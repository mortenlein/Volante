<#
    Creates a SELF-SIGNED code-signing certificate for TESTING the signing pipeline.

    A self-signed cert removes the "unknown publisher" SmartScreen/UAC warning ONLY
    on machines that trust it (your own PCs / a managed fleet where you deploy the
    cert to Trusted Publishers). For PUBLIC distribution you need a CA-issued
    code-signing certificate - ideally EV, which gets SmartScreen reputation instantly.

    Examples:
      tools\New-DevCert.ps1
      tools\New-DevCert.ps1 -ExportPfx dev.pfx
#>
param(
    [string]       $Subject = 'CN=Volante Dev',
    [string]       $ExportPfx,
    [securestring] $PfxPassword
)
$ErrorActionPreference = 'Stop'

$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeyUsage DigitalSignature `
    -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(3)

Write-Host "Created code-signing cert: $($cert.Subject)"
Write-Host "Thumbprint: $($cert.Thumbprint)"

if ($ExportPfx) {
    if (-not $PfxPassword) { $PfxPassword = Read-Host 'PFX password' -AsSecureString }
    Export-PfxCertificate -Cert $cert -FilePath $ExportPfx -Password $PfxPassword | Out-Null
    Write-Host "Exported PFX: $ExportPfx"
}
Write-Host "Now sign with:  tools\Sign.ps1 -Thumbprint $($cert.Thumbprint)"
Write-Host "(Self-signed: trusted only where you install this cert.)"
