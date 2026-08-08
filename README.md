# Thetis → Zeus TX Audio Profile Converter

Migrate your [Thetis](https://github.com/ramdor/Thetis) TX audio profiles into
[Zeus / Zeus Link](https://www.zeussdr.com) automatically, over Zeus's own API —
no manual re-entry, no file editing.

For each Thetis TX profile it recreates the equivalent Zeus **TX Audio Profile**,
including the CFC (Continuous Frequency Compressor) curve, leveler/ALC settings,
phase rotator, TX filter cutoffs, and mic gain.

> **Status:** Built and verified against **Zeus Link 1.0.7** with a Hermes Lite 2.
> Other Zeus versions will likely work, but *always* run the included
> verification script afterward (see below) — Zeus's API can change between
> versions.

---

## What it does

- Reads **all** your Thetis TX profiles straight from Thetis's database
- Lets you pick which to convert (or convert everything), and which becomes the
  active/default profile in Zeus
- Re-maps each profile's CFC bands from Thetis's freely-placed frequencies onto
  Zeus's fixed 10-band grid (50/100/200/500/1000/1500/2000/2500/3000/5000 Hz)
  using cubic-spline interpolation, so the tonal shape is preserved
- Creates the profiles through Zeus's real HTTP API — the same mechanism Zeus's
  own "Save" button uses — so they register correctly and appear in the dropdown
- Includes a **verification script** that independently re-derives the expected
  values and diffs them against what Zeus actually stored, field by field

## What it does NOT do

- It does not touch Zeus's database files directly (that approach does not work —
  see [How it works](#how-it-works))
- It does not copy VST plugin chains or the native plugin suite (noise-gate, eq,
  compressor, exciter, bass, reverb) — those have no Thetis equivalent and are
  left at Zeus's defaults
- It does not migrate RX settings — TX audio profiles only

---

## Requirements

- **Windows** with **PowerShell 7+** (`pwsh`). Windows PowerShell 5.1 may work but
  is untested for the final version; 7+ is recommended.
- **Thetis** installed, and it has connected to your radio at least once (so its
  profile database exists).
- **Zeus / Zeus Link running** while you run the converter. The scripts talk to
  the live Zeus engine over loopback — Zeus must be up, not closed.

---

## Quick start

1. Download or clone this repo.
2. Open PowerShell 7 (`pwsh`) in the repo folder.
3. **Make sure Zeus is running.**
4. Preview what will be converted (writes nothing):

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\Convert-ThetisToZeus.ps1 -WhatIf
   ```

5. Run it for real:

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\Convert-ThetisToZeus.ps1
   ```

   - Enter profile numbers (comma-separated) or `A` for all.
   - Then choose which profile becomes the active/default (or `S` to skip).

6. **Verify** (this is the important step — don't skip it):

   ```powershell
   pwsh -ExecutionPolicy Bypass -File .\Compare-ThetisZeus.ps1
   ```

   You want the summary to read **MISMATCH: 0, MISSING: 0**. Any `EXTRA` entries
   are just profiles that exist in Zeus but not Thetis (e.g. your own manually-made
   ones) — harmless.

> ⚠️ **The converter changes your live TX settings as it runs** (each profile is
> pushed to the live engine, then snapshotted — that's how Zeus's Save works). It
> re-applies your chosen active profile at the end. **Don't transmit while it runs.**

### Non-interactive use

```powershell
# Convert everything and set a specific profile active, no prompts:
pwsh -ExecutionPolicy Bypass -File .\Convert-ThetisToZeus.ps1 -All -SetActiveName "VMP 3k Voodoo"
```

---

## How it works

Zeus stores settings in [LiteDB](https://www.litedb.org/) files, but — importantly —
**writing those files directly does nothing**, because Zeus reads settings from its
live engine (a local REST server), not from disk at runtime. Zeus's UI is a
Chromium WebView talking over loopback HTTP to two backend processes
(`StationEngine` and `ZeusProduct`).

The profile-create endpoint (`POST /api/tx-audio-profiles`) only accepts a
`{name}` and **snapshots whatever is currently loaded in the live engine** — it
ignores any settings in the request body. So despite the repo name, this converts
*into* Zeus's profile store through its API; it does not manipulate the `.db` files.

The converter mirrors exactly what Zeus's own "Save" button does:

1. **Push settings to the live engine** on `StationEngine` via:
   - `POST /api/tx/cfc`            — CFC config (`{config}`)
   - `POST /api/tx/leveling`       — leveler/ALC (`{txLeveling}`)
   - `POST /api/tx/leveler-max-gain` — (`{gain}`)
   - `POST /api/tx/phase-rotator`  — (`{txPhaseRotator}`)
   - `POST /api/tx-filter`         — TX filter low/high (`{lowHz, highHz}`)
   - `POST /api/mic-gain`          — (`{db}`)
2. **Snapshot** into a named profile on `ZeusProduct` via
   `POST /api/tx-audio-profiles` (`{name}`), deleting any existing same-named
   profile first so it cleanly replaces.
3. **Set active** via `PUT /api/tx-audio-profiles/last-loaded` (`{id}`).

Ports are discovered automatically at runtime (Zeus assigns them dynamically).

### Field mapping

| Thetis                       | Zeus                          | Notes |
|------------------------------|-------------------------------|-------|
| `CFCEqFreq0-9` / `CFCPreComp0-9` / `CFCPostEqGain0-9` | `cfcConfig.bands[]` | Interpolated onto Zeus's fixed grid; compression floored at 0 (Zeus won't accept negative comp) |
| `CFCEnabled`, `CFCPostEqEnabled`, `CFCPreComp` | `cfcConfig.*` | |
| `Lev_On`, `Lev_MaxGain`, `Lev_Decay`, `ALC_*` | `txLeveling.*`, `levelerMaxGain` | |
| `CFCPhaseRotator*`, `CFCPhaseReverseEnabled` | `txPhaseRotator.*` | |
| `FilterLow`, `FilterHigh`    | `lowHz`, `highHz`             | |
| `MicGain`                    | `micGain`                     | |

---

## Troubleshooting

- **"ZeusProduct is not running"** — start Zeus and wait for it to fully load.
- **All conversions FAIL with 400** — likely a Zeus version difference in a field
  type or endpoint. The converter's inline error names the failing call and body;
  most 400s in testing were floats sent where Zeus wanted integers.
- **Profiles don't appear in the dropdown** — make sure you ran the *converter*
  (which uses the live+snapshot method), not an older direct-DB approach. Restart
  Zeus if the dropdown looks stale.
- **Comparison shows filter mismatches only** — make sure you're on the current
  version of the converter (older ones didn't set the TX filter).

---

## Files

| File | Purpose |
|------|---------|
| `Convert-ThetisToZeus.ps1` | The converter |
| `Compare-ThetisZeus.ps1`   | Independent verification of the conversion |

---

## Disclaimer

Community tool, not affiliated with or endorsed by the Zeus/Thetis projects.
It talks to Zeus's local API the same way the app itself does, but APIs can change
between versions. It changes your live TX settings while running. Review the code,
use `-WhatIf` first, and always run the verification script. No warranty.

## License

MIT — see [LICENSE](LICENSE).
