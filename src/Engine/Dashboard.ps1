<#
    Volante dashboard diagnostics - READ-ONLY system checks shown before tuning.
    Unlike the tweak catalog (Tweaks.ps1, which has Test/Apply/Revert), these are
    pure diagnostics with one safe, reversible action (refresh-rate fix). Dot-sourced
    into Optimizer.Engine.psm1 so helpers like Get-RegValueSafe resolve in module scope.

    Provides:
      Get-RefreshRateStatus / Set-MaxRefreshRate / Restore-RefreshRate  (item 1)
      Get-GpuDriverStatus                                               (item 2)
      Get-ValvePing                                                     (item 3)
      Get-GpuControlPanelRecommendations / Open-GpuControlPanel         (item 4)
#>

# --- Native display interop (WMI cannot report the true max refresh rate) -----
if (-not ('Volante.Display' -as [type])) {
    Add-Type -Language CSharp @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Volante {

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion;
    public short dmDriverVersion;
    public short dmSize;
    public short dmDriverExtra;
    public int   dmFields;
    public int   dmPositionX;
    public int   dmPositionY;
    public int   dmDisplayOrientation;
    public int   dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int   dmBitsPerPel;
    public int   dmPelsWidth;
    public int   dmPelsHeight;
    public int   dmDisplayFlags;
    public int   dmDisplayFrequency;
    public int   dmICMMethod;
    public int   dmICMIntent;
    public int   dmMediaType;
    public int   dmDitherType;
    public int   dmReserved1;
    public int   dmReserved2;
    public int   dmPanningWidth;
    public int   dmPanningHeight;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }

  public class DisplayInfo {
    public string Device;
    public string Name;
    public int Width;
    public int Height;
    public int CurrentHz;
    public int MaxHz;
    public bool IsOptimal;
  }

  public static class Display {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    const int  ENUM_CURRENT_SETTINGS = -1;
    const uint CDS_UPDATEREGISTRY = 0x00000001;
    const uint CDS_TEST           = 0x00000002;
    const int  DISP_CHANGE_SUCCESSFUL = 0;
    const int  ATTACHED_TO_DESKTOP = 0x00000001;
    const int  MIRRORING_DRIVER    = 0x00000008;
    const int  DM_BITSPERPEL = 0x00040000, DM_PELSWIDTH = 0x00080000,
               DM_PELSHEIGHT = 0x00100000, DM_DISPLAYFREQUENCY = 0x00400000;

    static DEVMODE NewDevmode() {
      DEVMODE d = new DEVMODE();
      d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      return d;
    }

    public static DisplayInfo[] GetDisplays() {
      var list = new List<DisplayInfo>();
      var dd = new DISPLAY_DEVICE();
      dd.cb = Marshal.SizeOf(dd);
      uint i = 0;
      while (EnumDisplayDevices(null, i, ref dd, 0)) {
        i++;
        if ((dd.StateFlags & ATTACHED_TO_DESKTOP) == 0 || (dd.StateFlags & MIRRORING_DRIVER) != 0) {
          dd.cb = Marshal.SizeOf(dd); continue;
        }
        DEVMODE cur = NewDevmode();
        if (EnumDisplaySettings(dd.DeviceName, ENUM_CURRENT_SETTINGS, ref cur)) {
          int maxHz = cur.dmDisplayFrequency;
          DEVMODE m = NewDevmode();
          int n = 0;
          while (EnumDisplaySettings(dd.DeviceName, n, ref m)) {
            if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight
                && m.dmDisplayFrequency > maxHz) maxHz = m.dmDisplayFrequency;
            n++;
          }
          list.Add(new DisplayInfo {
            Device = dd.DeviceName, Name = dd.DeviceString,
            Width = cur.dmPelsWidth, Height = cur.dmPelsHeight,
            CurrentHz = cur.dmDisplayFrequency, MaxHz = maxHz,
            IsOptimal = (cur.dmDisplayFrequency >= maxHz)
          });
        }
        dd.cb = Marshal.SizeOf(dd);
      }
      return list.ToArray();
    }

    public static int GetCurrentHz(string device) {
      DEVMODE cur = NewDevmode();
      if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref cur)) return -1;
      return cur.dmDisplayFrequency;
    }

    // Apply a refresh rate at the CURRENT resolution. Only ever applies a mode that
    // EnumDisplaySettings reports as supported, and CDS_TEST-validates it first.
    // Returns 0 on success; negative on failure.
    public static int SetRefresh(string device, int hz) {
      DEVMODE cur = NewDevmode();
      if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref cur)) return -1;
      DEVMODE m = NewDevmode();
      DEVMODE target = new DEVMODE();
      bool found = false;
      int n = 0;
      while (EnumDisplaySettings(device, n, ref m)) {
        if (m.dmPelsWidth == cur.dmPelsWidth && m.dmPelsHeight == cur.dmPelsHeight
            && m.dmDisplayFrequency == hz) { target = m; found = true; break; }
        n++;
      }
      if (!found) return -2;
      target.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;
      if (ChangeDisplaySettingsEx(device, ref target, IntPtr.Zero, CDS_TEST, IntPtr.Zero) != DISP_CHANGE_SUCCESSFUL)
        return -3;
      return ChangeDisplaySettingsEx(device, ref target, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
    }
  }
}
'@
}

