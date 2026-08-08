# Compare-ThetisZeus.ps1
# Verifies the Thetis -> Zeus conversion by re-deriving each Thetis profile's
# expected Zeus values and diffing them against what the live Zeus API actually
# returns. Read-only - makes no changes to either side.
#
# Zeus MUST be running.
#
# Reports, per profile:
#   - MISSING  : exists in Thetis, not found in Zeus
#   - EXTRA    : exists in Zeus, no matching Thetis profile (e.g. test1, api-probe)
#   - MISMATCH : found in both but one or more fields differ (lists them)
#   - OK       : all compared fields match
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File .\Compare-ThetisZeus.ps1
#   pwsh -ExecutionPolicy Bypass -File .\Compare-ThetisZeus.ps1 -Verbose2   # show every compared field

param([switch]$Verbose2)

$thetisDbRoot = $null
foreach ($variant in @("Thetis-x64","Thetis-x86","Thetis")) {
    $candidate = "$env:APPDATA\OpenHPSDR\$variant\DB"
    if (Test-Path $candidate) { $thetisDbRoot = $candidate; break }
}
if (-not $thetisDbRoot) { $thetisDbRoot = "$env:APPDATA\OpenHPSDR\Thetis-x64\DB" }
$tol = 0.02   # tolerance for float comparisons (rounding in interpolation)

$reportDir = "$env:USERPROFILE\Documents\ZeusSync\Discovery"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }
$reportPath = "$reportDir\Compare-ThetisZeus_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
function Say { param([string]$m,[string]$c="White"); Add-Content $reportPath $m; Write-Host $m -ForegroundColor $c }

Say "========================================" "Cyan"
Say " Thetis vs Zeus Profile Comparison" "Cyan"
Say " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Cyan"
Say "========================================" "Cyan"

# --- Find ZeusProduct API ---
$zp = Get-Process -Name ZeusProduct -ErrorAction SilentlyContinue
if (-not $zp) { Say "ERROR: ZeusProduct not running. Start Zeus first." "Red"; exit 1 }
$port = $null
foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $zp.Id -and $_.LocalAddress -eq '127.0.0.1' })) {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$($c.LocalPort)/api/tx-audio-profiles" -TimeoutSec 5 -ErrorAction Stop | Out-Null; $port = $c.LocalPort; break } catch {}
}
if (-not $port) { Say "ERROR: No ZeusProduct port answered /api/tx-audio-profiles." "Red"; exit 1 }
$baseUri = "http://127.0.0.1:$port"
Say "Zeus API: $baseUri" "DarkGray"

# --- Cubic spline (same as converter) ---
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
if ($dbman.Count -eq 0) { Say "ERROR: No Thetis DB found." "Red"; exit 1 }
$dbmanPath = if ($dbman.Count -eq 1) { $dbman[0].FullName } else { $dbman[0].FullName }
$tj = Get-Content $dbmanPath | ConvertFrom-Json
$thetisXml = Get-Content (Join-Path $thetisDbRoot $tj.ActiveDB_File) -Raw
$profiles = @{}
foreach ($m in [regex]::Matches($thetisXml,'<TXProfile>([\s\S]*?)</TXProfile>')) {
    $b = $m.Groups[1].Value
    if ($b -match '<Name>([^<]+)</Name>') { $profiles[$matches[1].Trim()] = $b }
}
Say "Thetis profiles: $($profiles.Count)" "DarkGray"

# --- Pull all Zeus profiles, index by id ---
$zeusResp = Invoke-RestMethod -Uri "$baseUri/api/tx-audio-profiles"
$zeusById = @{}
foreach ($p in $zeusResp.profiles) { $zeusById[$p.id] = $p }
Say "Zeus profiles: $($zeusById.Count)" "DarkGray"
Say ""

function TGet { param($x,$t) if($x -match ('<'+[regex]::Escape($t)+'>([^<]*)</'+[regex]::Escape($t)+'>')){return $matches[1].Trim()}; return $null }
function TNum { param($x,$t,$d=0.0) $r=TGet $x $t; $v=$d; if($r -ne $null){[void][double]::TryParse($r,[ref]$v)}; return $v }
function TBool { param($x,$t,$d=$false) $r=TGet $x $t; if($r -eq $null){return $d}; return ($r -eq "True") }
function NearEq { param($a,$b) return ([math]::Abs([double]$a - [double]$b) -le $tol) }

$zeusFreqs = @(50.0,100.0,200.0,500.0,1000.0,1500.0,2000.0,2500.0,3000.0,5000.0)

$okCount=0; $mismatchCount=0; $missingCount=0
$matchedZeusIds = @{}

