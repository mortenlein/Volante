<#
    One-shot release build:  exe  ->  (sign)  ->  installer  ->  (sign).
    Signing steps run only if you provide a certificate (-PfxPath or -Thumbprint);
    otherwise they are skipped and you get an unsigned build.

    Examples:
      tools\Build-Release.ps1                       # unsigned exe + installer
      tools\Build-Release.ps1 -Thumbprint ABC123... # sign with an installed cert
      tools\Build-Release.ps1 -PfxPath cert.pfx
#>
param(
    [string]       $PfxPath,
    [securestring] $PfxPassword,
    [string]       $Thumbprint
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Invoke-Sign($files) {
    if (-not ($PfxPath -or $Thumbprint)) { Write-Host '  (no certificate provided - skipping signing)'; return }
    $p = @{ Path = $files }
    if ($Thumbprint) { $p.Thumbprint = $Thumbprint }
    else { $p.PfxPath = $PfxPath; if ($PfxPassword) { $p.PfxPassword = $PfxPassword } }
    & (Join-Path $PSScriptRoot 'Sign.ps1') @p
}

Write-Host '== 1/4  Build Volante.exe =='
& (Join-Path $PSScriptRoot 'Build-Exe.ps1')

Write-Host '== 2/4  Sign Volante.exe =='
Invoke-Sign @("$root\Volante.exe")

Write-Host '== 3/4  Build installer =='
& (Join-Path $PSScriptRoot 'Build-Installer.ps1')

Write-Host '== 4/4  Sign installer =='
$setup = @(Get-ChildItem "$root\dist\*.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
if ($setup.Count) { Invoke-Sign $setup } else { Write-Host '  (no installer found to sign)' }

Write-Host 'Release build complete.'