# === Item 1: monitor refresh rate ============================================
function Get-RefreshRateStatus {
    try { return @([Volante.Display]::GetDisplays()) }
    catch { Write-Log "Refresh-rate probe failed: $($_.Exception.Message)" 'WARN'; return @() }
}

# Set a display to its highest supported rate at the current resolution.
# Returns @{ Success; PreviousHz; Code }. PreviousHz lets the caller offer a revert.
function Set-MaxRefreshRate {
    param([Parameter(Mandatory)][string]$Device, [Parameter(Mandatory)][int]$Hz)
    try {
        $prev = [Volante.Display]::GetCurrentHz($Device)
        $code = [Volante.Display]::SetRefresh($Device, $Hz)
        if ($code -eq 0) {
            Write-Log "Display $Device set to $Hz Hz (was $prev Hz)." 'OK'
            return [pscustomobject]@{ Success = $true;  PreviousHz = $prev; Code = 0 }
        }
        Write-Log "Could not set $Device to $Hz Hz (code $code)." 'WARN'
        return [pscustomobject]@{ Success = $false; PreviousHz = $prev; Code = $code }
    } catch {
        Write-Log "Set refresh rate failed: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{ Success = $false; PreviousHz = $null; Code = $_.Exception.Message }
    }
}

function Restore-RefreshRate {
    param([Parameter(Mandatory)][string]$Device, [Parameter(Mandatory)][int]$Hz)
    try { return ([Volante.Display]::SetRefresh($Device, $Hz) -eq 0) }
    catch { return $false }
}

# === Item 2: GPU driver ======================================================
# NVIDIA encodes its marketing version in the WDDM string's trailing digits,
# e.g. "32.0.15.9579" -> last 5 digits "59579" -> "595.79".
function Convert-NvidiaDriverVersion {
    param([string]$Version)
    if (-not $Version) { return $null }
    $digits = ($Version -replace '\D', '')
    if ($digits.Length -lt 5) { return $null }
    $last5 = $digits.Substring($digits.Length - 5)
    return '{0}.{1}' -f $last5.Substring(0, 3), $last5.Substring(3, 2)
}

function Get-GpuDriverStatus {
    $list = @()
    try {
        $vcs = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
                 Where-Object { $_.DriverVersion -and $_.PNPDeviceID -like 'PCI\*' })
    } catch {
        Write-Log "GPU driver probe failed: $($_.Exception.Message)" 'WARN'
        $vcs = @()
    }
    foreach ($vc in $vcs) {
        $ac = "$($vc.AdapterCompatibility) $($vc.Name)"
        $vendor = 'Other'; $url = ''
        if     ($ac -match 'NVIDIA')                      { $vendor = 'NVIDIA'; $url = 'https://www.nvidia.com/Download/index.aspx' }
        elseif ($ac -match 'Advanced Micro|\bAMD\b|ATI')  { $vendor = 'AMD';    $url = 'https://www.amd.com/en/support' }
        elseif ($ac -match 'Intel')                       { $vendor = 'Intel';  $url = 'https://www.intel.com/content/www/us/en/download-center/home.html' }

        $date = $null; $age = $null
        try { if ($vc.DriverDate) { $date = [datetime]$vc.DriverDate; $age = [int]((Get-Date) - $date).TotalDays } } catch {}

        $list += [pscustomobject]@{
            Name             = $vc.Name
            Vendor           = $vendor
            DriverVersion    = $vc.DriverVersion
            MarketingVersion = $(if ($vendor -eq 'NVIDIA') { Convert-NvidiaDriverVersion $vc.DriverVersion } else { $null })
            DriverDate       = $date
            AgeDays          = $age
            IsStale          = ($null -ne $age -and $age -gt 90)
            DownloadUrl      = $url
        }
    }
    return @($list)
}

# === Item 3: ping to Valve / Steam ===========================================
# TCP-connect latency (not ICMP): Valve's game relays drop ICMP, but their edge
# endpoints answer on 443, so a TCP handshake time is a usable routing-latency proxy.
function Test-TcpLatency {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 600)
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
            $client.EndConnect($iar)
            $sw.Stop()
            return [int]$sw.ElapsedMilliseconds
        }
        return $null
    } catch { return $null }
    finally { $client.Close() }
}

# Curated Steam/Valve endpoints. Edit this list to target endpoints near you.
function Get-ValvePingTargets {
    @(
        [pscustomobject]@{ Label = 'Steam (valvesoftware.com)'; HostName = 'valvesoftware.com';      Port = 443 }
        [pscustomobject]@{ Label = 'Steam store';               HostName = 'store.steampowered.com'; Port = 443 }
        [pscustomobject]@{ Label = 'Steam API';                 HostName = 'api.steampowered.com';   Port = 443 }
        [pscustomobject]@{ Label = 'Steam community';           HostName = 'steamcommunity.com';     Port = 443 }
    )
}

