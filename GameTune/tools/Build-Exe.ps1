<#
    Builds GameTune.exe from src\Launcher.cs using the .NET Framework C# compiler
    (csc.exe, present on every Windows box - no install or internet needed).

    Result: a double-clickable Windows app with an icon, an embedded admin
    manifest (auto-UAC), and no console window. The .ps1 engine stays on disk
    beside it, so the logic remains auditable and editable.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Exe.ps1
#>
$ErrorActionPreference = 'Stop'

$root     = Split-Path $PSScriptRoot -Parent
$src      = Join-Path $root 'src\Launcher.cs'
$manifest = Join-Path $root 'src\app.manifest'
$icon     = Join-Path $root 'assets\gametune.ico'
$out      = Join-Path $root 'GameTune.exe'

# 1) Icon
if (-not (Test-Path $icon)) {
    Write-Host 'Generating icon...'
    & (Join-Path $PSScriptRoot 'New-Icon.ps1')
}

# 2) Locate the C# compiler (.NET Framework 4.x).
$csc = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw 'csc.exe not found - .NET Framework 4.x is required to build.' }

# 3) Compile a Windows (no-console) exe with icon + admin manifest.
Write-Host 'Building GameTune.exe...'
$cscArgs = @(
    '/nologo', '/target:winexe', "/out:$out",
    "/win32icon:$icon", "/win32manifest:$manifest",
    '/reference:System.Windows.Forms.dll',
    $src
)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE." }

if (Test-Path $out) {
    Write-Host ("Built: {0} ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1kb))
    Write-Host 'Double-click GameTune.exe to launch (UAC will prompt automatically).'
    Write-Host 'NOTE: unsigned - first run may show SmartScreen (More info > Run anyway).'
} else {
    throw 'Build did not produce GameTune.exe.'
}
