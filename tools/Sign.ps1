<#
    Authenticode code-signing for Volante.exe and the installer.
    Use a .pfx file OR an installed certificate (by thumbprint). An RFC3161
    timestamp is added by default so signatures stay valid after the cert expires.

    Examples:
      tools\Sign.ps1 -PfxPath cert.pfx
      tools\Sign.ps1 -Thumbprint ABC123...                       # cert already in your store
      tools\Sign.ps1 -PfxPath cert.pfx -Path Volante.exe,dist\Volante-Setup-1.0.0.exe
#>
[CmdletBinding(DefaultParameterSetName = 'Pfx')]
param(
    [Parameter(ParameterSetName = 'Pfx', Mandatory)] [string]       $PfxPath,
    [Parameter(ParameterSetName = 'Pfx')]            [securestring] $PfxPassword,
    [Parameter(ParameterSetName = 'Store', Mandatory)][string]      $Thumbprint,
    [string[]] $Path,
    [string]   $TimestampUrl = 'http://timestamp.digicert.com',
    [switch]   $NoTimestamp
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Default targets: the exe plus any built installer.
if (-not $Path) {
    $Path = @("$root\Volante.exe")
    Get-ChildItem "$root\dist\*.exe" -ErrorAction SilentlyContinue | ForEach-Object { $Path += $_.FullName }
}

# Resolve the signing certificate (with its private key).
if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
    if (-not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath" }
    if (-not $PfxPassword) { $PfxPassword = Read-Host 'PFX password' -AsSecureString }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        (Resolve-Path $PfxPath).Path, $PfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
} else {
    $cert = Get-Item "Cert:\CurrentUser\My\$Thumbprint"  -ErrorAction SilentlyContinue
    if (-not $cert) { $cert = Get-Item "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction SilentlyContinue }
    if (-not $cert) { throw "No certificate with thumbprint $Thumbprint in CurrentUser\My or LocalMachine\My." }
}
if (-not $cert.HasPrivateKey) { throw 'Certificate has no private key - cannot sign.' }

foreach ($f in $Path) {
    if (-not (Test-Path $f)) { Write-Warning "skip (not found): $f"; continue }
    $p = @{ FilePath = $f; Certificate = $cert; HashAlgorithm = 'SHA256' }
    if (-not $NoTimestamp) { $p.TimestampServer = $TimestampUrl }
    $sig = Set-AuthenticodeSignature @p
    "{0,-34} {1}" -f (Split-Path $f -Leaf), $sig.Status
}
