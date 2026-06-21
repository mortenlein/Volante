<#
    Volante - entry point.
    No arguments  -> launches the GUI (elevating if needed).
    Any action arg-> headless mode (no prompts), for deployed PCs.

    Examples:
      .\Optimize.ps1                              # GUI
      .\Optimize.ps1 -List                        # show catalog
      .\Optimize.ps1 -Report                      # show current state, change nothing
      .\Optimize.ps1 -Headless -Recommended       # apply the recommended preset
      .\Optimize.ps1 -Headless -Recommended -DryRun
      .\Optimize.ps1 -Headless -Apply mouse-accel-off,gamedvr-off
      .\Optimize.ps1 -Headless -ProfilePath .\config\recommended.json
      .\Optimize.ps1 -Headless -RevertAll
#>
#requires -version 5.1
[CmdletBinding()]
param(
    [switch]   $Headless,
    [switch]   $Report,
    [switch]   $Dashboard,
    [switch]   $DryRun,
    [switch]   $Recommended,
    [switch]   $All,
    [string[]] $Apply,
    [string[]] $Revert,
    [switch]   $RevertAll,
    [string]   $ProfilePath,
    [switch]   $NoRestorePoint,
    [switch]   $List,
    [switch]   $NoElevate
)

$enginePath = Join-Path $PSScriptRoot 'src\Engine\Optimizer.Engine.psm1'
Import-Module $enginePath -Force

# --- List (read-only, no admin) ---------------------------------------------
if ($List) {
    Get-TweakCatalog |
        Select-Object Id, Category, Risk, Scope, Recommended, Name |
        Format-Table -AutoSize
    return
}

# --- Dashboard (read-only diagnostics, no admin) ----------------------------
if ($Dashboard) {
    Write-Host ''
    Write-Host '=== Monitor refresh rate ==='
    foreach ($d in (Get-RefreshRateStatus)) {
        $tag = if ($d.IsOptimal) { 'OK (at max)' } else { "-> supports up to $($d.MaxHz) Hz" }
        '{0,-30} {1}x{2}  {3} Hz  {4}' -f $d.Name, $d.Width, $d.Height, $d.CurrentHz, $tag
    }
    Write-Host ''
    Write-Host '=== GPU driver ==='
    foreach ($g in (Get-GpuDriverStatus)) {
        $mk  = if ($g.MarketingVersion) { " ($($g.Vendor) $($g.MarketingVersion))" } else { '' }
        $age = if ($null -ne $g.AgeDays) { "$($g.AgeDays)d old" } else { 'date unknown' }
        $st  = if ($g.IsStale) { 'STALE - check for a newer one' } else { 'recent' }
        '{0,-30} {1}{2}  {3}  {4}' -f $g.Name, $g.DriverVersion, $mk, $age, $st
    }
    Write-Host ''
    Write-Host '=== Ping to Valve / Steam (TCP latency) ==='
    foreach ($p in (Get-ValvePing)) {
        $ms = if ($null -ne $p.Ms) { "$($p.Ms) ms" } else { 'timeout' }
        $b  = if ($p.Best) { ' (best)' } else { '' }
        '{0,-28} {1}{2}' -f $p.Label, $ms, $b
    }
    Write-Host ''
    $cp = Get-GpuControlPanelRecommendations
    Write-Host "=== CS2 control-panel settings ($($cp.Vendor)) ==="
    foreach ($it in $cp.Items) {
        '{0,-36} -> {1,-28} (current: {2})' -f $it.Setting, $it.Recommended, $it.Current
    }
    Write-Host ''
    return
}

$noAction = -not ($Headless -or $Report -or $Dashboard -or $DryRun -or $Recommended -or $All -or
                  $Apply -or $Revert -or $RevertAll -or $ProfilePath)

# --- App (GUI) mode ----------------------------------------------------------
# The UI is the WebView2 desktop app (Volante.exe): it self-elevates (admin
# manifest) and renders src\WebUI through the in-process engine bridge.
if ($noAction) {
    $exe = Join-Path $PSScriptRoot 'Volante.exe'
    if (Test-Path $exe) { Start-Process -FilePath $exe; return }
    Write-Host 'Volante.exe not found. Build it with: tools\Build-Exe.ps1' -ForegroundColor Yellow
    Write-Host '(or run headless, e.g.  .\Optimize.ps1 -Dashboard  /  -Report  /  -Headless -Recommended)'
    return
}

# --- Headless / CLI ----------------------------------------------------------
$catalog = Get-TweakCatalog
Write-Log "Volante (headless) - admin=$([bool](Test-IsAdmin)) dryrun=$([bool]$DryRun)" 'INFO'

if ($Report) {
    Write-Host ''
    foreach ($t in $catalog) {
        $s = Invoke-TweakTest $t
        '{0,-26} {1,-9} applied={2,-5} {3}' -f $t.Id, $t.Risk, $s.Applied, $s.Current
    }
    return
}

# Resolve which tweaks to apply
$ids = @()
if ($All)              { $ids = $catalog.Id }
elseif ($Recommended)  { $ids = Get-RecommendedIds }
elseif ($Apply)        { $ids = $Apply }
elseif ($ProfilePath)  { $ids = Import-OptimizerProfile -Path $ProfilePath }

# Resolve which to revert
$revIds = @()
if ($RevertAll)   { $revIds = $catalog.Id }
elseif ($Revert)  { $revIds = $Revert }

if ($ids.Count -gt 0 -and -not $NoRestorePoint -and -not $DryRun) {
    New-OptimizerRestorePoint | Out-Null
}

$fail = 0
foreach ($id in $ids) {
    $t = $catalog | Where-Object Id -eq $id | Select-Object -First 1
    if (-not $t) { Write-Log "Unknown tweak id: $id" 'WARN'; continue }
    $r = Invoke-TweakApply $t -DryRun:$DryRun
    if ($r.Result -eq 'Failed') { $fail++ }
}
foreach ($id in $revIds) {
    $t = $catalog | Where-Object Id -eq $id | Select-Object -First 1
    if (-not $t) { Write-Log "Unknown tweak id: $id" 'WARN'; continue }
    $r = Invoke-TweakRevert $t -DryRun:$DryRun
    if ($r.Result -eq 'Failed') { $fail++ }
}

$doneLevel = 'OK'; if ($fail) { $doneLevel = 'WARN' }
Write-Log "Volante done. Failures=$fail" $doneLevel
exit $fail
