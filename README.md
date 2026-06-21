# Volante

A transparent, **reversible** Windows 10/11 game-tweaking tool - rebuilt from a
typical "game optimizer" pack with the dangerous/placebo parts removed and a
real engine, GUI, and headless/deployment mode added.

Design goals: small, transparent, **truly reversible**, evidence-based, conservative.
No bundled binaries, no registry cleaners, no blanket service-disabling.

## How it works

A single PowerShell engine (`src/Engine`) defines a catalog of tweaks, each with
`Test` / `Apply` / `Revert` logic. Two thin frontends sit on top:

| Mode | Use |
|------|-----|
| **GUI** (WPF) | Interactive - pick tweaks, dry-run, apply, revert |
| **Headless** | Scripted/silent for deployed PCs (Intune, SCCM, MDT, login scripts) |

Both call the *same* engine, so results are identical. Every change records its
**original value** to a backup store before writing, so revert restores reality -
not a guessed default.

- Backup store: `%ProgramData%\Volante\backup.json`
- Logs: `%ProgramData%\Volante\logs\gametune_YYYYMMDD.log`

## Requirements

- Windows 10/11, **Windows PowerShell 5.1** (built in; the launcher uses it explicitly).
- Administrator for *machine-scoped* tweaks (the GUI auto-elevates; headless should run elevated / as SYSTEM).

## GUI

Double-click **`Volante.exe`** - a tiny native launcher with an icon that prompts
for admin automatically (UAC) and opens with no console window. (No exe yet? See
**Building the launcher** below, or use `Volante.cmd` which does the same thing
from PowerShell.)

It opens on a **Dashboard** - a read-only system check shown *before* you tune
anything (the only change it can make is the optional refresh-rate fix, which you
confirm):

1. **Monitor refresh rate** - current vs the highest your display supports, with a
   one-click **Set to max** (validated against supported modes, with a keep/revert prompt).
2. **GPU driver** - installed version (NVIDIA marketing version decoded), date and age,
   flagged if it's over ~3 months old, plus a link to the vendor download and Windows Update.
3. **Ping to Valve / Steam** - TCP-handshake latency to Steam edge endpoints (a routing
   proxy, not your exact in-game ping; CS2's relays don't answer ICMP).
4. **CS2 GPU control-panel settings** - the recommended NVIDIA/AMD settings for CS2 with a
   button that opens your control panel. Values that can't be read safely from outside the
   driver are marked "Verify in control panel" rather than guessed.

From the Dashboard, **Start tuning** opens the wizard and **Advanced mode** opens the
full list. The tuner itself has two modes:

**Wizard (default - for everyone):** a guided flow.
1. **Goals** - pick "Gaming performance" and/or "Privacy & less clutter" (both on by default).
2. **Review** - plain-language list of what will change, with a restore-point reassurance.
   Click **Preview (no changes)** to dry-run the whole flow and see exactly what *would*
   happen without touching anything - then **Apply these now** from the results if you're happy.
3. **Apply** - one click; a restore point is saved first, then a results screen with an
   **Undo everything** button and a **Restart now** button if any change needs a reboot.

**Advanced mode (for power users):** click "Power user? Open Advanced mode" for the full
per-tweak list - Recommended/All/Clear presets, Dry Run, Apply/Revert Selected, a live log,
and a risk badge (Safe / Caution / Advanced) + current state on every tweak.

## Headless / deployment

```powershell
# Show the catalog (no admin, no changes)
.\Optimize.ps1 -List

# Report current state only - changes nothing
.\Optimize.ps1 -Report

# Read-only system check (refresh rate, GPU driver, Valve ping, CS2 settings)
.\Optimize.ps1 -Dashboard

# Apply the recommended preset (auto restore point unless -NoRestorePoint)
.\Optimize.ps1 -Headless -Recommended

# Preview without changing anything
.\Optimize.ps1 -Headless -Recommended -DryRun

# Specific tweaks by id
.\Optimize.ps1 -Headless -Apply mouse-accel-off,gamedvr-off

# From a profile file (build your own fleet profile)
.\Optimize.ps1 -Headless -ProfilePath .\config\recommended.json

# Roll back
.\Optimize.ps1 -Headless -Revert gpu-pstate-restore
.\Optimize.ps1 -Headless -RevertAll
```

Flags: `-Headless -Report -Dashboard -DryRun -Recommended -All -Apply <ids> -Revert <ids>
-RevertAll -ProfilePath <file> -NoRestorePoint -NoElevate -List`.
Exit code = number of failed operations (0 = success), for deployment checks.