function Get-ValvePing {
    param([int]$TimeoutMs = 600)
    $results = @(foreach ($t in Get-ValvePingTargets) {
        $ms = Test-TcpLatency -HostName $t.HostName -Port $t.Port -TimeoutMs $TimeoutMs
        [pscustomobject]@{ Label = $t.Label; HostName = $t.HostName; Ms = $ms; Best = $false }
    })
    $reachable = @($results | Where-Object { $null -ne $_.Ms } | Sort-Object Ms)
    if ($reachable.Count -gt 0) { $reachable[0].Best = $true }
    return $results
}

# === Item 4: CS2 GPU control-panel recommendations ===========================
function Get-PrimaryGpuVendor {
    $vendors = @((Get-GpuDriverStatus).Vendor)
    if ($vendors -contains 'NVIDIA') { return 'NVIDIA' }
    if ($vendors -contains 'AMD')    { return 'AMD' }
    if ($vendors -contains 'Intel')  { return 'Intel' }
    return 'Other'
}

function Get-GpuControlPanelRecommendations {
    $vendor = Get-PrimaryGpuVendor

    # One genuinely-detectable "current" value shared by all vendors: HAGS state.
    # The rest of the vendor profile (Low Latency, V-Sync, etc.) lives in a binary
    # driver database that needs the vendor SDK to read, so it is honestly marked.
    $hags = Get-RegValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $hagsCur = switch ("$hags") { '2' { 'On' } '1' { 'Off' } '0' { 'Off' } default { 'Default (not set)' } }
    $verify  = 'Verify in control panel'

    $items = @(
        [pscustomobject]@{ Setting = 'Hardware-accelerated GPU scheduling'; Recommended = 'On'; Current = $hagsCur }
    )

    switch ($vendor) {
        'NVIDIA' {
            $items += @(
                [pscustomobject]@{ Setting = 'Low Latency Mode';            Recommended = 'Ultra';                     Current = $verify }
                [pscustomobject]@{ Setting = 'Power management mode';        Recommended = 'Prefer maximum performance';Current = $verify }
                [pscustomobject]@{ Setting = 'Texture filtering - Quality';  Recommended = 'High performance';          Current = $verify }
                [pscustomobject]@{ Setting = 'Vertical sync';               Recommended = 'Off';                       Current = $verify }
                [pscustomobject]@{ Setting = 'Threaded optimization';        Recommended = 'On';                        Current = $verify }
                [pscustomobject]@{ Setting = 'Monitor technology';           Recommended = 'G-SYNC (if supported)';     Current = $verify }
            )
        }
        'AMD' {
            $items += @(
                [pscustomobject]@{ Setting = 'Radeon Anti-Lag';             Recommended = 'Enabled';     Current = $verify }
                [pscustomobject]@{ Setting = 'Wait for Vertical Refresh';   Recommended = 'Always Off';  Current = $verify }
                [pscustomobject]@{ Setting = 'Texture Filtering Quality';   Recommended = 'Performance'; Current = $verify }
                [pscustomobject]@{ Setting = 'Surface Format Optimization'; Recommended = 'Enabled';     Current = $verify }
                [pscustomobject]@{ Setting = 'Radeon Chill';               Recommended = 'Off';         Current = $verify }
            )
        }
        'Intel' {
            $items += @(
                [pscustomobject]@{ Setting = 'Vertical Sync';              Recommended = 'Off';              Current = $verify }
                [pscustomobject]@{ Setting = 'Anisotropic Filtering';      Recommended = 'Application choice';Current = $verify }
            )
        }
        default {
            $items += @(
                [pscustomobject]@{ Setting = 'Game profile for cs2.exe';   Recommended = 'High-performance / low-latency'; Current = $verify }
            )
        }
    }
    return [pscustomobject]@{ Vendor = $vendor; Items = @($items) }
}

# Launch the vendor's control panel; falls back to Windows display settings.
function Open-GpuControlPanel {
    param([string]$Vendor)
    try {
        switch ($Vendor) {
            'NVIDIA' {
                $nv = "$env:ProgramFiles\NVIDIA Corporation\Control Panel Client\nvcplui.exe"
                if (Test-Path -LiteralPath $nv) { Start-Process -FilePath $nv; return $true }
                $cmd = Get-Command 'nvcplui.exe' -ErrorAction SilentlyContinue
                if ($cmd) { Start-Process -FilePath $cmd.Source; return $true }
            }
            'AMD' {
                foreach ($p in @(
                    "$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe",
                    "$env:ProgramFiles\AMD\CNext\CNext\cnext.exe")) {
                    if (Test-Path -LiteralPath $p) { Start-Process -FilePath $p; return $true }
                }
            }
        }
        Start-Process 'ms-settings:display'
        return $true
    } catch {
        Write-Log "Could not open control panel: $($_.Exception.Message)" 'WARN'
        return $false
    }
}