foreach ($name in ($profiles.Keys | Sort-Object)) {
    $blk = $profiles[$name]
    $slug = ($name -replace '[^a-zA-Z0-9]+','-').Trim('-').ToLower()
    $matchedZeusIds[$slug] = $true

    if (-not $zeusById.ContainsKey($slug)) {
        Say ("MISSING  {0}  (expected id '{1}' not in Zeus)" -f $name, $slug) "Red"
        $missingCount++
        continue
    }
    $z = $zeusById[$slug]

    # Re-derive expected CFC bands
    $tf=@();$tc=@();$tp=@()
    for($i=0;$i -le 9;$i++){ $tf+=TNum $blk "CFCEqFreq$i"; $tc+=TNum $blk "CFCPreComp$i"; $tp+=TNum $blk "CFCPostEqGain$i" }
    $ord = 0..9 | Sort-Object { $tf[$_] }
    $tfS=$ord|%{$tf[$_]}; $tcS=$ord|%{$tc[$_]}; $tpS=$ord|%{$tp[$_]}

    $diffs = @()

    # Scalar fields
    if (-not (NearEq (TNum $blk "MicGain") $z.micGainDb)) { $diffs += "micGainDb: expected $(TNum $blk 'MicGain'), got $($z.micGainDb)" }
    if (-not (NearEq (TNum $blk "Lev_MaxGain" 8.0) $z.levelerMaxGainDb)) { $diffs += "levelerMaxGainDb: expected $(TNum $blk 'Lev_MaxGain' 8.0), got $($z.levelerMaxGainDb)" }
    if ((TBool $blk "CFCEnabled") -ne $z.cfcConfig.enabled) { $diffs += "cfc.enabled: expected $(TBool $blk 'CFCEnabled'), got $($z.cfcConfig.enabled)" }
    if (-not (NearEq (TNum $blk "CFCPreComp") $z.cfcConfig.preCompDb)) { $diffs += "cfc.preCompDb: expected $(TNum $blk 'CFCPreComp'), got $($z.cfcConfig.preCompDb)" }
    if (-not (NearEq (TNum $blk "FilterLow" 100.0) $z.lowCutHz)) { $diffs += "lowCutHz: expected $(TNum $blk 'FilterLow' 100.0), got $($z.lowCutHz)" }
    if (-not (NearEq (TNum $blk "FilterHigh" 3000.0) $z.highCutHz)) { $diffs += "highCutHz: expected $(TNum $blk 'FilterHigh' 3000.0), got $($z.highCutHz)" }
    if ((TBool $blk "Lev_On") -ne $z.txLeveling.levelerEnabled) { $diffs += "leveler.enabled: expected $(TBool $blk 'Lev_On'), got $($z.txLeveling.levelerEnabled)" }
    if (-not (NearEq (TNum $blk "ALC_MaximumGain" 3.0) $z.txLeveling.alcMaxGainDb)) { $diffs += "alcMaxGainDb: expected $(TNum $blk 'ALC_MaximumGain' 3.0), got $($z.txLeveling.alcMaxGainDb)" }
    if ((TBool $blk "CFCPhaseRotatorEnabled") -ne $z.txPhaseRotator.enabled) { $diffs += "phaseRotator.enabled: expected $(TBool $blk 'CFCPhaseRotatorEnabled'), got $($z.txPhaseRotator.enabled)" }

    # CFC bands (interpolated, comp clamped >= 0)
    for($i=0;$i -lt $zeusFreqs.Count;$i++){
        $f=$zeusFreqs[$i]
        $expComp=[math]::Round((Interp-Value $f ([double[]]$tfS) ([double[]]$tcS)),2); if($expComp -lt 0){$expComp=0}
        $expPost=[math]::Round((Interp-Value $f ([double[]]$tfS) ([double[]]$tpS)),2)
        $zb = $z.cfcConfig.bands[$i]
        if ($zb.freqHz -ne [int]$f) { $diffs += "band$($i+1).freqHz: expected $([int]$f), got $($zb.freqHz)" }
        if (-not (NearEq $expComp $zb.compLevelDb)) { $diffs += "band$($i+1)($([int]$f)Hz).comp: expected $expComp, got $($zb.compLevelDb)" }
        if (-not (NearEq $expPost $zb.postGainDb)) { $diffs += "band$($i+1)($([int]$f)Hz).post: expected $expPost, got $($zb.postGainDb)" }
    }

    if ($diffs.Count -eq 0) {
        Say ("OK       {0}" -f $name) "Green"
        if ($Verbose2) {
            Say ("           mic=$($z.micGainDb) lev=$($z.levelerMaxGainDb) cfc=$($z.cfcConfig.enabled) preComp=$($z.cfcConfig.preCompDb) filter=$($z.lowCutHz)-$($z.highCutHz)") "DarkGray"
        }
        $okCount++
    } else {
        Say ("MISMATCH {0}  ({1} diff(s)):" -f $name, $diffs.Count) "Yellow"
        foreach ($d in $diffs) { Say ("           - $d") "DarkGray" }
        $mismatchCount++
    }
}

# --- Extra Zeus profiles with no Thetis source ---
Say ""
$extras = $zeusById.Keys | Where-Object { -not $matchedZeusIds.ContainsKey($_) }
foreach ($e in $extras) {
    Say ("EXTRA    Zeus profile '{0}' (name '{1}') has no matching Thetis source" -f $e, $zeusById[$e].name) "Magenta"
}

# --- Active profile check ---
$lastLoaded = $null
try { $lastLoaded = (Invoke-RestMethod -Uri "$baseUri/api/tx-audio-profiles/last-loaded").id } catch {}
Say ""
Say "Active (last-loaded) Zeus profile id: $lastLoaded" "Cyan"

# --- Summary ---
Say ""
Say "========================================" "Cyan"
Say " Summary" "Cyan"
Say "========================================" "Cyan"
Say ("  OK:        {0}" -f $okCount)       $(if($okCount -gt 0){"Green"}else{"White"})
Say ("  MISMATCH:  {0}" -f $mismatchCount) $(if($mismatchCount -gt 0){"Yellow"}else{"White"})
Say ("  MISSING:   {0}" -f $missingCount)  $(if($missingCount -gt 0){"Red"}else{"White"})
Say ("  EXTRA:     {0}  (test artifacts / manually-made, harmless)" -f @($extras).Count) "DarkGray"
Say ""
Say "Report saved: $reportPath" "DarkGray"
