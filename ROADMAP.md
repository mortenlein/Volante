# Roadmap

## Shipped — v2.0.0 (see CHANGELOG.md)
- **WebView2 desktop app** (React UI in `src/WebUI`) over the PowerShell engine;
  in-process JS↔engine JSON bridge. Frameless window (custom title bar, drag/resize,
  Win11 rounded corners). WPF GUI retired.
- **Dashboard** real readiness score; **System check** (refresh rate, GPU driver,
  Valve/Steam ping, CS2 control-panel recs, CS2 setup).
- **Tune**: apply / **Preview** (dry-run) / **Revert all** / **per-tweak revert**;
  **editable game profiles** drive the selected tweak set.
- **Monitor**: live telemetry (CPU + per-core, GPU util/temp/clock, VRAM, power, RAM,
  ping) via `nvidia-smi` + `Get-Counter`; persisted history + GPU/CPU trend chart.
- **FPS + benchmark** via **bundled PresentMon 1.10** (Intel, MIT).
- **CS2 setup** (detect, launch options, autoexec), **restore points** (list + create),
  **Settings**, **config export/import**.
- **19 Pester tests**; installer packages app + WebView2 DLLs + PresentMon; portable
  ZIP + **GitHub Release v2.0.0**.

## Remaining / Next
- **Code-signing** (needs a certificate): sign `Volante.exe` + the installer to remove
  the SmartScreen "unknown publisher" prompt. `tools\Sign.ps1` is ready;
  `tools\New-DevCert.ps1` makes a self-signed cert for lab use.
- **Inno installer for the release**: install Inno Setup 6, run `tools\Build-Installer.ps1`,
  then attach `dist\Volante-Setup-2.0.0.exe` to the v2.0.0 GitHub Release.
- **Live verification**: full click-through of `Volante.exe` — frameless drag/resize,
  per-tweak revert, benchmark FPS (elevated, with a game running), config export/import.
- **Continuous live FPS** (today FPS is benchmark-only) via a streaming PresentMon session.
- **Telemetry trends across sessions** (graphs from the persisted history); more game profiles.
- **Per-game NVIDIA/AMD control-panel automation** — risky / against the "no fragile
  binary pokes" ethos; needs a deliberate decision before building.
