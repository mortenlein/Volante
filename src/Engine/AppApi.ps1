<#
    Volante app API - the command dispatcher for the WebView2 UI bridge.
    The C# host hands each UI message (JSON: {id, command, args}) to
    Invoke-VolanteCommand, which routes to the engine and returns a JSON envelope
    ({id, ok, data} | {id, ok:false, error}). All routing lives here (in plain,
    auditable PowerShell) so the C# host stays a dumb pipe. Dot-sourced into
    Optimizer.Engine.psm1, so engine functions resolve in module scope.
#>

# --- Projections into the redesign's UI shapes -------------------------------
function Get-AppRefresh {
    @(Get-RefreshRateStatus | ForEach-Object {
        [pscustomobject]@{
            gpu     = $_.Name
            res     = ('{0} x {1}' -f $_.Width, $_.Height)
            hz      = $_.CurrentHz
            maxHz   = $_.MaxHz
            device  = $_.Device
            optimal = [bool]$_.IsOptimal
            note    = $(if ($_.IsOptimal) { 'Already at the highest supported.' }
                        else { "Your display supports up to $($_.MaxHz) Hz." })
        }
    })
}

function Get-AppDrivers {
    @(Get-GpuDriverStatus | ForEach-Object {
        $ver = $_.DriverVersion
        if ($_.MarketingVersion) { $ver = "$($_.DriverVersion) - $($_.Vendor) $($_.MarketingVersion)" }
        [pscustomobject]@{
            name    = $_.Name
            version = $ver
            date    = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { 'unknown' })
            ago     = $_.AgeDays
            stale   = [bool]$_.IsStale
            url     = $_.DownloadUrl
        }
    })
}

function Get-AppPings {
    @(Get-ValvePing | ForEach-Object {
        [pscustomobject]@{ name = $_.Label; ms = $_.Ms; best = [bool]$_.Best }
    })
}

function Get-AppControlPanel {
    $cp = Get-GpuControlPanelRecommendations
    [pscustomobject]@{
        vendor = $cp.Vendor
        items  = @($cp.Items | ForEach-Object {
            $cur = "$($_.Current)"; $rec = "$($_.Recommended)"
            $cs = 'verify'
            if     ($cur -eq $rec)        { $cs = 'good' }
            elseif ($cur -notlike 'Verify*') { $cs = 'warn' }
            [pscustomobject]@{ name = $_.Setting; rec = $_.Recommended; cur = $_.Current; cs = $cs }
        })
    }
}

function Get-DashboardData {
    $refresh = Get-AppRefresh
    $drivers = Get-AppDrivers
    $pings   = Get-AppPings
    [pscustomobject]@{
        refresh   = $refresh
        drivers   = $drivers
        pings     = $pings
        cp        = Get-AppControlPanel
        readiness = Get-ReadinessFrom -Refresh $refresh -Drivers $drivers -Pings $pings
    }
}

# Project the tweak catalog into the design's tweak-card shape. `id` is the real
# catalog id, so applyTweaks just passes ids straight back to the engine. When a
# profile is given, its tweak set drives which cards start enabled.
function Get-TweakCards {
    param([string]$Profile)
    $set = if ($Profile) { @(Get-ProfileTweakIds -Id $Profile) } else { $null }
    @(Get-TweakCatalog | ForEach-Object {
        $s = Invoke-TweakTest $_
        $inSet = if ($null -ne $set) { $set -contains $_.Id } else { [bool]$_.Recommended }
        [pscustomobject]@{
            id      = $_.Id
            name    = $_.Name
            desc    = $_.Description
            cat     = $_.Category
            risk    = $_.Risk
            applied = [bool]$s.Applied
            value   = $(if ($s.Applied) { 'Applied' } else { 'Off' })
            enabled = [bool]($inSet -and -not $s.Applied)
        }
    })
}

function Invoke-ApplyTweakIds {
    param([string[]]$Ids, [string]$Profile, [switch]$DryRun)
    $cat = Get-TweakCatalog
    $applied = 0; $failed = 0; $skipped = 0; $reboot = $false; $would = 0
    if (-not $DryRun -and @($Ids).Count -gt 0 -and (Test-IsAdmin)) { New-OptimizerRestorePoint | Out-Null }
    foreach ($id in @($Ids)) {
        $t = $cat | Where-Object Id -eq $id | Select-Object -First 1
        if (-not $t) { continue }
        $r = Invoke-TweakApply $t -DryRun:$DryRun
        switch ($r.Result) {
            'Applied'    { $applied++; if ($t.RebootRequired) { $reboot = $true } }
            'WouldApply' { $would++;   if ($t.RebootRequired) { $reboot = $true } }
            'Failed'     { $failed++ }
            'Skipped'    { $skipped++ }
        }
    }
    if (-not $DryRun -and $applied -gt 0) {
        $label = if ($Profile) { " - $Profile" } else { '' }
        Add-AppHistory -Type 'apply' -Text "Applied $applied tweak(s)$label"
    }
    [pscustomobject]@{ applied = $applied; would = $would; failed = $failed; skipped = $skipped; reboot = $reboot; dryRun = [bool]$DryRun }
}

