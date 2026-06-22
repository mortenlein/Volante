# Mission: Volante

## Core Goal
Provide a transparent, truly reversible Windows 10/11 game-tweaking tool with a clean GUI and headless mode, excluding dangerous or placebo registry cleaner practices.

## Tech Stack
- Core Engine: Windows PowerShell 5.1 (Optimize.ps1 + src/Engine modules)
- GUI Frontend: WebView2 desktop app rendering a React UI (src/WebUI), bridged to the
  engine in-process via JSON (src/Host/VolanteHost.cs). The legacy WPF GUI has been removed.
- Telemetry: nvidia-smi + Get-Counter; bundled PresentMon (MIT) for FPS.

