# Working Memory

## Active Task
**v2.0.0 released.** Tag `v2.0.0` + GitHub Release published with the portable ZIP
(`dist\Volante-2.0.0-portable.zip`). All work on `main`.

## Remaining tasks
- [ ] **Code-signing** — provide a cert (`.pfx`) or run `tools\New-DevCert.ps1`, then
      `tools\Sign.ps1`; re-cut a signed `Volante.exe` (+ installer).
- [ ] **Inno installer** — install Inno Setup 6, run `tools\Build-Installer.ps1`, and
      attach `dist\Volante-Setup-2.0.0.exe` to the v2.0.0 GitHub Release.
- [ ] **Live verification** of `Volante.exe`: frameless drag/resize, per-tweak revert,
      benchmark FPS (elevated, with a game running), config export/import.
- [ ] **(Optional)** continuous live FPS (streaming PresentMon); cross-session telemetry
      graphs; more game profiles.
- [ ] **(Decision)** per-game NVIDIA/AMD control-panel automation — risky; needs a call.

## Recently completed (v2.0.0)
Full session: WebView2 app + bridge, live telemetry + persisted history, editable
profiles, CS2 setup, restore points, Settings, config export/import, bundled PresentMon,
19 Pester tests, portable ZIP + GitHub Release. See CHANGELOG.md.
