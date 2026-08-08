# Convert-ThetisToZeus.ps1  (v2 - live-state + snapshot method)
# Converts Thetis TX profiles into Zeus TX Audio Profiles using the SAME
# mechanism Zeus's own UI uses:
#   1. push settings to the LIVE engine (StationEngine server) via /api/tx/*
#   2. snapshot the live state into a named profile by POSTing {name} to the
#      ZeusProduct server's /api/tx-audio-profiles
#
# This is required because POST /api/tx-audio-profiles only accepts {name} and
# snapshots whatever is currently live - it ignores any settings in the body.
# (Verified from the UI's own JS source and by end-to-end testing.)
#
# Endpoints (all body shapes confirmed from wwwroot JS source):
#   StationEngine:  POST /api/tx/cfc            {config: cfcConfig}
#                   POST /api/tx/leveling       {txLeveling: {...}}
#                   POST /api/tx/leveler-max-gain {gain: n}
#                   POST /api/tx/phase-rotator  {txPhaseRotator: {...}}
#                   POST /api/mic-gain          {db: n}
#   ZeusProduct:    POST /api/tx-audio-profiles {name}          (snapshot)
#                   DELETE /api/tx-audio-profiles/{id}
#                   PUT  /api/tx-audio-profiles/last-loaded {id} (set active)
#
# CFC bands are interpolated onto Zeus's fixed grid via cubic spline.
# Zeus MUST be running.
#
# NOTE: This changes your LIVE TX settings as it runs (each profile is pushed
# live, then snapshotted). When finished it re-applies your chosen active
# profile so the live state matches that one. Don't transmit while it runs.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File .\Convert-ThetisToZeus.ps1
#   pwsh -ExecutionPolicy Bypass -File .\Convert-ThetisToZeus.ps1 -All -SetActiveName "VMP 3k Voodoo"
#   pwsh -ExecutionPolicy Bypass -File .\Convert-ThetisToZeus.ps1 -WhatIf

param(
    [switch]$All,
    [string]$SetActiveName,
    [switch]$WhatIf
)

# Auto-detect the Thetis DB folder (handles Thetis-x64, Thetis-x86, or plain Thetis)
$thetisDbRoot = $null
foreach ($variant in @("Thetis-x64","Thetis-x86","Thetis")) {
    $candidate = "$env:APPDATA\OpenHPSDR\$variant\DB"
    if (Test-Path $candidate) { $thetisDbRoot = $candidate; break }
}
if (-not $thetisDbRoot) { $thetisDbRoot = "$env:APPDATA\OpenHPSDR\Thetis-x64\DB" }  # fall back for error message
$logDir  = "$env:USERPROFILE\Documents\ZeusSync\Logs"
$logPath = "$logDir\Convert-ThetisToZeus_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
function Write-Log { param([string]$m,[string]$c="White"); Add-Content $logPath "[$(Get-Date -Format 'HH:mm:ss')] $m"; Write-Host $m -ForegroundColor $c }
function Write-LogBlank { Add-Content $logPath ""; Write-Host "" }

Write-LogBlank
Write-Log "========================================" "Cyan"
Write-Log " Thetis -> Zeus Converter (live+snapshot)" "Cyan"
Write-Log "========================================" "Cyan"
if ($WhatIf) { Write-Log " -WhatIf: preview only, no live writes or snapshots." "Yellow" }

# --- Find both servers ---
$zp = Get-Process -Name ZeusProduct -ErrorAction SilentlyContinue
$se = Get-Process -Name StationEngine -ErrorAction SilentlyContinue
if (-not $zp -or -not $se) { Write-Log "ERROR: Zeus not fully running (need ZeusProduct + StationEngine)." "Red"; exit 1 }

function Find-Port($proc, $probePath) {
    foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $proc.Id -and $_.LocalAddress -eq '127.0.0.1' })) {
        try { Invoke-WebRequest "http://127.0.0.1:$($c.LocalPort)$probePath" -TimeoutSec 3 -ErrorAction Stop | Out-Null; return $c.LocalPort } catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 404) { return $c.LocalPort }
        }
    }
    return $null
}
$prodPort = Find-Port $zp "/api/tx-audio-profiles"
$engPort  = Find-Port $se "/api/tx/cfc/presets"
if (-not $prodPort -or -not $engPort) { Write-Log "ERROR: Could not resolve both server ports (prod=$prodPort eng=$engPort)." "Red"; exit 1 }
$prod = "http://127.0.0.1:$prodPort"
$eng  = "http://127.0.0.1:$engPort"
Write-Log "ZeusProduct: $prod   StationEngine: $eng" "Green"

