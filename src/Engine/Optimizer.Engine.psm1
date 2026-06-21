<#
    Volante engine - pure logic, no UI.
    Provides: logging, admin check, restore point, a tracked backup store
    (for TRUE revert), and apply/revert/test wrappers over the tweak catalog.
    Target: Windows PowerShell 5.1 (STA), Windows 10/11.
#>

$ErrorActionPreference = 'Stop'

# --- Paths -------------------------------------------------------------------
$script:DataRoot   = Join-Path $env:ProgramData 'Volante'
$script:LogDir     = Join-Path $script:DataRoot  'logs'
$script:BackupFile = Join-Path $script:DataRoot  'backup.json'
$script:LogFile    = Join-Path $script:LogDir    ('volante_{0:yyyyMMdd}.log' -f (Get-Date))
$script:LogSink    = $null   # optional callback (GUI) -> & $sink $line $level

function Initialize-Store {
    foreach ($d in @($script:DataRoot, $script:LogDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# --- Logging -----------------------------------------------------------------
function Set-LogSink { param([scriptblock]$Sink) $script:LogSink = $Sink }

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')] [string]$Level = 'INFO'
    )
    Initialize-Store
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line } catch {}
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:LogSink) { try { & $script:LogSink $line $Level } catch {} }
}

# --- Privilege / safety ------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-OptimizerRestorePoint {
    param([string]$Description = 'Volante - before tweaks')
    if (-not (Test-IsAdmin)) { Write-Log 'Restore point skipped (needs admin).' 'WARN'; return $false }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS'
        Write-Log "Restore point created: $Description" 'OK'
        return $true
    } catch {
        # Windows rate-limits restore points to one per 24h by default; treat as non-fatal.
        Write-Log "Restore point not created: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# --- Backup store (enables TRUE revert) --------------------------------------
function Get-BackupRecords {
    Initialize-Store
    if (-not (Test-Path -LiteralPath $script:BackupFile)) { return @() }
    $raw = Get-Content -LiteralPath $script:BackupFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json)
}

function Save-BackupRecords {
    param($Records)
    $arr = @($Records)
    if ($arr.Count -eq 0) { '[]' | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8; return }
    ,$arr | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:BackupFile -Encoding UTF8
}

function Get-RegValueSafe {
    param($Path, $Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$Name
}

function Get-RegKind {
    param($Path, $Name)
    try { return "$((Get-Item -LiteralPath $Path -ErrorAction Stop).GetValueKind($Name))" }
    catch { return $null }
}

# Set a registry value, capturing the original ONCE so it can be reverted.
function Set-TrackedValue {
    param(
        [string]$TweakId, [string]$Path, [string]$Name,
        [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')] [string]$Type,
        $Value
    )
    $records = Get-BackupRecords
    $tracked = $records | Where-Object {
        $_.tweakId -eq $TweakId -and $_.kind -eq 'reg' -and $_.path -eq $Path -and $_.name -eq $Name }
    if (-not $tracked) {
        $had = $false; $orig = $null; $origType = $Type
        $kind = Get-RegKind -Path $Path -Name $Name
        if ($kind) { $had = $true; $orig = Get-RegValueSafe $Path $Name; $origType = $kind }
        $rec = [pscustomobject]@{
            tweakId = $TweakId; kind = 'reg'; path = $Path; name = $Name
            existed = $had; value = $orig; type = $origType }
        Save-BackupRecords (@($records) + $rec)
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

# Remove a registry value, capturing the original first (for revert).
function Remove-TrackedValue {
    param([string]$TweakId, [string]$Path, [string]$Name)
    $kind = Get-RegKind -Path $Path -Name $Name
    if (-not $kind) { return }   # nothing there
    $records = Get-BackupRecords
    $tracked = $records | Where-Object {
        $_.tweakId -eq $TweakId -and $_.kind -eq 'reg' -and $_.path -eq $Path -and $_.name -eq $Name }
    if (-not $tracked) {
        $rec = [pscustomobject]@{
            tweakId = $TweakId; kind = 'reg'; path = $Path; name = $Name
            existed = $true; value = (Get-RegValueSafe $Path $Name); type = $kind }
        Save-BackupRecords (@($records) + $rec)
    }
    Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
}

function Undo-TrackedValues {
    param([string]$TweakId)
    $records = Get-BackupRecords
    $mine = @($records | Where-Object { $_.tweakId -eq $TweakId -and $_.kind -eq 'reg' })
    [array]::Reverse($mine)
    foreach ($r in $mine) {
        try {
            if ($r.existed) {
                if (-not (Test-Path -LiteralPath $r.path)) { New-Item -Path $r.path -Force | Out-Null }
                New-ItemProperty -LiteralPath $r.path -Name $r.name -PropertyType $r.type -Value $r.value -Force | Out-Null
            } elseif (Test-Path -LiteralPath $r.path) {
                Remove-ItemProperty -LiteralPath $r.path -Name $r.name -Force -ErrorAction SilentlyContinue
            }
        } catch { Write-Log "Revert of $($r.path)\$($r.name) failed: $($_.Exception.Message)" 'WARN' }
    }
    Save-BackupRecords (@($records) | Where-Object { -not ($_.tweakId -eq $TweakId -and $_.kind -eq 'reg') })
}

# Arbitrary per-tweak notes (used by non-registry tweaks: power plan, services).
function Set-TweakNote {
    param([string]$TweakId, [string]$Key, [string]$Value)
    $records = @((Get-BackupRecords) | Where-Object {
        -not ($_.tweakId -eq $TweakId -and $_.kind -eq 'note' -and $_.noteKey -eq $Key) })
    $records += [pscustomobject]@{ tweakId = $TweakId; kind = 'note'; noteKey = $Key; noteValue = $Value }
    Save-BackupRecords $records
}
function Get-TweakNote {
    param([string]$TweakId, [string]$Key)
    $r = Get-BackupRecords | Where-Object {
        $_.tweakId -eq $TweakId -and $_.kind -eq 'note' -and $_.noteKey -eq $Key } | Select-Object -First 1
    if ($r) { return $r.noteValue }
    return $null
}
function Clear-TweakNotes {
    param([string]$TweakId)
    Save-BackupRecords (@((Get-BackupRecords) | Where-Object { -not ($_.tweakId -eq $TweakId -and $_.kind -eq 'note') }))
}

# --- Apply / revert / test wrappers -----------------------------------------
function Invoke-TweakTest {
    param($Tweak)
    try { return (& $Tweak.Test) }
    catch { return @{ Applied = $false; Current = "error: $($_.Exception.Message)" } }
}

function Invoke-TweakApply {
    param($Tweak, [switch]$DryRun)
    $state = Invoke-TweakTest $Tweak
    if ($state.Applied) {
        Write-Log "SKIP '$($Tweak.Name)' - already applied." 'INFO'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'AlreadyApplied' }
    }
    if ($DryRun) {
        $adm = ''
        if ($Tweak.Scope -eq 'Machine' -and -not (Test-IsAdmin)) { $adm = ' [needs admin to apply]' }
        Write-Log "DRYRUN would apply '$($Tweak.Name)'$adm (current: $($state.Current))." 'INFO'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'WouldApply' }
    }
    if (($Tweak.Scope -eq 'Machine') -and -not (Test-IsAdmin)) {
        Write-Log "SKIP '$($Tweak.Name)' - requires administrator." 'WARN'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'Skipped'; Reason = 'NeedsAdmin' }
    }
    try {
        & $Tweak.Apply
        $note = ''; if ($Tweak.RebootRequired) { $note = ' (reboot required)' }
        Write-Log "APPLIED '$($Tweak.Name)'.$note" 'OK'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'Applied' }
    } catch {
        Write-Log "FAILED '$($Tweak.Name)': $($_.Exception.Message)" 'ERROR'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'Failed'; Reason = $_.Exception.Message }
    }
}

