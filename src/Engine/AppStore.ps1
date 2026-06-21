<#
    Volante app state: real readiness score, game profiles, and history - persisted
    as JSON under %ProgramData%\Volante. Dot-sourced into Optimizer.Engine.psm1, so
    $script:DataRoot / Initialize-Store / engine functions resolve in module scope.
#>

$script:ProfilesFile = Join-Path $script:DataRoot 'profiles.json'
$script:HistoryFile  = Join-Path $script:DataRoot 'history.json'

# --- Readiness ---------------------------------------------------------------
# Computed from real signals already gathered for the dashboard (no extra pings).
function Get-ReadinessFrom {
    param($Refresh, $Drivers, $Pings)
    $cat = Get-TweakCatalog
    $rec = @($cat | Where-Object { $_.Recommended })
    $appliedCount = 0
    foreach ($t in $rec) { if ((Invoke-TweakTest $t).Applied) { $appliedCount++ } }
    $tweakRatio = if ($rec.Count) { $appliedCount / $rec.Count } else { 1 }

    $disp = @($Refresh); $dispBad = @($disp | Where-Object { -not $_.optimal }).Count
    $dispRatio = if ($disp.Count) { 1 - ($dispBad / $disp.Count) } else { 1 }

    $drv = @($Drivers); $drvStale = @($drv | Where-Object { $_.stale }).Count
    $drvRatio = if ($drv.Count) { 1 - ($drvStale / $drv.Count) } else { 1 }

    $reach = @($Pings | Where-Object { $null -ne $_.ms } | Sort-Object ms)
    $best = if ($reach.Count) { $reach[0].ms } else { $null }
    $pingScore = if ($null -eq $best) { 0.5 } elseif ($best -le 30) { 1 } elseif ($best -le 60) { 0.8 } elseif ($best -le 100) { 0.5 } else { 0.3 }

    $score  = [int][math]::Round((($tweakRatio * 0.5) + ($dispRatio * 0.15) + ($drvRatio * 0.15) + ($pingScore * 0.2)) * 100)
    $issues = ($rec.Count - $appliedCount) + $dispBad + $drvStale
    [pscustomobject]@{ score = $score; issues = $issues; tweaks = "$appliedCount/$($rec.Count)" }
}

# --- Game profiles -----------------------------------------------------------
function Get-DefaultProfiles {
    @(
        [pscustomobject]@{ id = 'cs2';      name = 'Counter-Strike 2';   tag = 'FPS - competitive' }
        [pscustomobject]@{ id = 'valorant'; name = 'Valorant';           tag = 'FPS - tactical' }
        [pscustomobject]@{ id = 'apex';     name = 'Apex Legends';       tag = 'Battle royale' }
        [pscustomobject]@{ id = 'fortnite'; name = 'Fortnite';           tag = 'BR - building' }
        [pscustomobject]@{ id = 'lol';      name = 'League of Legends';  tag = 'MOBA' }
        [pscustomobject]@{ id = 'global';   name = 'All games';          tag = 'System-wide' }
    )
}

# Which catalog tweaks a profile selects. Competitive shooters share a latency-
# focused set; 'global' uses the full recommended preset.
function Get-ProfileTweakIds {
    param([string]$Id)
    $competitive = @(
        'mouse-accel-off', 'gamedvr-off', 'game-mode-on', 'startup-delay-off', 'menu-show-delay',
        'system-responsiveness', 'games-task-priority', 'network-throttling-off',
        'power-ultimate', 'power-throttling-off', 'usb-selective-suspend-off', 'pcie-aspm-off'
    )
    switch ($Id) {
        'cs2'      { $competitive }
        'valorant' { $competitive }
        'apex'     { $competitive }
        'fortnite' { $competitive }
        'lol'      { @('mouse-accel-off', 'game-mode-on', 'startup-delay-off', 'menu-show-delay', 'power-ultimate') }
        default    { @((Get-TweakCatalog | Where-Object Recommended).Id) }
    }
}

function Get-AppProfiles {
    Initialize-Store
    $active = 'cs2'
    if (Test-Path -LiteralPath $script:ProfilesFile) {
        try { $j = Get-Content -LiteralPath $script:ProfilesFile -Raw | ConvertFrom-Json; if ($j.active) { $active = $j.active } } catch {}
    }
    [pscustomobject]@{ active = $active; list = Get-DefaultProfiles }
}

function Set-ActiveProfile {
    param([string]$Id)
    Initialize-Store
    [pscustomobject]@{ active = $Id } | ConvertTo-Json | Set-Content -LiteralPath $script:ProfilesFile -Encoding UTF8
    [pscustomobject]@{ active = $Id }
}

# --- History -----------------------------------------------------------------
function Get-RelativeTime {
    param([string]$IsoTime)
    try {
        $t = [datetime]::Parse($IsoTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $span = (Get-Date) - $t
        if ($span.TotalMinutes -lt 1)  { return 'just now' }
        if ($span.TotalMinutes -lt 60) { return ('{0}m ago' -f [int]$span.TotalMinutes) }
        if ($span.TotalHours   -lt 24) { return ('{0}h ago' -f [int]$span.TotalHours) }
        if ($span.TotalDays    -lt 2)  { return 'yesterday' }
        return ('{0}d ago' -f [int]$span.TotalDays)
    } catch { return '' }
}

function Add-AppHistory {
    param([string]$Type, [string]$Text)
    Initialize-Store
    $entry = [pscustomobject]@{ time = (Get-Date).ToString('o'); type = $Type; text = $Text }
    $existing = @()
    if (Test-Path -LiteralPath $script:HistoryFile) {
        try { $existing = @(Get-Content -LiteralPath $script:HistoryFile -Raw | ConvertFrom-Json) } catch {}
    }
    $all = @(@($entry) + $existing | Select-Object -First 100)
    ,$all | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:HistoryFile -Encoding UTF8
}

function Get-AppHistory {
    param([int]$Take = 12)
    Initialize-Store
    if (-not (Test-Path -LiteralPath $script:HistoryFile)) { return @() }
    try { $h = @(Get-Content -LiteralPath $script:HistoryFile -Raw | ConvertFrom-Json) } catch { return @() }
    @($h | Select-Object -First $Take | ForEach-Object {
        $cs = switch ("$($_.type)") { 'apply' { 'good' } 'revert' { 'ct' } 'check' { 'good' } 'driver' { 'warn' } 'benchmark' { 'good' } default { 'good' } }
        [pscustomobject]@{ text = $_.text; when = (Get-RelativeTime $_.time); type = $_.type; cs = $cs }
    })
}