# --- Cubic spline ---
function Get-CubicSplineCoeffs {
    param([double[]]$x, [double[]]$y)
    $n = $x.Count
    if ($n -lt 2) { return $null }
    if ($n -eq 2) { $s = ($y[1]-$y[0])/($x[1]-$x[0]); return @{x=$x;a=$y[0..0];b=@($s);c=@(0.0);d=@(0.0)} }
    $h=@(); for($i=0;$i -lt $n-1;$i++){ $h+=$x[$i+1]-$x[$i] }
    $sz=$n-2
    $diag=[double[]]::new($sz);$upper=[double[]]::new($sz-1);$lower=[double[]]::new($sz-1);$rhs=[double[]]::new($sz)
    for($i=0;$i -lt $sz;$i++){ $diag[$i]=2.0*($h[$i]+$h[$i+1]); $rhs[$i]=6.0*(($y[$i+2]-$y[$i+1])/$h[$i+1]-($y[$i+1]-$y[$i])/$h[$i]) }
    for($i=0;$i -lt $sz-1;$i++){ $upper[$i]=$h[$i+1]; $lower[$i]=$h[$i+1] }
    $c2=[double[]]::new($sz);$d2=[double[]]::new($sz)
    $c2[0]=$upper[0]/$diag[0];$d2[0]=$rhs[0]/$diag[0]
    for($i=1;$i -lt $sz;$i++){ $m=$diag[$i]-$lower[$i-1]*$c2[$i-1]; $d2[$i]=($rhs[$i]-$lower[$i-1]*$d2[$i-1])/$m; if($i -lt $sz-1){$c2[$i]=$upper[$i]/$m} }
    $M=[double[]]::new($n);$M[$n-1]=0.0;$M[0]=0.0;$M[$sz]=$d2[$sz-1]
    for($i=$sz-2;$i -ge 0;$i--){ $M[$i+1]=$d2[$i]-$c2[$i]*$M[$i+2] }
    $a=[double[]]::new($n-1);$b=[double[]]::new($n-1);$c=[double[]]::new($n-1);$d=[double[]]::new($n-1)
    for($i=0;$i -lt $n-1;$i++){ $a[$i]=$y[$i]; $b[$i]=($y[$i+1]-$y[$i])/$h[$i]-$h[$i]*(2.0*$M[$i]+$M[$i+1])/6.0; $c[$i]=$M[$i]/2.0; $d[$i]=($M[$i+1]-$M[$i])/(6.0*$h[$i]) }
    return @{x=$x;a=$a;b=$b;c=$c;d=$d}
}
function Interp-Value {
    param([double]$freq,[double[]]$freqs,[double[]]$vals)
    if($freq -le $freqs[0]){return $vals[0]}
    if($freq -ge $freqs[-1]){return $vals[-1]}
    $sp=Get-CubicSplineCoeffs $freqs $vals
    for($i=0;$i -lt ($freqs.Count-1);$i++){ if($freq -ge $freqs[$i] -and $freq -le $freqs[$i+1]){ $dx=$freq-$freqs[$i]; return $sp.a[$i]+$sp.b[$i]*$dx+$sp.c[$i]*$dx*$dx+$sp.d[$i]*$dx*$dx*$dx } }
    return 0.0
}

# --- Read Thetis ---
$dbman = Get-ChildItem $thetisDbRoot -Filter "*_dbman_settings.json" -ErrorAction SilentlyContinue
if ($dbman.Count -eq 0) { Write-Log "ERROR: No Thetis DB found." "Red"; exit 1 }
$dbmanPath = if ($dbman.Count -eq 1) { $dbman[0].FullName } else {
    $i=1; foreach($f in $dbman){ Write-Host "  [$i] $($f.Name -replace '_dbman_settings.json','')"; $i++ }
    $dbman[[int](Read-Host "Select radio")-1].FullName
}
$tj = Get-Content $dbmanPath | ConvertFrom-Json
$thetisXml = Get-Content (Join-Path $thetisDbRoot $tj.ActiveDB_File) -Raw
$activeThetisProfile = $null
if ($thetisXml -match '<Key>comboTXProfile</Key>\s*<Value>([^<]+)</Value>') { $activeThetisProfile = $matches[1].Trim() }
$profiles = @{}
foreach ($m in [regex]::Matches($thetisXml,'<TXProfile>([\s\S]*?)</TXProfile>')) {
    $b = $m.Groups[1].Value
    if ($b -match '<Name>([^<]+)</Name>') { $profiles[$matches[1].Trim()] = $b }
}
if ($profiles.Count -eq 0) { Write-Log "ERROR: No TXProfile blocks." "Red"; exit 1 }
$profileNames = @($profiles.Keys | Sort-Object)
Write-Log "Found $($profileNames.Count) Thetis profiles. Active: $activeThetisProfile" "DarkGray"

