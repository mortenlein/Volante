<#
    GameTune GUI (WPF). Two modes in one window:
      - Wizard  (default): Goals -> Review -> Done. Friendly for normal users.
      - Advanced: the full per-tweak list. Same engine underneath.
    Must run STA (GameTune.cmd and the elevation relaunch both pass -STA).
#>
param([string]$EnginePath)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module $EnginePath -Force

# View-model with INotifyPropertyChanged so Select-All / Clear update the checkboxes.
if (-not ('GameTune.TweakVm' -as [type])) {
    Add-Type -Language CSharp @'
using System.ComponentModel;
namespace GameTune {
  public class TweakVm : INotifyPropertyChanged {
    public string Id {get;set;}
    public string Name {get;set;}
    public string Category {get;set;}
    public string Description {get;set;}
    public string Risk {get;set;}
    public string RiskColor {get;set;}
    public string StateText {get;set;}
    public string StateColor {get;set;}
    private bool _sel;
    public bool IsSelected { get { return _sel; } set { _sel = value; Raise("IsSelected"); } }
    public event PropertyChangedEventHandler PropertyChanged;
    void Raise(string n){ var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
  }
}
'@
}

# --- Load XAML ---------------------------------------------------------------
$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

$ctrl = @{}
foreach ($n in 'HeaderSubtitle','StatusText',
                'PageWizard','PageAdvanced',
                'StepGoals','StepReview','StepResults',
                'ChkPerf','ChkPriv','BtnToAdvanced','BtnGoalsNext',
                'ReviewSummary','ReviewList','BtnReviewBack','BtnPreviewWizard','BtnApplyWizard',
                'ResultsTitle','ResultsText','BtnUndoAll','BtnRestart','BtnApplyNow','BtnDone',
                'BtnToSimple','TweakList','LogBox','LogScroll',
                'BtnRecommended','BtnAll','BtnNone','BtnRestore','BtnDryRun',
                'BtnApply','BtnRevert','BtnRefresh') {
    $ctrl[$n] = $window.FindName($n)
}

$riskColor  = @{ Safe = '#2E9E5B'; Caution = '#C9892B'; Advanced = '#C0453B' }
$vms        = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$cvs        = $window.FindResource('TweakView')
$cvs.Source = $vms

function Set-Status { param($Text) $ctrl['StatusText'].Text = $Text }

# --- Navigation --------------------------------------------------------------
function Show-Page {
    param([ValidateSet('wizard','advanced')] $Name)
    if ($Name -eq 'wizard') {
        $ctrl['PageWizard'].Visibility   = 'Visible'
        $ctrl['PageAdvanced'].Visibility = 'Collapsed'
        $ctrl['HeaderSubtitle'].Text     = "Let's tune your PC for gaming"
    } else {
        $ctrl['PageWizard'].Visibility   = 'Collapsed'
        $ctrl['PageAdvanced'].Visibility = 'Visible'
        $ctrl['HeaderSubtitle'].Text     = 'Advanced mode - every tweak, with full detail'
        Update-List
    }
}

function Show-WizStep {
    param([ValidateSet('goals','review','results')] $Name)
    $ctrl['StepGoals'].Visibility   = 'Collapsed'
    $ctrl['StepReview'].Visibility  = 'Collapsed'
    $ctrl['StepResults'].Visibility = 'Collapsed'
    switch ($Name) {
        'goals'   { $ctrl['StepGoals'].Visibility   = 'Visible' }
        'review'  { $ctrl['StepReview'].Visibility  = 'Visible' }
        'results' { $ctrl['StepResults'].Visibility = 'Visible' }
    }
}

# --- Wizard logic ------------------------------------------------------------
# Map the chosen goals to the recommended tweaks for those categories.
function Get-WizardIds {
    $cat = Get-TweakCatalog
    $ids = @()
    if ($ctrl['ChkPerf'].IsChecked) { $ids += ($cat | Where-Object { $_.Recommended -and $_.Category -ne 'Privacy' }).Id }
    if ($ctrl['ChkPriv'].IsChecked) { $ids += ($cat | Where-Object { $_.Recommended -and $_.Category -eq 'Privacy' }).Id }
    @($ids | Select-Object -Unique)
}

function Build-Review {
    $cat = Get-TweakCatalog
    $ids = Get-WizardIds
    $sel = @($cat | Where-Object { $ids -contains $_.Id })
    $pending = @($sel | Where-Object { -not (Invoke-TweakTest $_).Applied })
    $reboot  = @($pending | Where-Object { $_.RebootRequired }).Count

    $ctrl['ReviewList'].ItemsSource = [string[]]@($sel | ForEach-Object { $_.Name })
    if ($pending.Count -eq 0) {
        $ctrl['ReviewSummary'].Text = "Good news - everything for your selected goals is already set. You can review the list below or go back."
    } else {
        $msg = "We'll apply $($pending.Count) improvement(s)"
        if ($sel.Count -ne $pending.Count) { $msg += " ($($sel.Count - $pending.Count) already done)" }
        $msg += "."
        if ($reboot -gt 0) { $msg += " $reboot of them take effect after a restart." }
        $ctrl['ReviewSummary'].Text = $msg
    }
}

function Invoke-Wizard {
    param([switch]$DryRun)
    $cat = Get-TweakCatalog
    $ids = Get-WizardIds
    if ($DryRun) {
        Set-Status 'Previewing - no changes will be made...'
    } else {
        Set-Status 'Saving a restore point and applying...'
        New-OptimizerRestorePoint | Out-Null
    }
    $applied = 0; $already = 0; $skipped = 0; $failed = 0; $would = 0; $reboot = $false
    foreach ($id in $ids) {
        $t = $cat | Where-Object Id -eq $id | Select-Object -First 1
        if (-not $t) { continue }
        $r = Invoke-TweakApply $t -DryRun:$DryRun
        switch ($r.Result) {
            'Applied'        { $applied++; if ($t.RebootRequired) { $reboot = $true } }
            'WouldApply'     { $would++;   if ($t.RebootRequired) { $reboot = $true } }
            'AlreadyApplied' { $already++ }
            'Skipped'        { $skipped++ }
            'Failed'         { $failed++ }
        }
    }

    $lines = @()
    if ($DryRun) {
        $lines += "Preview only - nothing was changed on your PC."
        $lines += ""
        $lines += "$would improvement(s) would be applied."
        if ($already -gt 0) { $lines += "$already are already set." }
        if ($skipped -gt 0) { $lines += "$skipped need administrator rights." }
        if ($reboot)        { $lines += "Some would take effect after a restart." }
        $ctrl['ResultsTitle'].Text       = 'Preview complete'
        $ctrl['BtnApplyNow'].Visibility  = 'Visible'
        $ctrl['BtnRestart'].Visibility   = 'Collapsed'
        $ctrl['BtnUndoAll'].Visibility   = 'Collapsed'
        Set-Status 'Preview finished - no changes made.'
    } else {
        $lines += "Applied $applied improvement(s)."
        if ($already -gt 0) { $lines += "$already were already set." }
        if ($skipped -gt 0) { $lines += "$skipped need administrator rights (relaunch as admin to apply them)." }
        if ($failed  -gt 0) { $lines += "$failed could not be applied - see Advanced mode for details." }
        if ($reboot) {
            $lines += ""
            $lines += "Some changes take effect after a restart."
            $ctrl['BtnRestart'].Visibility = 'Visible'
        } else {
            $ctrl['BtnRestart'].Visibility = 'Collapsed'
        }
        if ($failed -gt 0) { $ctrl['ResultsTitle'].Text = 'Done, with a few notes' }
        else               { $ctrl['ResultsTitle'].Text = 'All done!' }
        $ctrl['BtnApplyNow'].Visibility = 'Collapsed'
        $ctrl['BtnUndoAll'].Visibility  = 'Visible'
        Set-Status 'Finished.'
    }
    $ctrl['ResultsText'].Text = ($lines -join "`n")
    Show-WizStep 'results'
}

function Invoke-UndoAll {
    Set-Status 'Reverting all changes...'
    $cat = Get-TweakCatalog
    $n = 0
    foreach ($t in $cat) {
        $r = Invoke-TweakRevert $t
        if ($r.Result -eq 'Reverted') { $n++ }
    }
    $ctrl['ResultsTitle'].Text = 'Reverted'
    $ctrl['ResultsText'].Text  = "Rolled back $n change(s) to their previous values. You can run the wizard again any time."
    $ctrl['BtnRestart'].Visibility  = 'Collapsed'
    $ctrl['BtnApplyNow'].Visibility = 'Collapsed'
    Set-Status 'All changes reverted.'
}

# --- Advanced-mode logic -----------------------------------------------------
function Update-List {
    $vms.Clear()
    foreach ($t in (Get-TweakCatalog)) {
        $s = Invoke-TweakTest $t
        $vm = New-Object GameTune.TweakVm
        $vm.Id = $t.Id; $vm.Name = $t.Name; $vm.Category = $t.Category
        $vm.Description = $t.Description; $vm.Risk = $t.Risk; $vm.RiskColor = $riskColor[$t.Risk]
        if ($s.Applied) { $vm.StateText = "Already applied - $($s.Current)"; $vm.StateColor = '#2E9E5B' }
        else            { $vm.StateText = "Not applied - $($s.Current)";     $vm.StateColor = '#8A90A2' }
        $vm.IsSelected = ([bool]$t.Recommended -and -not $s.Applied)
        $vms.Add($vm)
    }
}

function Invoke-OnSelected {
    param([scriptblock]$PerTweak, [string]$Verb, [switch]$RestorePoint)
    $sel = @($vms | Where-Object { $_.IsSelected })
    if ($sel.Count -eq 0) { Set-Status 'Nothing selected.'; return }
    if ($RestorePoint) { New-OptimizerRestorePoint | Out-Null }
    $cat = Get-TweakCatalog
    foreach ($v in $sel) {
        $t = $cat | Where-Object Id -eq $v.Id | Select-Object -First 1
        if ($t) { & $PerTweak $t }
    }
    Update-List
    Set-Status "$Verb $($sel.Count) tweak(s). See log; some changes may need a reboot."
}

# --- Log sink ----------------------------------------------------------------
Set-LogSink {
    param($line, $level)
    $ctrl['LogBox'].Dispatcher.Invoke([action]{
        $ctrl['LogBox'].AppendText($line + "`r`n")
        $ctrl['LogScroll'].ScrollToEnd()
    })
}

# --- Wire up: wizard ---------------------------------------------------------
$ctrl['BtnGoalsNext'].Add_Click({
    if (-not ($ctrl['ChkPerf'].IsChecked -or $ctrl['ChkPriv'].IsChecked)) {
        Set-Status 'Pick at least one goal to continue.'; return
    }
    Build-Review; Show-WizStep 'review'
})
$ctrl['BtnReviewBack'].Add_Click({ Show-WizStep 'goals' })
$ctrl['BtnPreviewWizard'].Add_Click({ Invoke-Wizard -DryRun })
$ctrl['BtnApplyWizard'].Add_Click({ Invoke-Wizard })
$ctrl['BtnApplyNow'].Add_Click({ Invoke-Wizard })
$ctrl['BtnUndoAll'].Add_Click({ Invoke-UndoAll })
$ctrl['BtnDone'].Add_Click({ Show-WizStep 'goals'; Show-Page 'wizard'; Set-Status 'Ready.' })
$ctrl['BtnRestart'].Add_Click({ Start-Process 'shutdown' -ArgumentList '/g','/t','5' })
$ctrl['BtnToAdvanced'].Add_Click({ Show-Page 'advanced' })

# --- Wire up: advanced -------------------------------------------------------
$ctrl['BtnToSimple'].Add_Click({ Show-Page 'wizard' })
$ctrl['BtnRecommended'].Add_Click({
    $cat = Get-TweakCatalog
    foreach ($v in $vms) { $v.IsSelected = [bool]($cat | Where-Object Id -eq $v.Id | Select-Object -First 1).Recommended }
    Set-Status 'Selected recommended tweaks.'
})
$ctrl['BtnAll'].Add_Click({  foreach ($v in $vms) { $v.IsSelected = $true  }; Set-Status 'Selected all.' })
$ctrl['BtnNone'].Add_Click({ foreach ($v in $vms) { $v.IsSelected = $false }; Set-Status 'Cleared selection.' })
$ctrl['BtnRestore'].Add_Click({
    Set-Status 'Creating restore point...'
    if (New-OptimizerRestorePoint) { Set-Status 'Restore point created.' }
    else { Set-Status 'Restore point not created (see log - admin / 24h limit).' }
})
$ctrl['BtnDryRun'].Add_Click({ Invoke-OnSelected -Verb 'Dry-ran' -PerTweak { param($t) Invoke-TweakApply $t -DryRun | Out-Null } })
$ctrl['BtnApply'].Add_Click({ Invoke-OnSelected -Verb 'Applied' -RestorePoint -PerTweak { param($t) Invoke-TweakApply $t | Out-Null } })
$ctrl['BtnRevert'].Add_Click({ Invoke-OnSelected -Verb 'Reverted' -PerTweak { param($t) Invoke-TweakRevert $t | Out-Null } })
$ctrl['BtnRefresh'].Add_Click({ Update-List; Set-Status 'Refreshed.' })

# --- Go ----------------------------------------------------------------------
Show-Page 'wizard'
Show-WizStep 'goals'
if (-not (Test-IsAdmin)) {
    Set-Status 'Note: not running as admin - some system tweaks will be skipped. Relaunch as administrator for the full set.'
}
Write-Log 'GUI started.' 'INFO'
$window.ShowDialog() | Out-Null