function Invoke-TweakRevert {
    param($Tweak, [switch]$DryRun)
    if (($Tweak.Scope -eq 'Machine') -and -not (Test-IsAdmin)) {
        Write-Log "SKIP revert '$($Tweak.Name)' - requires administrator." 'WARN'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'Skipped'; Reason = 'NeedsAdmin' }
    }
    if ($DryRun) {
        Write-Log "DRYRUN would revert '$($Tweak.Name)'." 'INFO'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'WouldRevert' }
    }
    try {
        & $Tweak.Revert
        Write-Log "REVERTED '$($Tweak.Name)'." 'OK'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'Reverted' }
    } catch {
        Write-Log "FAILED revert '$($Tweak.Name)': $($_.Exception.Message)" 'ERROR'
        return [pscustomobject]@{ Id = $Tweak.Id; Result = 'Failed'; Reason = $_.Exception.Message }
    }
}

# --- Profiles ----------------------------------------------------------------
function Get-RecommendedIds { (Get-TweakCatalog | Where-Object { $_.Recommended }).Id }

function Import-OptimizerProfile {
    param([string]$Path)
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return @($cfg.tweaks)
}

# Load the tweak catalog (defines Get-TweakCatalog + helpers in module scope so
# the tweak script blocks resolve Set-TrackedValue etc. without exporting them).
. (Join-Path $PSScriptRoot 'Tweaks.ps1')

# Load the dashboard diagnostics (read-only system checks shown before tuning).
. (Join-Path $PSScriptRoot 'Dashboard.ps1')

# Load live telemetry (monitor screen).
. (Join-Path $PSScriptRoot 'Telemetry.ps1')

# Load app state (readiness, profiles, history), optional FPS (PresentMon), CS2 helpers.
. (Join-Path $PSScriptRoot 'AppStore.ps1')
. (Join-Path $PSScriptRoot 'Fps.ps1')
. (Join-Path $PSScriptRoot 'Cs2.ps1')

# Load the app API (command dispatcher for the WebView2 UI bridge).
. (Join-Path $PSScriptRoot 'AppApi.ps1')

Export-ModuleMember -Function `
    Write-Log, Set-LogSink, Test-IsAdmin, New-OptimizerRestorePoint, `
    Get-TweakCatalog, Invoke-TweakTest, Invoke-TweakApply, Invoke-TweakRevert, `
    Get-RecommendedIds, Import-OptimizerProfile, Get-BackupRecords, `
    Get-RefreshRateStatus, Set-MaxRefreshRate, Restore-RefreshRate, `
    Get-GpuDriverStatus, Get-ValvePing, Get-ValvePingTargets, `
    Get-GpuControlPanelRecommendations, Open-GpuControlPanel, `
    Get-MonitorTelemetry, `
    Get-AppProfiles, Set-ActiveProfile, Save-ProfileTweaks, Reset-ProfileTweaks, `
    Get-AppHistory, Add-AppHistory, `
    Get-PresentMonPath, Get-FpsAvailable, Invoke-FpsBenchmark, `
    Get-Cs2Info, Set-Cs2Autoexec, `
    Get-DashboardData, Get-TweakCards, Invoke-VolanteCommand