**Intune / SCCM example** (runs as SYSTEM = already elevated; skip restore point
in imaging, log is captured automatically):

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "Optimize.ps1" -Headless -Recommended -NoRestorePoint
```

## Tweaks included

27 tweaks across 8 categories. Run `Optimize.ps1 -List` for the full catalog with
risk/scope, or `-Report` to see what's currently applied.

| Category | Count | Examples |
|----------|-------|----------|
| Latency     | 4 | MMCSS responsiveness, Games task priority, network throttling |
| Power       | 5 | Ultimate plan, CPU throttling off, USB suspend off, PCIe ASPM off |
| Privacy     | 7 | DiagTrack, advertising ID, activity history, telemetry policy |
| Performance | 3 | Game DVR off, Game Mode on, startup-delay off |
| Visual      | 3 | menu delay, reduce animations, transparency off |
| GPU         | 3 | P-state lock removal, HAGS, **MSI mode** (advanced) |
| Input       | 1 | mouse acceleration off |
| Network     | 1 | **per-NIC Nagle off** (advanced) |

Each tweak is tagged Safe / Caution / Advanced. The **Recommended** preset (used by
the wizard and `-Recommended`) is the ~19 lower-risk ones; Advanced/contested tweaks
(`hags-on`, `diagtrack-off`, `win32-priority-separation`, `fast-startup-off`,
`reduce-animations`, `transparency-off`, `gpu-msi-mode`, `nagle-off`) are opt-in.

## Building the launcher (Volante.exe)

The exe is a ~13 KB native launcher compiled from `src\Launcher.cs` with an embedded
icon and admin manifest. It just runs the plain-text `.ps1` engine on disk, so the
logic stays auditable. Build (or rebuild) it with the always-present .NET Framework
compiler - no install, no internet:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Exe.ps1
```

This (re)generates `assets\gametune.ico` if missing and produces `Volante.exe`.
The exe is **unsigned**, so first run may show a SmartScreen prompt
("More info" > "Run anyway"); code-signing is the only thing that removes that.
For headless/deployment, keep using `Optimize.ps1` / `Volante.cmd` (the exe is
GUI-only and has no console output).

## Code-signing (removes SmartScreen warnings)

Signing is the only thing that stops the "unknown publisher" SmartScreen/UAC prompt.

```powershell
# Real certificate (recommended for distribution): a .pfx or an installed cert
tools\Sign.ps1 -PfxPath cert.pfx
tools\Sign.ps1 -Thumbprint <thumbprint>          # cert already in your store

# Just testing the pipeline? Make a self-signed cert first:
tools\New-DevCert.ps1
```

`Sign.ps1` signs `Volante.exe` (and any `dist\*.exe` installer) with SHA-256 and an
RFC3161 timestamp, so signatures stay valid after the cert expires.

- **Self-signed** cert: trusted only where you deploy it (your PCs / a managed fleet
  with the cert in Trusted Publishers). Fine for personal/lab use.
- **Public distribution:** use a CA-issued code-signing certificate - ideally **EV**,
  which earns SmartScreen reputation immediately.

## Installer (Inno Setup)

Builds `dist\Volante-Setup-<ver>.exe` with Start-menu + optional desktop shortcuts
and an uninstaller, installing to `Program Files\Volante`.

```powershell
tools\Build-Installer.ps1     # requires Inno Setup 6 (free): https://jrsoftware.org/isdl.php
```

## One-command release

Build the exe, sign it, build the installer, and sign that - in one go. Signing
steps run only if you pass a certificate:

```powershell
tools\Build-Release.ps1                        # unsigned exe + installer
tools\Build-Release.ps1 -Thumbprint <thumbprint>
tools\Build-Release.ps1 -PfxPath cert.pfx
```

## Adding a tweak

Add one `[pscustomobject]` to `Get-TweakCatalog` in `src/Engine/Tweaks.ps1` with
`Test` / `Apply` / `Revert` script blocks. Use `Set-TrackedValue` /
`Remove-TrackedValue` (registry) or `Set-TweakNote` (services/power) in `Apply`
so revert is automatic and exact. No other file needs to change - it shows up in
both the GUI and headless modes.

## What was deliberately left out

CCleaner / registry cleaning, blanket service-disabling (BITS, Spooler, Bluetooth,
Hyper-V), `SysMain`/Prefetch disabling on SSDs, blocking driver auto-download, and
the broken hibernate `.reg`. See the project notes for the rationale.

