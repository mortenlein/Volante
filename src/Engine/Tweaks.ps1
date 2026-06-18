<#
    Volante tweak catalog.
    Each tweak is a self-describing object with Test / Apply / Revert script blocks.
    Conventions:
      Scope        = 'User' (HKCU only, no admin) | 'Machine' (HKLM/services/powercfg, needs admin)
      Risk         = 'Safe' | 'Caution' | 'Advanced'
      Recommended  = preselected in the "Recommended" preset
      Test  -> @{ Applied = <bool>; Current = <string> }
    Apply blocks use Set-TrackedValue / Remove-TrackedValue / Set-TweakNote so that
    Revert can restore the EXACT prior state (see Optimizer.Engine.psm1).
#>

$script:DisplayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$script:MmProfile    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$script:GamesTask    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'

function Get-ActiveScheme {
    $line = (powercfg /getactivescheme) -join ' '
    [pscustomobject]@{
        Guid = ([regex]'([0-9a-fA-F-]{36})').Match($line).Value
        Name = ([regex]'\(([^)]+)\)').Match($line).Groups[1].Value
    }
}

# Read the current AC index of a power setting (for true revert of powercfg tweaks).
function Get-PowerAcIndex {
    param($Sub, $Setting)
    $line = (powercfg /query SCHEME_CURRENT $Sub $Setting 2>$null) |
        Where-Object { $_ -match 'Current AC Power Setting Index' } | Select-Object -First 1
    if ($line -and $line -match '0x([0-9a-fA-F]+)') { return [convert]::ToInt32($matches[1], 16) }
    return $null
}

function Set-PowerIndex {
    param($Sub, $Setting, $Value)
    powercfg /setacvalueindex SCHEME_CURRENT $Sub $Setting $Value | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $Sub $Setting $Value | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

# Registry keys that hold the MSI-mode flag for each PCI display adapter.
function Get-GpuMsiKeys {
    $devs = $null
    try { $devs = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -like 'PCI\*' }) }
    catch { $devs = $null }
    if ($devs) {
        return @($devs | ForEach-Object {
            "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        })
    }
    # Fallback: scan PCI devices in the display class directly in the registry.
    return @(
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI' -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                if ((Get-RegValueSafe $_.PSPath 'ClassGUID') -eq '{4d36e968-e325-11ce-bfc1-08002be10318}') {
                    Join-Path $_.PSPath 'Device Parameters\Interrupt Management\MessageSignaledInterruptProperties'
                }
            }
        }
    )
}

# Interface GUID of the active network adapter (the one with the default route).
function Get-ActiveNicGuid {
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        $nic   = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction Stop
        if ($nic.InterfaceGuid) { return $nic.InterfaceGuid }
    } catch {}
    try {
        $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop |
            Where-Object { $_.DefaultIPGateway } | Select-Object -First 1
        if ($cfg) { return $cfg.SettingID }
    } catch {}
    return $null
}

