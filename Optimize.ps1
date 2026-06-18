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

$noAction = -not ($Headless -or $Report -or $DryRun -or $Recommended -or $All -or
                  $Apply -or $Revert -or $RevertAll -or $ProfilePath)

# --- GUI mode ----------------------------------------------------------------
if ($noAction) {
    if (-not (Test-IsAdmin) -and -not $NoElevate) {
        Write-Host 'Elevating for full access (machine tweaks need admin)...'
        $relaunch = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath
        Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunch
        return
    }
    & (Join-Path $PSScriptRoot 'src\GUI\Show-OptimizerGui.ps1') -EnginePath $enginePath
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
