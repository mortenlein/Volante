<#
    Compiles installer\GameTune.iss into dist\GameTune-Setup-<ver>.exe using Inno
    Setup's command-line compiler (ISCC.exe).

    Inno Setup 6 must be installed (free): https://jrsoftware.org/isdl.php
    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Installer.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$iss  = Join-Path $root 'installer\GameTune.iss'
$exe  = Join-Path $root 'GameTune.exe'

if (-not (Test-Path $exe)) { throw 'GameTune.exe not found - run tools\Build-Exe.ps1 first.' }

# Known install locations (machine-wide and per-user), v6 and v5.
$candidates = @(
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 5\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 5\ISCC.exe"
)
# Plus any install location the registry knows about (covers winget/custom paths).
foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    Get-ItemProperty $r -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Inno Setup' -and $_.InstallLocation } |
        ForEach-Object { $candidates += (Join-Path $_.InstallLocation 'ISCC.exe') }
}
$iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw 'Inno Setup (ISCC.exe) not found. Install it (free): https://jrsoftware.org/isdl.php'
}

Write-Host "Compiling installer with $iscc ..."
& $iscc $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE." }

Get-ChildItem (Join-Path $root 'dist\*.exe') -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "Built: $($_.FullName)" }
