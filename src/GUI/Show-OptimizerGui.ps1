#     Volante GUI (WPF). Two modes in one window:
#       - Wizard  (default): Goals -> Review -> Done. Friendly for normal users.
#       - Advanced: the full per-tweak list. Same engine underneath.
#     Must run STA (Volante.cmd and the elevation relaunch both pass -STA).
param([string]$EnginePath)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module $EnginePath -Force

if (-not ('Volante.TweakVm' -as [type])) {
    Add-Type -Language CSharp @'
using System.ComponentModel;
namespace Volante {
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
                'PageDashboard','PageWizard','PageAdvanced',
                'DashRefreshPanel','DashDriverPanel','BtnWindowsUpdate',
                'DashPingPanel','BtnPingRetest','DashCpHeader','DashCpPanel','BtnCpOpen',
                'BtnDashRecheck','BtnDashAdvanced','BtnDashStart',
                'StepGoals','StepReview','StepResults',
                'ChkPerf','ChkPriv','BtnToAdvanced','BtnGoalsNext',
                'ReviewSummary','ReviewList','BtnReviewBack','BtnPreviewWizard','BtnApplyWizard',
                'ResultsTitle','ResultsText','BtnUndoAll','BtnRestart','BtnApplyNow','BtnDone',
                'BtnToSimple','TweakList','LogBox','LogScroll',
                'BtnRecommended','BtnAll','BtnNone','BtnRestore','BtnDryRun',
                'BtnApply','BtnRevert','BtnRefresh') {
    $ctrl[$n] = $window.FindName($n)
}

$script:DashVendor = 'Other'
$script:PingBusy   = $false   # guards the background latency runspace

$riskColor  = @{ Safe = '#2E9E5B'; Caution = '#C9892B'; Advanced = '#C0453B' }
$vms        = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$cvs        = $window.FindResource('TweakView')
$cvs.Source = $vms

function Set-Status { param($Text) $ctrl['StatusText'].Text = $Text }

# --- Navigation --------------------------------------------------------------
function Show-Page {
    param([ValidateSet('dashboard','wizard','advanced')] $Name)
    $ctrl['PageDashboard'].Visibility = 'Collapsed'
    $ctrl['PageWizard'].Visibility    = 'Collapsed'
    $ctrl['PageAdvanced'].Visibility  = 'Collapsed'
    switch ($Name) {
        'dashboard' {
            $ctrl['PageDashboard'].Visibility = 'Visible'
            $ctrl['HeaderSubtitle'].Text      = 'System check - a quick look before tuning'
        }
        'wizard' {
            $ctrl['PageWizard'].Visibility = 'Visible'
            $ctrl['HeaderSubtitle'].Text   = "Let's tune your PC for gaming"
        }
        'advanced' {
            $ctrl['PageAdvanced'].Visibility = 'Visible'
            $ctrl['HeaderSubtitle'].Text     = 'Advanced mode - every tweak, with full detail'
            Update-List
        }
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
        $vm = New-Object Volante.TweakVm
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

# --- Dashboard logic ---------------------------------------------------------
# Cards are built in code (not data-bound) so per-row buttons wire up cleanly and
# PSObject binding quirks are avoided - same reason TweakVm is a compiled class.
function New-Brush { param($Hex) (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
function New-Thick { param($L,$T,$R,$B) New-Object System.Windows.Thickness($L,$T,$R,$B) }

function New-Text {
    param($Text, $Hex = '#E6E8EE', $Size = 13, [switch]$Bold, [switch]$Wrap)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.Foreground = New-Brush $Hex; $tb.FontSize = $Size
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) { $tb.TextWrapping = 'Wrap' }
    return $tb
}

# A two-column row: left content stretches, optional right element hugs the right.
function New-DashRow {
    param([System.Windows.UIElement]$Left, [System.Windows.UIElement]$Right = $null)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = New-Thick 0 5 0 5
    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = New-Object System.Windows.GridLength(1, 'Star')
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1)
    [System.Windows.Controls.Grid]::SetColumn($Left, 0); $g.Children.Add($Left) | Out-Null
    if ($Right) { [System.Windows.Controls.Grid]::SetColumn($Right, 1); $g.Children.Add($Right) | Out-Null }
    return $g
}

function Open-Url { param($Url) try { Start-Process $Url } catch { Set-Status "Couldn't open link." } }

function Invoke-SetMaxHz {
    param($Display)
    Set-Status "Setting $($Display.Name) to $($Display.MaxHz) Hz..."
    $r = Set-MaxRefreshRate -Device $Display.Device -Hz $Display.MaxHz
    if ($r.Success) {
        $keep = [System.Windows.MessageBox]::Show(
            "Your screen is now at $($Display.MaxHz) Hz. Keep this setting?`n`n(Choose No to go back to $($r.PreviousHz) Hz.)",
            'Volante - keep refresh rate?', 'YesNo', 'Question')
        if ($keep -ne [System.Windows.MessageBoxResult]::Yes) {
            Restore-RefreshRate -Device $Display.Device -Hz $r.PreviousHz | Out-Null
            Set-Status "Reverted to $($r.PreviousHz) Hz."
        } else { Set-Status "Refresh rate set to $($Display.MaxHz) Hz." }
    } else {
        Set-Status "Couldn't change refresh rate (code $($r.Code))."
    }
    Update-DashRefresh
}

function Update-DashRefresh {
    $panel = $ctrl['DashRefreshPanel']; $panel.Children.Clear()
    $displays = @(Get-RefreshRateStatus)
    if ($displays.Count -eq 0) {
        $panel.Children.Add((New-Text 'Could not read display modes.' '#8A90A2')) | Out-Null; return
    }
    foreach ($d in $displays) {
        $left = New-Object System.Windows.Controls.StackPanel
        $left.VerticalAlignment = 'Center'
        $left.Children.Add((New-Text ("{0}  -  {1}x{2}" -f $d.Name, $d.Width, $d.Height) '#E6E8EE' 14 -Bold)) | Out-Null
        if ($d.IsOptimal) {
            $left.Children.Add((New-Text ("{0} Hz - already at the highest supported." -f $d.CurrentHz) '#2E9E5B' 12)) | Out-Null
            $panel.Children.Add((New-DashRow -Left $left)) | Out-Null
        } else {
            $left.Children.Add((New-Text ("{0} Hz now - your display supports up to {1} Hz." -f $d.CurrentHz, $d.MaxHz) '#C9892B' 12)) | Out-Null
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = "Set to $($d.MaxHz) Hz"; $btn.VerticalAlignment = 'Center'; $btn.Tag = $d
            $btn.Add_Click({ param($s, $e) Invoke-SetMaxHz $s.Tag })
            $panel.Children.Add((New-DashRow -Left $left -Right $btn)) | Out-Null
        }
    }
}

function Update-DashDriver {
    $panel = $ctrl['DashDriverPanel']; $panel.Children.Clear()
    $gpus = @(Get-GpuDriverStatus)
    if ($gpus.Count -eq 0) {
        $panel.Children.Add((New-Text 'No GPU detected.' '#8A90A2')) | Out-Null; return
    }
    foreach ($g in $gpus) {
        $left = New-Object System.Windows.Controls.StackPanel
        $left.VerticalAlignment = 'Center'
        $left.Children.Add((New-Text $g.Name '#E6E8EE' 14 -Bold)) | Out-Null
        $ver = "Driver $($g.DriverVersion)"
        if ($g.MarketingVersion) { $ver += " ($($g.Vendor) $($g.MarketingVersion))" }
        $left.Children.Add((New-Text $ver '#9AA0B2' 12)) | Out-Null
        $dstr = if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') } else { '?' }
        if ($null -eq $g.AgeDays) {
            $left.Children.Add((New-Text 'Install date unknown.' '#8A90A2' 12)) | Out-Null
        } elseif ($g.IsStale) {
            $left.Children.Add((New-Text ("Dated {0} ({1} days ago) - check for a newer driver." -f $dstr, $g.AgeDays) '#C9892B' 12)) | Out-Null
        } else {
            $left.Children.Add((New-Text ("Dated {0} - looks recent." -f $dstr) '#2E9E5B' 12)) | Out-Null
        }
        $btn = $null
        if ($g.DownloadUrl) {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = 'Get driver'; $btn.VerticalAlignment = 'Center'; $btn.Tag = $g.DownloadUrl
            $btn.Add_Click({ param($s, $e) Open-Url $s.Tag })
        }
        $panel.Children.Add((New-DashRow -Left $left -Right $btn)) | Out-Null
    }
}

# Self-contained TCP-latency work run in a background runspace (no module deps -
# mirrors Test-TcpLatency in Dashboard.ps1 so the UI thread never blocks on the network).
$script:PingWork = {
    param($Targets, $TimeoutMs)
    $results = foreach ($t in $Targets) {
        $client = New-Object System.Net.Sockets.TcpClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ms = $null
        try {
            $iar = $client.BeginConnect($t.HostName, $t.Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
                $client.EndConnect($iar); $sw.Stop(); $ms = [int]$sw.ElapsedMilliseconds
            }
        } catch { $ms = $null } finally { $client.Close() }
        [pscustomobject]@{ Label = $t.Label; HostName = $t.HostName; Ms = $ms; Best = $false }
    }
    $reachable = @($results | Where-Object { $null -ne $_.Ms } | Sort-Object Ms)
    if ($reachable.Count -gt 0) { $reachable[0].Best = $true }
    $results
}

function Render-PingRows {
    param($Pings)
    $panel = $ctrl['DashPingPanel']; $panel.Children.Clear()
    if (@($Pings).Count -eq 0) {
        $panel.Children.Add((New-Text 'Latency check unavailable.' '#8A90A2')) | Out-Null; return
    }
    foreach ($p in $Pings) {
        $leftTxt = New-Text $p.Label '#D6DAE6'; $leftTxt.VerticalAlignment = 'Center'
        if ($null -eq $p.Ms) {
            $right = New-Text 'timeout' '#C0453B' 13 -Bold
        } else {
            $hex = if ($p.Ms -lt 50) { '#2E9E5B' } elseif ($p.Ms -lt 100) { '#C9892B' } else { '#C0453B' }
            $txt = "$($p.Ms) ms"; if ($p.Best) { $txt += '  (best)' }
            $right = New-Text $txt $hex 13 -Bold
        }
        $right.VerticalAlignment = 'Center'
        $panel.Children.Add((New-DashRow -Left $leftTxt -Right $right)) | Out-Null
    }
}

# Kick the latency check on a background runspace; a DispatcherTimer (UI thread)
# polls for completion and renders, so the window stays responsive throughout.
function Update-DashPing {
    if ($script:PingBusy) { return }
    $panel = $ctrl['DashPingPanel']; $panel.Children.Clear()
    $panel.Children.Add((New-Text 'Checking latency...' '#8A90A2')) | Out-Null

    $targets = @(Get-ValvePingTargets)
    $script:PingBusy = $true
    Set-Status 'Testing latency to Steam/Valve...'

    $script:PingPs = [powershell]::Create()
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $script:PingPs.Runspace = $rs
    [void]$script:PingPs.AddScript($script:PingWork.ToString()).AddArgument($targets).AddArgument(500)
    $script:PingHandle = $script:PingPs.BeginInvoke()

    $script:PingTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PingTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:PingTimer.Add_Tick({
        if (-not $script:PingHandle.IsCompleted) { return }
        $script:PingTimer.Stop()
        $results = @()
        try { $results = @($script:PingPs.EndInvoke($script:PingHandle)) }
        catch { Write-Log "Ping background task failed: $($_.Exception.Message)" 'WARN' }
        try { $script:PingPs.Runspace.Close(); $script:PingPs.Dispose() } catch {}
        $script:PingBusy = $false
        Render-PingRows $results
        Set-Status 'Ready.'
    })
    $script:PingTimer.Start()
}

function Update-DashCp {
    $panel = $ctrl['DashCpPanel']; $panel.Children.Clear()
    $cp = Get-GpuControlPanelRecommendations
    $script:DashVendor = $cp.Vendor
    $ctrl['DashCpHeader'].Text = "CS2 GPU CONTROL-PANEL SETTINGS - $($cp.Vendor)"
    foreach ($it in $cp.Items) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = New-Thick 0 4 0 4
        $sp.Children.Add((New-Text $it.Setting '#E6E8EE' 13 -Bold)) | Out-Null
        $cur = "$($it.Current)"
        $curHex = if ($cur -eq $it.Recommended) { '#2E9E5B' } elseif ($cur -like 'Verify*') { '#6A7080' } else { '#C9892B' }
        $line = New-Object System.Windows.Controls.TextBlock
        $line.TextWrapping = 'Wrap'; $line.FontSize = 12; $line.Margin = New-Thick 0 2 0 0
        $r1 = New-Object System.Windows.Documents.Run('Recommended: '); $r1.Foreground = New-Brush '#8A90A2'
        $r2 = New-Object System.Windows.Documents.Run($it.Recommended);  $r2.Foreground = New-Brush '#D6DAE6'
        $r3 = New-Object System.Windows.Documents.Run('    Current: ');  $r3.Foreground = New-Brush '#8A90A2'
        $r4 = New-Object System.Windows.Documents.Run($cur);             $r4.Foreground = New-Brush $curHex
        $line.Inlines.Add($r1); $line.Inlines.Add($r2); $line.Inlines.Add($r3); $line.Inlines.Add($r4)
        $sp.Children.Add($line) | Out-Null
        $panel.Children.Add($sp) | Out-Null
    }
}

function Update-Dashboard {
    Set-Status 'Running checks...'
    try { Update-DashRefresh } catch { Write-Log "Dashboard refresh card failed: $($_.Exception.Message)" 'WARN' }
    try { Update-DashDriver }  catch { Write-Log "Dashboard driver card failed: $($_.Exception.Message)" 'WARN' }
    try { Update-DashCp }      catch { Write-Log "Dashboard control-panel card failed: $($_.Exception.Message)" 'WARN' }
    try { Update-DashPing }    catch { Write-Log "Dashboard ping card failed: $($_.Exception.Message)" 'WARN' }
}

# --- Log sink ----------------------------------------------------------------
Set-LogSink {
    param($line, $level)
    $ctrl['LogBox'].Dispatcher.Invoke([action]{
        $ctrl['LogBox'].AppendText($line + "`r`n")
        $ctrl['LogScroll'].ScrollToEnd()
    })
}

# --- Wire up: dashboard ------------------------------------------------------
$ctrl['BtnDashStart'].Add_Click({ Show-Page 'wizard'; Show-WizStep 'goals' })
$ctrl['BtnDashAdvanced'].Add_Click({ Show-Page 'advanced' })
$ctrl['BtnDashRecheck'].Add_Click({ Update-Dashboard })
$ctrl['BtnPingRetest'].Add_Click({ Update-DashPing })
$ctrl['BtnWindowsUpdate'].Add_Click({ Open-Url 'ms-settings:windowsupdate' })
$ctrl['BtnCpOpen'].Add_Click({
    if (-not (Open-GpuControlPanel -Vendor $script:DashVendor)) { Set-Status "Couldn't open the control panel." }
})

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
$ctrl['BtnDone'].Add_Click({ Show-WizStep 'goals'; Show-Page 'dashboard'; Set-Status 'Ready.' })
$ctrl['BtnRestart'].Add_Click({ Start-Process 'shutdown' -ArgumentList '/g','/t','5' })
$ctrl['BtnToAdvanced'].Add_Click({ Show-Page 'advanced' })

# --- Wire up: advanced -------------------------------------------------------
$ctrl['BtnToSimple'].Add_Click({ Show-Page 'dashboard' })
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
Show-Page 'dashboard'
Show-WizStep 'goals'
if (-not (Test-IsAdmin)) {
    Set-Status 'Note: not running as admin - some system tweaks will be skipped. Relaunch as administrator for the full set.'
}
# Run the dashboard checks after the window has painted so it appears instantly.
$window.Add_ContentRendered({ Update-Dashboard })
# Tidy up any in-flight background latency runspace on close.
$window.Add_Closed({
    try { if ($script:PingTimer) { $script:PingTimer.Stop() } } catch {}
    try { if ($script:PingPs)    { $script:PingPs.Dispose() } } catch {}
})
Write-Log 'GUI started.' 'INFO'
$window.ShowDialog() | Out-Null
