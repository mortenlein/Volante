<#
    Builds Volante.exe (the WebView2 desktop host) from src\Host\VolanteHost.cs using
    the .NET Framework C# compiler (csc.exe, present on every Windows box - no install
    or internet needed). It references the vendored Microsoft WebView2 SDK DLLs in
    lib\webview2 and copies them (incl. the native WebView2Loader.dll) next to the exe.

    Result: a double-clickable Windows app with an icon, an embedded admin manifest
    (auto-UAC), and no console window. It renders the web UI in src\WebUI and bridges
    to the .ps1 engine, which stays on disk beside it (auditable and editable).

    Requires the Edge WebView2 Runtime (ships with Windows 11; Evergreen elsewhere).

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Exe.ps1
#>
$ErrorActionPreference = 'Stop'

$root     = Split-Path $PSScriptRoot -Parent
$src      = Join-Path $root 'src\Host\VolanteHost.cs'
$manifest = Join-Path $root 'src\app.manifest'
$icon     = Join-Path $root 'assets\volante.ico'
$out      = Join-Path $root 'Volante.exe'
$wv2Dir   = Join-Path $root 'lib\webview2'
$wv2Core  = Join-Path $wv2Dir 'Microsoft.Web.WebView2.Core.dll'
$wv2Forms = Join-Path $wv2Dir 'Microsoft.Web.WebView2.WinForms.dll'
$wv2Load  = Join-Path $wv2Dir 'WebView2Loader.dll'

foreach ($dep in @($wv2Core, $wv2Forms, $wv2Load)) {
    if (-not (Test-Path $dep)) {
        throw "Missing WebView2 SDK file: $dep`nVendor the Microsoft.Web.WebView2 NuGet package into lib\webview2 (see lib\webview2\VERSION.txt)."
    }
}

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
#    System.Management.Automation lives in the GAC, not the reference-assembly
#    folder, so resolve its full path from the running PowerShell (5.1).
$sma = [psobject].Assembly.Location
Write-Host 'Building Volante.exe (WebView2 host)...'
$cscArgs = @(
    '/nologo', '/target:winexe', "/out:$out",
    "/win32icon:$icon", "/win32manifest:$manifest",
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    "/reference:$sma",
    "/reference:$wv2Core",
    "/reference:$wv2Forms",
    $src
)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE." }

# 4) Stage the WebView2 SDK DLLs next to the exe (managed + native loader).
foreach ($dll in @($wv2Core, $wv2Forms, $wv2Load)) {
    Copy-Item -LiteralPath $dll -Destination $root -Force
}

if (Test-Path $out) {
    Write-Host ("Built: {0} ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1kb))
    Write-Host 'Staged WebView2 DLLs next to Volante.exe.'
    Write-Host 'Double-click Volante.exe to launch (UAC will prompt automatically).'
    Write-Host 'NOTE: unsigned - first run may show SmartScreen (More info > Run anyway).'
} else {
    throw 'Build did not produce Volante.exe.'
}
