<#
    Volante config export/import: bundle game profiles (active + custom tweak sets)
    and settings into a shareable JSON file under Documents\Volante, and apply one
    back. Reuses the profile store (AppStore.ps1) and settings (Settings.ps1).
    Dot-sourced into Optimizer.Engine.psm1.
#>

function Get-ConfigPath {
    $dir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Volante'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir 'volante-config.json'
}

function Export-AppConfig {
    param([string]$Path)
    if (-not $Path) { $Path = Get-ConfigPath }
    $store = Get-ProfileStore
    $cfg = [pscustomobject]@{
        app      = 'Volante'
        version  = 1
        exported = (Get-Date).ToString('o')
        profiles = [pscustomobject]@{ active = $store.active; custom = $store.custom }
        settings = Get-AppSettings
    }
    $json = $cfg | ConvertTo-Json -Depth 8
    try {
        $json | Set-Content -LiteralPath $Path -Encoding UTF8
        [pscustomobject]@{ ok = $true; path = $Path; json = $json }
    } catch {
        [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)" }
    }
}

function Import-AppConfig {
    param([string]$Path)
    if (-not $Path) { $Path = Get-ConfigPath }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ ok = $false; error = "No config file at $Path" } }
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $profilesApplied = 0; $settingsApplied = $false
        if ($cfg.profiles) {
            $s = Get-ProfileStore
            if ($cfg.profiles.active) { $s.active = $cfg.profiles.active }
            if ($cfg.profiles.custom) {
                $h = @{}
                foreach ($p in $cfg.profiles.custom.PSObject.Properties) { $h[$p.Name] = @($p.Value); $profilesApplied++ }
                $s.custom = $h
            }
            Save-ProfileStore $s
        }
        if ($cfg.settings) {
            Set-AppSettings -StaleDriverDays $cfg.settings.staleDriverDays -MonitorPollMs $cfg.settings.monitorPollMs -PresentMonPath $cfg.settings.presentMonPath | Out-Null
            $settingsApplied = $true
        }
        Add-AppHistory -Type 'apply' -Text "Imported config ($profilesApplied profile set(s))"
        [pscustomobject]@{ ok = $true; path = $Path; profiles = $profilesApplied; settings = $settingsApplied }
    } catch {
        [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)" }
    }
}
