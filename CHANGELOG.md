# Changelog

## 2.0.0

A ground-up rebuild of the frontend with a real telemetry backend, while keeping
the same transparent, reversible PowerShell engine.

### Added
- **WebView2 desktop app** (`Volante.exe`): a no-console, frameless window (custom
  title bar, drag/resize, Win11 rounded corners) hosting a React UI in `src/WebUI`,
  bridged in-process to the PowerShell engine.
- **Dashboard** with a real **readiness score**; **System check** (refresh rate,
  GPU driver, Valve/Steam ping, CS2 control-panel recommendations, CS2 setup).
- **Tune**: apply / **Preview** (dry-run) / **Revert all** / **per-tweak revert**.
- **Live monitor**: real CPU + per-core / GPU util, temps, clock, VRAM, power, RAM,
  ping via `nvidia-smi` + `Get-Counter`; persisted telemetry history; dual-line
  GPU/CPU chart.
- **FPS + benchmark** via **bundled PresentMon 1.10** (Intel/GameTechDev, MIT).
- **Game profiles**: per-game tweak sets, editable/custom, persisted.
- **CS2 setup**: detect install, recommended launch options, autoexec writer.
- **Restore points**: list real Windows restore points + create on demand.
- **Settings**: driver-age threshold, monitor poll interval, PresentMon path, ping
  endpoints. **Config export/import** (profiles + settings).
- **Pester test suite** (engine + bridge).
- Read-only headless `Optimize.ps1 -Dashboard` report.

### Changed
- Build references the vendored Microsoft WebView2 SDK; the installer ships the
  WebView2 DLLs + PresentMon.
- "No bundled binaries" scoped to: no sketchy optimizer binaries — the only bundled
  binaries are the vetted WebView2 SDK and MIT PresentMon.

### Removed
- The legacy WPF GUI (`src/GUI`) and old native launcher (`src/Launcher.cs`).

## 1.0.0
- Initial Volante: PowerShell tweak engine + WPF GUI + headless mode.