# --- Selection menu ---
$selected = @()
if ($All) { $selected = $profileNames; Write-Log "-All: converting all $($selected.Count)." "Green" }
else {
    Write-LogBlank; Write-Log "Select Thetis profiles to convert:" "Cyan"; Write-LogBlank
    $i=1; foreach ($name in $profileNames) { $mk = if($name -eq $activeThetisProfile){" [ACTIVE]"}else{""}; Write-Host ("  [{0,2}] {1}{2}" -f $i,$name,$mk); $i++ }
    Write-LogBlank; Write-Host "  [A] Convert ALL"; Write-LogBlank
    $sel = Read-Host "Profile numbers (comma-separated) or A"
    if ($sel -match "^[Aa]") { $selected = $profileNames; Write-Log "All selected." "Green" }
    else { foreach ($nn in ($sel -split ',' | %{$_.Trim()})) { $ix=[int]$nn-1; if($ix -ge 0 -and $ix -lt $profileNames.Count){$selected+=$profileNames[$ix]} }
        if ($selected.Count -eq 0){Write-Log "None selected." "Red"; exit 1}; Write-Log "Selected: $($selected -join ', ')" "Green" }
}

# --- Active menu ---
$activeChoiceName = $null
if ($SetActiveName) { if ($selected -contains $SetActiveName){$activeChoiceName=$SetActiveName} else {Write-Log "[WARN] -SetActiveName not in selection." "Yellow"} }
elseif (-not $WhatIf) {
    Write-LogBlank; Write-Log "Set active (default) Zeus profile after convert:" "Cyan"; Write-LogBlank
    $i=1; foreach ($name in $selected){ $mk=if($name -eq $activeThetisProfile){" [was active in Thetis]"}else{""}; Write-Host ("  [{0,2}] {1}{2}" -f $i,$name,$mk); $i++ }
    Write-Host "  [S] Skip"; Write-LogBlank
    $ac = Read-Host "Active profile (number or S)"
    if ($ac -notmatch "^[Ss]"){ $ix=[int]$ac-1; if($ix -ge 0 -and $ix -lt $selected.Count){$activeChoiceName=$selected[$ix]} }
}
if ($activeChoiceName){ Write-Log "Will set active: $activeChoiceName" "Green" }

# --- Thetis tag helpers ---
function TGet { param($x,$t) if($x -match ('<'+[regex]::Escape($t)+'>([^<]*)</'+[regex]::Escape($t)+'>')){return $matches[1].Trim()}; return $null }
function TNum { param($x,$t,$d=0.0) $r=TGet $x $t; $v=$d; if($r -ne $null){[void][double]::TryParse($r,[ref]$v)}; return $v }
function TBool { param($x,$t,$d=$false) $r=TGet $x $t; if($r -eq $null){return $d}; return ($r -match '^(true|True)$') }

$zeusFreqs = @(50.0,100.0,200.0,500.0,1000.0,1500.0,2000.0,2500.0,3000.0,5000.0)

function Build-Live {
    param([string]$blk)
    $tf=@();$tc=@();$tp=@()
    for($i=0;$i -le 9;$i++){ $tf+=TNum $blk "CFCEqFreq$i"; $tc+=TNum $blk "CFCPreComp$i"; $tp+=TNum $blk "CFCPostEqGain$i" }
    $ord = 0..9 | Sort-Object { $tf[$_] }
    $tfS=$ord|%{$tf[$_]}; $tcS=$ord|%{$tc[$_]}; $tpS=$ord|%{$tp[$_]}
    $bands=[System.Collections.ArrayList]@()
    for($i=0;$i -lt $zeusFreqs.Count;$i++){
        $f=$zeusFreqs[$i]
        $comp=[math]::Round((Interp-Value $f ([double[]]$tfS) ([double[]]$tcS)),2); if($comp -lt 0){$comp=0}
        $post=[math]::Round((Interp-Value $f ([double[]]$tfS) ([double[]]$tpS)),2)
        [void]$bands.Add(@{ freqHz=[int]$f; compLevelDb=$comp; postGainDb=$post })
    }
    return @{
        cfc = @{ enabled=(TBool $blk "CFCEnabled"); postEqEnabled=(TBool $blk "CFCPostEqEnabled"); preCompDb=[int](TNum $blk "CFCPreComp"); prePeqDb=0; bands=@($bands) }
        leveling = @{ alcMaxGainDb=[int](TNum $blk "ALC_MaximumGain" 3.0); alcDecayMs=[int](TNum $blk "ALC_Decay" 10.0); levelerEnabled=(TBool $blk "Lev_On"); levelerDecayMs=[int](TNum $blk "Lev_Decay" 100.0); compressorEnabled=$false; compressorGainDb=0 }
        levelerMaxGain = [int](TNum $blk "Lev_MaxGain" 8.0)
        phaseRotator = @{ enabled=(TBool $blk "CFCPhaseRotatorEnabled"); cornerHz=[int](TNum $blk "CFCPhaseRotatorFreq" 338.0); stages=[int](TNum $blk "CFCPhaseRotatorStages" 8.0); reverse=(TBool $blk "CFCPhaseReverseEnabled"); autoMode=$false }
        micGain = [int](TNum $blk "MicGain")
        filterLow = [int](TNum $blk "FilterLow" 100.0)
        filterHigh = [int](TNum $blk "FilterHigh" 3000.0)
    }
}