function Get-TweakCatalog {
    $tweaks = @()

    # --- Input -------------------------------------------------------------
    $tweaks += [pscustomobject]@{
        Id = 'mouse-accel-off'; Name = 'Disable mouse acceleration'; Category = 'Input'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Turns off "Enhance pointer precision" so mouse movement maps 1:1 - the single most universally recommended FPS-gaming input tweak.'
        Test = {
            $a = Get-RegValueSafe 'HKCU:\Control Panel\Mouse' 'MouseSpeed'
            $b = Get-RegValueSafe 'HKCU:\Control Panel\Mouse' 'MouseThreshold1'
            $c = Get-RegValueSafe 'HKCU:\Control Panel\Mouse' 'MouseThreshold2'
            @{ Applied = ("$a" -eq '0' -and "$b" -eq '0' -and "$c" -eq '0'); Current = "speed=$a t1=$b t2=$c" }
        }
        Apply = {
            Set-TrackedValue 'mouse-accel-off' 'HKCU:\Control Panel\Mouse' 'MouseSpeed'      String '0'
            Set-TrackedValue 'mouse-accel-off' 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' String '0'
            Set-TrackedValue 'mouse-accel-off' 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' String '0'
        }
        Revert = { Undo-TrackedValues 'mouse-accel-off' }
    }

    # --- Visual ------------------------------------------------------------
    $tweaks += [pscustomobject]@{
        Id = 'menu-show-delay'; Name = 'Instant menu/UI response'; Category = 'Visual'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Sets MenuShowDelay to 0 (default 400ms) so menus and the Start UI feel snappier. Cosmetic, fully reversible.'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Control Panel\Desktop' 'MenuShowDelay'
            @{ Applied = ("$v" -eq '0'); Current = "MenuShowDelay=$v" }
        }
        Apply  = { Set-TrackedValue 'menu-show-delay' 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' String '0' }
        Revert = { Undo-TrackedValues 'menu-show-delay' }
    }

    # --- Performance -------------------------------------------------------
    $tweaks += [pscustomobject]@{
        Id = 'gamedvr-off'; Name = 'Disable Game DVR / background capture'; Category = 'Performance'
        Risk = 'Safe'; Scope = 'Machine'; Recommended = $true; RebootRequired = $false
        Description = 'Cleanly disables Game DVR background recording (a small but real overhead) WITHOUT removing the Game Bar app - which avoids the "ms-gamingoverlay" popup that breaks games. Use OBS/ShadowPlay/ReLive for clips.'
        Test = {
            $u = Get-RegValueSafe 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled'
            $p = Get-RegValueSafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'
            @{ Applied = ("$u" -eq '0' -and "$p" -eq '0'); Current = "GameDVR_Enabled=$u AllowGameDVR=$p" }
        }
        Apply = {
            Set-TrackedValue 'gamedvr-off' 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' DWord 0
            Set-TrackedValue 'gamedvr-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' DWord 0
            Set-TrackedValue 'gamedvr-off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' DWord 0
        }
        Revert = { Undo-TrackedValues 'gamedvr-off' }
    }

    # --- Power -------------------------------------------------------------
    $tweaks += [pscustomobject]@{
        Id = 'power-ultimate'; Name = 'Activate Ultimate Performance power plan'; Category = 'Power'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $false
        Description = "Uses Windows' built-in Ultimate Performance plan (transparent, MS-signed) instead of a mystery imported .pow. Higher idle power draw. Reverts to your previous plan on undo."
        Test = {
            $cur = Get-ActiveScheme
            @{ Applied = ($cur.Name -match 'Ultimate Performance'); Current = "active: $($cur.Name)" }
        }
        Apply = {
            $cur = Get-ActiveScheme
            Set-TweakNote 'power-ultimate' 'prevScheme' $cur.Guid
            $guid = $null
            foreach ($l in (powercfg /list)) {
                if ($l -match 'Ultimate Performance') { $guid = ([regex]'([0-9a-fA-F-]{36})').Match($l).Value; break }
            }
            if (-not $guid) {
                $out = (powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61) -join "`n"
                $guid = ([regex]'([0-9a-fA-F-]{36})').Match($out).Value
            }
            powercfg /setactive $guid | Out-Null
        }
        Revert = {
            $prev = Get-TweakNote 'power-ultimate' 'prevScheme'
            if ($prev) { powercfg /setactive $prev | Out-Null }
            Clear-TweakNotes 'power-ultimate'
        }
    }

    # --- GPU ---------------------------------------------------------------
    $tweaks += [pscustomobject]@{
        Id = 'gpu-pstate-restore'; Name = 'Remove legacy GPU P-state lock'; Category = 'GPU'
        Risk = 'Advanced'; Scope = 'Machine'; Recommended = $true; RebootRequired = $true
        Description = 'Removes DisableDynamicPstate from any display adapter (a common old "tweak" that pins GPU clocks high, raising idle heat/power for negligible gain). No-op if already clean. Use the driver control panel for per-game performance modes instead.'
        Test = {
            $found = $false
            Get-ChildItem $script:DisplayClass -ErrorAction SilentlyContinue | ForEach-Object {
                if ($null -ne (Get-RegValueSafe $_.PSPath 'DisableDynamicPstate')) { $found = $true }
            }
            @{ Applied = (-not $found); Current = $(if ($found) { 'P-state lock present' } else { 'clean' }) }
        }
        Apply = {
            Get-ChildItem $script:DisplayClass -ErrorAction SilentlyContinue | ForEach-Object {
                if ($null -ne (Get-RegValueSafe $_.PSPath 'DisableDynamicPstate')) {
                    Remove-TrackedValue 'gpu-pstate-restore' $_.PSPath 'DisableDynamicPstate'
                }
            }
        }
        Revert = { Undo-TrackedValues 'gpu-pstate-restore' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'hags-on'; Name = 'Hardware-accelerated GPU scheduling'; Category = 'GPU'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $false; RebootRequired = $true
        Description = 'Enables HAGS (HwSchMode=2). Can lower latency on modern GPUs/drivers; effect varies, so it is opt-in. Requires a reboot.'
        Test = {
            $v = Get-RegValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
            @{ Applied = ("$v" -eq '2'); Current = "HwSchMode=$v" }
        }
        Apply  = { Set-TrackedValue 'hags-on' 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' DWord 2 }
        Revert = { Undo-TrackedValues 'hags-on' }
    }

    # --- Privacy / services ------------------------------------------------
    $tweaks += [pscustomobject]@{
        Id = 'diagtrack-off'; Name = 'Disable Connected User Experiences & Telemetry'; Category = 'Privacy'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $false; RebootRequired = $false
        Description = 'Disables the DiagTrack telemetry service. Opt-in (not default) because some enterprise tooling depends on it. Safer than the pack''s blanket service-disabling; nothing else is touched.'
        Test = {
            $svc = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
            if (-not $svc) { return @{ Applied = $true; Current = 'service absent' } }
            @{ Applied = ($svc.StartType -eq 'Disabled'); Current = "StartType=$($svc.StartType)" }
        }
        Apply = {
            $svc = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
            if ($svc) {
                Set-TweakNote 'diagtrack-off' 'startType' "$($svc.StartType)"
                Set-Service -Name DiagTrack -StartupType Disabled
                Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
            }
        }
        Revert = {
            $st = Get-TweakNote 'diagtrack-off' 'startType'
            if (-not $st) { $st = 'Automatic' }
            Set-Service -Name DiagTrack -StartupType $st -ErrorAction SilentlyContinue
            Clear-TweakNotes 'diagtrack-off'
        }
    }

    # === Latency & scheduling ============================================
    $tweaks += [pscustomobject]@{
        Id = 'system-responsiveness'; Name = 'MMCSS system responsiveness'; Category = 'Latency'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $true
        Description = 'Sets SystemResponsiveness to 10 (default 20) so the multimedia scheduler reserves less CPU for background tasks, leaving more headroom for games.'
        Test = {
            $v = Get-RegValueSafe $script:MmProfile 'SystemResponsiveness'
            @{ Applied = ("$v" -eq '10'); Current = "SystemResponsiveness=$v" }
        }
        Apply  = { Set-TrackedValue 'system-responsiveness' $script:MmProfile 'SystemResponsiveness' DWord 10 }
        Revert = { Undo-TrackedValues 'system-responsiveness' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'games-task-priority'; Name = 'Prioritize the Games scheduler task'; Category = 'Latency'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $true
        Description = 'Raises the MMCSS "Games" task (CPU Priority 6, GPU Priority 8, Scheduling/SFIO High) so games get preferential CPU/GPU scheduling.'
        Test = {
            $p  = Get-RegValueSafe $script:GamesTask 'Priority'
            $sc = Get-RegValueSafe $script:GamesTask 'Scheduling Category'
            @{ Applied = ("$p" -eq '6' -and "$sc" -eq 'High'); Current = "Priority=$p Scheduling=$sc" }
        }
        Apply = {
            Set-TrackedValue 'games-task-priority' $script:GamesTask 'GPU Priority'        DWord  8
            Set-TrackedValue 'games-task-priority' $script:GamesTask 'Priority'            DWord  6
            Set-TrackedValue 'games-task-priority' $script:GamesTask 'Scheduling Category' String 'High'
            Set-TrackedValue 'games-task-priority' $script:GamesTask 'SFIO Priority'       String 'High'
        }
        Revert = { Undo-TrackedValues 'games-task-priority' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'network-throttling-off'; Name = 'Disable network throttling'; Category = 'Latency'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $true
        Description = 'Sets NetworkThrottlingIndex to 0xFFFFFFFF (default 10), removing the multimedia network throttle. Helps when network + audio + game run together.'
        Test = {
            $v = Get-RegValueSafe $script:MmProfile 'NetworkThrottlingIndex'
            @{ Applied = ("$v" -eq '4294967295'); Current = "NetworkThrottlingIndex=$v" }
        }
        Apply  = { Set-TrackedValue 'network-throttling-off' $script:MmProfile 'NetworkThrottlingIndex' DWord 0xFFFFFFFF }
        Revert = { Undo-TrackedValues 'network-throttling-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'win32-priority-separation'; Name = 'Foreground priority boost'; Category = 'Latency'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $false; RebootRequired = $false
        Description = 'Sets Win32PrioritySeparation to 0x26 (38) for a stronger, shorter foreground CPU boost. Benefit is contested, so opt-in. Reversible.'
        Test = {
            $v = Get-RegValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation'
            @{ Applied = ("$v" -eq '38'); Current = "Win32PrioritySeparation=$v" }
        }
        Apply  = { Set-TrackedValue 'win32-priority-separation' 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' DWord 38 }
        Revert = { Undo-TrackedValues 'win32-priority-separation' }
    }

    # === QoL & visual ====================================================
    $tweaks += [pscustomobject]@{
        Id = 'game-mode-on'; Name = 'Enable Game Mode'; Category = 'Performance'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Turns Windows Game Mode ON. Modern Game Mode prioritizes the foreground game and is recommended (the old pack wrongly told users to disable it).'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
            @{ Applied = ("$v" -eq '1'); Current = "AutoGameModeEnabled=$v" }
        }
        Apply = {
            Set-TrackedValue 'game-mode-on' 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' DWord 1
            Set-TrackedValue 'game-mode-on' 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode'   DWord 1
        }
        Revert = { Undo-TrackedValues 'game-mode-on' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'startup-delay-off'; Name = 'Remove startup-apps delay'; Category = 'Performance'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Sets StartupDelayInMSec to 0 so startup apps launch immediately after sign-in instead of after the default ~10s delay.'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec'
            @{ Applied = ("$v" -eq '0'); Current = "StartupDelayInMSec=$v" }
        }
        Apply  = { Set-TrackedValue 'startup-delay-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' DWord 0 }
        Revert = { Undo-TrackedValues 'startup-delay-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'reduce-animations'; Name = 'Reduce window animations'; Category = 'Visual'
        Risk = 'Safe'; Scope = 'User'; Recommended = $false; RebootRequired = $false
        Description = 'Turns off window minimize/maximize and taskbar animations for a snappier feel. Cosmetic; sign out/in (or restart Explorer) to fully apply.'
        Test = {
            $m = Get-RegValueSafe 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate'
            $t = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations'
            @{ Applied = ("$m" -eq '0' -and "$t" -eq '0'); Current = "MinAnimate=$m TaskbarAnimations=$t" }
        }
        Apply = {
            Set-TrackedValue 'reduce-animations' 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' String '0'
            Set-TrackedValue 'reduce-animations' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' DWord 0
        }
        Revert = { Undo-TrackedValues 'reduce-animations' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'transparency-off'; Name = 'Disable UI transparency'; Category = 'Visual'
        Risk = 'Safe'; Scope = 'User'; Recommended = $false; RebootRequired = $false
        Description = 'Disables Windows transparency effects (small compositor saving + preference). Reversible.'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency'
            @{ Applied = ("$v" -eq '0'); Current = "EnableTransparency=$v" }
        }
        Apply  = { Set-TrackedValue 'transparency-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' DWord 0 }
        Revert = { Undo-TrackedValues 'transparency-off' }
    }

    # === Power latency ===================================================
    $tweaks += [pscustomobject]@{
        Id = 'power-throttling-off'; Name = 'Disable CPU power throttling'; Category = 'Power'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $true
        Description = 'Sets PowerThrottlingOff=1 so Windows stops throttling CPU cores for power savings (EcoQoS). Higher power draw; effective after reboot.'
        Test = {
            $v = Get-RegValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'
            @{ Applied = ("$v" -eq '1'); Current = "PowerThrottlingOff=$v" }
        }
        Apply  = { Set-TrackedValue 'power-throttling-off' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' DWord 1 }
        Revert = { Undo-TrackedValues 'power-throttling-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'usb-selective-suspend-off'; Name = 'Disable USB selective suspend'; Category = 'Power'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $false
        Description = 'Stops Windows suspending USB devices - avoids occasional input latency/hitching on mice, keyboards and controllers. Applies to the active power plan.'
        Test = {
            $i = Get-PowerAcIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
            @{ Applied = ($i -eq 0); Current = "USB selective suspend AC index=$i" }
        }
        Apply = {
            $i = Get-PowerAcIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
            Set-TweakNote 'usb-selective-suspend-off' 'origAc' "$i"
            Set-PowerIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0
        }
        Revert = {
            $o = Get-TweakNote 'usb-selective-suspend-off' 'origAc'
            if (-not $o) { $o = 1 }
            Set-PowerIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' $o
            Clear-TweakNotes 'usb-selective-suspend-off'
        }
    }

    $tweaks += [pscustomobject]@{
        Id = 'pcie-aspm-off'; Name = 'Disable PCIe link power management'; Category = 'Power'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $false
        Description = 'Sets PCI Express ASPM to Off so the GPU/NVMe links never drop to a low-power state mid-use. Applies to the active power plan.'
        Test = {
            $i = Get-PowerAcIndex '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            @{ Applied = ($i -eq 0); Current = "PCIe ASPM AC index=$i" }
        }
        Apply = {
            $i = Get-PowerAcIndex '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5'
            Set-TweakNote 'pcie-aspm-off' 'origAc' "$i"
            Set-PowerIndex '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0
        }
        Revert = {
            $o = Get-TweakNote 'pcie-aspm-off' 'origAc'
            if (-not $o) { $o = 2 }
            Set-PowerIndex '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' $o
            Clear-TweakNotes 'pcie-aspm-off'
        }
    }

    $tweaks += [pscustomobject]@{
        Id = 'fast-startup-off'; Name = 'Disable Fast Startup'; Category = 'Power'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $false; RebootRequired = $false
        Description = 'Sets HiberbootEnabled=0 (the correct version of the old broken hibernate .reg). Slightly slower boot, but cleaner driver/device state each start. Hibernation itself is left intact.'
        Test = {
            $v = Get-RegValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
            @{ Applied = ("$v" -eq '0'); Current = "HiberbootEnabled=$v" }
        }
        Apply  = { Set-TrackedValue 'fast-startup-off' 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' DWord 0 }
        Revert = { Undo-TrackedValues 'fast-startup-off' }
    }

    # === Privacy =========================================================
    $tweaks += [pscustomobject]@{
        Id = 'advertising-id-off'; Name = 'Disable advertising ID'; Category = 'Privacy'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Turns off the per-user advertising ID used to tailor ads across apps.'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled'
            @{ Applied = ("$v" -eq '0'); Current = "Enabled=$v" }
        }
        Apply  = { Set-TrackedValue 'advertising-id-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' DWord 0 }
        Revert = { Undo-TrackedValues 'advertising-id-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'activity-history-off'; Name = 'Disable activity history'; Category = 'Privacy'
        Risk = 'Safe'; Scope = 'Machine'; Recommended = $true; RebootRequired = $false
        Description = 'Disables the Windows Timeline/activity feed and stops publishing/uploading user activities (policy keys).'
        Test = {
            $v = Get-RegValueSafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed'
            @{ Applied = ("$v" -eq '0'); Current = "EnableActivityFeed=$v" }
        }
        Apply = {
            Set-TrackedValue 'activity-history-off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed'     DWord 0
            Set-TrackedValue 'activity-history-off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' DWord 0
            Set-TrackedValue 'activity-history-off' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities'  DWord 0
        }
        Revert = { Undo-TrackedValues 'activity-history-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'tailored-experiences-off'; Name = 'Disable tailored experiences'; Category = 'Privacy'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Stops Windows using your diagnostic data to show tailored tips, ads and recommendations.'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled'
            @{ Applied = ("$v" -eq '0'); Current = "Tailored=$v" }
        }
        Apply  = { Set-TrackedValue 'tailored-experiences-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' DWord 0 }
        Revert = { Undo-TrackedValues 'tailored-experiences-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'telemetry-min'; Name = 'Minimize telemetry (policy)'; Category = 'Privacy'
        Risk = 'Caution'; Scope = 'Machine'; Recommended = $true; RebootRequired = $false
        Description = 'Sets the AllowTelemetry policy to 0 (Security/Basic on non-Enterprise editions). Complements disabling the DiagTrack service. Reversible.'
        Test = {
            $v = Get-RegValueSafe 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
            @{ Applied = ("$v" -eq '0'); Current = "AllowTelemetry=$v" }
        }
        Apply  = { Set-TrackedValue 'telemetry-min' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' DWord 0 }
        Revert = { Undo-TrackedValues 'telemetry-min' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'start-web-search-off'; Name = 'Disable web results in Start search'; Category = 'Privacy'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Disables Bing/web results in Start menu search so it only searches your PC (faster, more private).'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled'
            @{ Applied = ("$v" -eq '0'); Current = "BingSearchEnabled=$v" }
        }
        Apply = {
            Set-TrackedValue 'start-web-search-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' DWord 0
            Set-TrackedValue 'start-web-search-off' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent'    DWord 0
        }
        Revert = { Undo-TrackedValues 'start-web-search-off' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'suggested-content-off'; Name = 'Disable suggested content & app ads'; Category = 'Privacy'
        Risk = 'Safe'; Scope = 'User'; Recommended = $true; RebootRequired = $false
        Description = 'Turns off Start menu app suggestions, Settings "suggested content", and silent promoted-app installs.'
        Test = {
            $v = Get-RegValueSafe 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled'
            @{ Applied = ("$v" -eq '0'); Current = "SystemPaneSuggestions=$v" }
        }
        Apply = {
            $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Set-TrackedValue 'suggested-content-off' $cdm 'SystemPaneSuggestionsEnabled'    DWord 0
            Set-TrackedValue 'suggested-content-off' $cdm 'SilentInstalledAppsEnabled'      DWord 0
            Set-TrackedValue 'suggested-content-off' $cdm 'SubscribedContent-338388Enabled' DWord 0
            Set-TrackedValue 'suggested-content-off' $cdm 'SubscribedContent-338393Enabled' DWord 0
            Set-TrackedValue 'suggested-content-off' $cdm 'SubscribedContent-353694Enabled' DWord 0
            Set-TrackedValue 'suggested-content-off' $cdm 'SubscribedContent-353696Enabled' DWord 0
        }
        Revert = { Undo-TrackedValues 'suggested-content-off' }
    }

    # === Advanced: GPU MSI mode + per-NIC Nagle (opt-in, device/NIC-targeted) ===
    $tweaks += [pscustomobject]@{
        Id = 'gpu-msi-mode'; Name = 'Enable MSI mode for the GPU'; Category = 'GPU'
        Risk = 'Advanced'; Scope = 'Machine'; Recommended = $false; RebootRequired = $true
        Description = 'Switches the graphics card to Message Signaled Interrupts (MSISupported=1) - can lower interrupt/DPC latency and smooth frame pacing. Most modern drivers already enable it. Per-device and reversible; takes effect after a reboot.'
        Test = {
            $keys = Get-GpuMsiKeys
            if ($keys.Count -eq 0) { return @{ Applied = $true; Current = 'no PCI GPU found' } }
            $on = 0
            foreach ($k in $keys) { if ((Get-RegValueSafe $k 'MSISupported') -eq 1) { $on++ } }
            @{ Applied = ($on -eq $keys.Count); Current = "MSI on $on/$($keys.Count) GPU(s)" }
        }
        Apply  = { foreach ($k in (Get-GpuMsiKeys)) { Set-TrackedValue 'gpu-msi-mode' $k 'MSISupported' DWord 1 } }
        Revert = { Undo-TrackedValues 'gpu-msi-mode' }
    }

    $tweaks += [pscustomobject]@{
        Id = 'nagle-off'; Name = "Disable Nagle on the active network adapter"; Category = 'Network'
        Risk = 'Advanced'; Scope = 'Machine'; Recommended = $false; RebootRequired = $true
        Description = "Sets TcpAckFrequency=1 and TCPNoDelay=1 on your active adapter so small TCP packets send immediately (lower latency). Note: most multiplayer games use UDP, which this does NOT affect - the gain is mainly TCP traffic. Targets only the active NIC; reversible."
        Test = {
            $guid = Get-ActiveNicGuid
            if (-not $guid) { return @{ Applied = $true; Current = 'no active adapter found' } }
            $base = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
            $a = Get-RegValueSafe $base 'TcpAckFrequency'
            $n = Get-RegValueSafe $base 'TCPNoDelay'
            @{ Applied = ("$a" -eq '1' -and "$n" -eq '1'); Current = "TcpAckFrequency=$a TCPNoDelay=$n" }
        }
        Apply = {
            $guid = Get-ActiveNicGuid
            if (-not $guid) { return }
            $base = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
            Set-TweakNote 'nagle-off' 'nic' $guid
            Set-TrackedValue 'nagle-off' $base 'TcpAckFrequency' DWord 1
            Set-TrackedValue 'nagle-off' $base 'TCPNoDelay'      DWord 1
        }
        Revert = { Undo-TrackedValues 'nagle-off'; Clear-TweakNotes 'nagle-off' }
    }

    return $tweaks
}
