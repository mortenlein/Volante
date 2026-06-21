<#
    Volante user settings - persisted as JSON under %ProgramData%\Volante.
    Tunes engine behaviour: stale-driver threshold, telemetry poll interval, an
    explicit PresentMon path, and custom ping targets. Dot-sourced into
    Optimizer.Engine.psm1 (module scope).
#>

$script:SettingsFile = Join-Path $script:DataRoot 'settings.json'

function Get-DefaultSettings {
    [pscustomobject]@{
        staleDriverDays = 90
        monitorPollMs   = 1000
        presentMonPath  = ''
        pingTargets     = @()   # empty -> built-in Get-ValvePingTargets defaults
    }
}

function Get-AppSettings {
    Initialize-Store
    $d = Get-DefaultSettings
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
            if ($j.staleDriverDays) { $d.staleDriverDays = [int]$j.staleDriverDays }
            if ($j.monitorPollMs)   { $d.monitorPollMs   = [int]$j.monitorPollMs }
            if ($null -ne $j.presentMonPath) { $d.presentMonPath = "$($j.presentMonPath)" }
            if ($j.pingTargets)     { $d.pingTargets = @($j.pingTargets) }
        } catch {}
    }
    $d
}

function Set-AppSettings {
    param($StaleDriverDays, $MonitorPollMs, $PresentMonPath)
    $s = Get-AppSettings
    if ($StaleDriverDays) { $s.staleDriverDays = [int]$StaleDriverDays }
    if ($MonitorPollMs)   { $s.monitorPollMs   = [int]$MonitorPollMs }
    if ($null -ne $PresentMonPath) { $s.presentMonPath = "$PresentMonPath" }
    Initialize-Store
    [pscustomobject]@{
        staleDriverDays = $s.staleDriverDays
        monitorPollMs   = $s.monitorPollMs
        presentMonPath  = $s.presentMonPath
        pingTargets     = $s.pingTargets
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    Get-AppSettings
}