function Invoke-RevertAllTweaks {
    $n = 0
    foreach ($t in (Get-TweakCatalog)) {
        if ((Invoke-TweakRevert $t).Result -eq 'Reverted') { $n++ }
    }
    if ($n -gt 0) { Add-AppHistory -Type 'revert' -Text "Reverted $n change(s)" }
    [pscustomobject]@{ reverted = $n }
}

function Invoke-RevertTweakIds {
    param([string[]]$Ids)
    $cat = Get-TweakCatalog
    $n = 0
    foreach ($id in @($Ids)) {
        $t = $cat | Where-Object Id -eq $id | Select-Object -First 1
        if ($t -and (Invoke-TweakRevert $t).Result -eq 'Reverted') { $n++ }
    }
    if ($n -gt 0) { Add-AppHistory -Type 'revert' -Text "Reverted $n tweak(s)" }
    [pscustomobject]@{ reverted = $n }
}

# Real Windows System Restore points (newest first). Needs admin; empty if disabled.
function Get-AppRestorePoints {
    try {
        @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending |
            Select-Object -First 10 | ForEach-Object {
                $when = "$($_.CreationTime)"
                try { $when = [System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime).ToString('yyyy-MM-dd HH:mm') } catch {}
                [pscustomobject]@{ seq = $_.SequenceNumber; description = "$($_.Description)"; when = $when }
            })
    } catch { @() }
}

# --- Single entry point the host calls ---------------------------------------
function Invoke-VolanteCommand {
    param([string]$Message)
    $id = $null
    try {
        $req = $Message | ConvertFrom-Json
        $id  = $req.id
        $a   = $req.args
        $data = switch ($req.command) {
            'getDashboard'     { Get-DashboardData }
            'getTweaks'        { Get-TweakCards -Profile $a.profile }
            'getMonitor'       { Get-MonitorTelemetry }
            'getTelemetryHistory' { Get-TelemetryHistory -Take $(if ($a.take) { [int]$a.take } else { 60 }) }
            'rerunChecks'      { Add-AppHistory -Type 'check' -Text 'Ran system check'; Get-DashboardData }
            'applyTweaks'      { Invoke-ApplyTweakIds -Ids @($a.ids) -Profile $a.profile }
            'previewTweaks'    { Invoke-ApplyTweakIds -Ids @($a.ids) -DryRun }
            'revertAll'        { Invoke-RevertAllTweaks }
            'revertTweaks'     { Invoke-RevertTweakIds -Ids @($a.ids) }
            'getRestorePoints' { Get-AppRestorePoints }
            'getProfiles'      { Get-AppProfiles }
            'setProfile'       { Set-ActiveProfile -Id $a.id }
            'saveProfile'      { Save-ProfileTweaks -Id $a.id -Ids @($a.ids) }
            'resetProfile'     { Reset-ProfileTweaks -Id $a.id | Out-Null; Get-TweakCards -Profile $a.id }
            'getHistory'       { Get-AppHistory -Take 12 }
            'fpsAvailable'     { [pscustomobject]@{ available = (Get-FpsAvailable) } }
            'getSettings'      { Get-AppSettings }
            'setSettings'      { Set-AppSettings -StaleDriverDays $a.staleDriverDays -MonitorPollMs $a.monitorPollMs -PresentMonPath $a.presentMonPath }
            'exportConfig'     { Export-AppConfig }
            'importConfig'     { Import-AppConfig -Path $a.path }
            'getCs2'           { Get-Cs2Info }
            'writeCs2Autoexec' { $r = Set-Cs2Autoexec; if ($r.ok) { Add-AppHistory -Type 'apply' -Text 'Wrote CS2 autoexec.cfg' }; $r }
            'runBenchmark'     {
                $b = Invoke-FpsBenchmark -Seconds $(if ($a.seconds) { [int]$a.seconds } else { 20 })
                if ($b.ok) { Add-AppHistory -Type 'benchmark' -Text "Benchmark: $($b.avg) avg / $($b.low1) 1% low fps" }
                $b
            }
            'setMaxRefresh'    { Set-MaxRefreshRate -Device $a.device -Hz ([int]$a.hz) }
            'restorePoint'     { [pscustomobject]@{ ok = [bool](New-OptimizerRestorePoint) } }
            'openControlPanel' { [pscustomobject]@{ ok = [bool](Open-GpuControlPanel -Vendor $a.vendor) } }
            'openUrl'          { Start-Process $a.url; [pscustomobject]@{ ok = $true } }
            'isAdmin'          { [pscustomobject]@{ admin = [bool](Test-IsAdmin) } }
            default            { throw "Unknown command: $($req.command)" }
        }
        [pscustomobject]@{ id = $id; ok = $true; data = $data } | ConvertTo-Json -Depth 10 -Compress
    } catch {
        [pscustomobject]@{ id = $id; ok = $false; error = "$($_.Exception.Message)" } | ConvertTo-Json -Depth 4 -Compress
    }
}
