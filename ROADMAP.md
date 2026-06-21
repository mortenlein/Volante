# Roadmap

## Done
- **WebView2 desktop app** (React UI in `src/WebUI`) over the PowerShell engine,
  replacing the WPF GUI; JS↔engine JSON bridge hosted in-process.
- **Dashboard** with a real readiness score; **System check** (refresh rate, GPU
  driver, Valve/Steam ping, CS2 control-panel recs, CS2 setup).
- **Tune**: tweak catalog with apply / revert / dry-run **Preview**; **profiles**
  drive the selected tweak set.
- **Monitor**: live telemetry (CPU + per-core, GPU util/temp/clock, VRAM, power,
  RAM, ping) via `nvidia-smi` + `Get-Counter` — no bundled binaries.
- **Profiles / history** persisted under `%ProgramData%\Volante`.
- **Optional FPS** via PresentMon (detected, not bundled) + benchmark.
- **CS2 setup**: detect install, recommended launch options, autoexec writer.
- **Pester** test suite; installer packages the app + WebView2 DLLs.

## Next
- Real FPS without the PresentMon dependency, or bundle a vetted PresentMon build.
- Safe per-game NVIDIA/AMD control-panel automation (currently detect + guide).
- Code-signing to remove the SmartScreen prompt.
- Telemetry history/graphs, more game profiles, richer benchmark report.