function Push-Live {
    param($live)
    $calls = @(
        @{ url="$eng/api/tx/cfc";              body=(@{config=$live.cfc} | ConvertTo-Json -Depth 8) }
        @{ url="$eng/api/tx/leveling";         body=(@{txLeveling=$live.leveling} | ConvertTo-Json -Depth 6) }
        @{ url="$eng/api/tx/leveler-max-gain"; body=(@{gain=$live.levelerMaxGain} | ConvertTo-Json) }
        @{ url="$eng/api/tx/phase-rotator";    body=(@{txPhaseRotator=$live.phaseRotator} | ConvertTo-Json -Depth 6) }
        @{ url="$eng/api/mic-gain";            body=(@{db=$live.micGain} | ConvertTo-Json) }
        @{ url="$eng/api/tx-filter";           body=(@{lowHz=$live.filterLow; highHz=$live.filterHigh} | ConvertTo-Json) }
    )
    foreach ($call in $calls) {
        try {
            Invoke-RestMethod $call.url -Method Post -Body $call.body -ContentType "application/json" -ErrorAction Stop | Out-Null
        } catch {
            $eb=""; try { $eb=(New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
            if(-not $eb){ $eb=$_.ErrorDetails.Message }
            throw "live-push $($call.url) failed: $eb  ||  BODY WAS: $($call.body)"
        }
    }
}

# --- Existing profiles (for delete-before-snapshot) ---
$existing = @{}
try { foreach ($ep in (Invoke-RestMethod "$prod/api/tx-audio-profiles").profiles) { $existing[$ep.name] = $ep.id } } catch {}

Write-LogBlank; Write-Log "Converting $($selected.Count) profile(s)..." "Cyan"
$ok=0; $fail=0; $activeSlug=$null

foreach ($name in $selected) {
    $live = Build-Live $profiles[$name]
    if ($WhatIf) {
        Write-Log ("[WHATIF] {0}: cfc.enabled={1} preComp={2} lev={3} maxGain={4} rot={5} mic={6}" -f $name,$live.cfc.enabled,$live.cfc.preCompDb,$live.leveling.levelerEnabled,$live.levelerMaxGain,$live.phaseRotator.enabled,$live.micGain) "DarkGray"
        continue
    }
    try {
        Push-Live $live
        if ($existing.ContainsKey($name)) { try { Invoke-RestMethod "$prod/api/tx-audio-profiles/$($existing[$name])" -Method Delete -ErrorAction Stop | Out-Null } catch {} }
        $r = Invoke-RestMethod "$prod/api/tx-audio-profiles" -Method Post -Body (@{name=$name} | ConvertTo-Json) -ContentType "application/json"
        if ($name -eq $activeChoiceName) { $activeSlug = $r.id }
        Write-Log ("  OK   {0} -> id '{1}'" -f $name,$r.id) "Green"; $ok++
    } catch {
        $msg=$_.Exception.Message
        Write-Log ("  FAIL {0}: {1}" -f $name,$msg) "Red"; $fail++
    }
}

if ($WhatIf) { Write-LogBlank; Write-Log "-WhatIf done - nothing written." "Yellow"; exit 0 }

# --- Set active: re-push its live state + mark last-loaded ---
if ($activeSlug) {
    try {
        Push-Live (Build-Live $profiles[$activeChoiceName])
        Invoke-RestMethod "$prod/api/tx-audio-profiles/last-loaded" -Method Put -Body (@{id=$activeSlug} | ConvertTo-Json) -ContentType "application/json" | Out-Null
        Write-Log "Active profile set to '$activeChoiceName' and live state re-applied to match." "Green"
    } catch { Write-Log "Could not set active: $($_.Exception.Message)" "Yellow" }
}

Write-LogBlank
Write-Log "========================================" "Cyan"
Write-Log " Done.  OK: $ok   Failed: $fail" $(if($fail -gt 0){"Yellow"}else{"Green"})
Write-Log "========================================" "Cyan"
Write-Log "Run Compare-ThetisZeus.ps1 to verify." "Cyan"
Write-Log "Log: $logPath" "DarkGray"
