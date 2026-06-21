<#
    Volante live telemetry for the monitor screen. No bundled binaries:
      - GPU util / temp / clock / VRAM / power: nvidia-smi (ships with the NVIDIA driver)
      - CPU total + per-core util, GPU util fallback: Get-Counter
      - CPU temperature: MSAcpi_ThermalZoneTemperature (best-effort; null if unsupported)
      - ping: Test-TcpLatency (Dashboard.ps1)
    FPS is added in a later phase (PresentMon); it is not produced here.
    Dot-sourced into Optimizer.Engine.psm1 (module scope).
#>

function ConvertTo-NumOrNull {
    # nvidia-smi always emits '.' decimals; parse with InvariantCulture so it works
    # on machines whose locale uses ',' as the decimal separator.
    param($Text)
    $d = 0.0
    $clean = "$Text" -replace '[^\d.\-]', ''
    if ([double]::TryParse($clean, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-NvidiaSmiSnapshot {
    try {
        $raw = & nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,clocks.gr,memory.used,memory.total,power.draw `
                            --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if (-not $raw) { return $null }
        $f = @($raw -split ',' | ForEach-Object { $_.Trim() })
        if ($f.Count -lt 6) { return $null }
        [pscustomobject]@{
            gpu      = [int](ConvertTo-NumOrNull $f[0])
            gpuTemp  = [int](ConvertTo-NumOrNull $f[1])
            gpuClock = [int](ConvertTo-NumOrNull $f[2])
            memUsed  = [double](ConvertTo-NumOrNull $f[3])
            memTotal = [double](ConvertTo-NumOrNull $f[4])
            power    = [int](ConvertTo-NumOrNull $f[5])
        }
    } catch { return $null }
}

function Get-CpuCounters {
    $cpu = 0; $cores = @()
    try {
        $s = (Get-Counter '\Processor Information(*)\% Processor Utility' -ErrorAction Stop).CounterSamples
        $tot = $s | Where-Object { $_.InstanceName -eq '_Total' } | Select-Object -First 1
        if ($tot) { $cpu = [int][math]::Round([math]::Min(100, $tot.CookedValue)) }
        $cores = @($s | Where-Object { $_.InstanceName -match '^\d+,\d+$' } |
            Sort-Object { $p = $_.InstanceName -split ','; [int]$p[0] * 1000 + [int]$p[1] } |
            ForEach-Object { [int][math]::Round([math]::Min(100, $_.CookedValue)) })
    } catch {}
    [pscustomobject]@{ cpu = $cpu; cores = $cores }
}

function Get-GpuUtilCounter {
    try {
        $g = (Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop).CounterSamples
        return [int][math]::Round([math]::Min(100, (($g | Measure-Object -Property CookedValue -Sum).Sum)))
    } catch { return 0 }
}

function Get-CpuTemperature {
    # ACPI thermal zone, tenths of Kelvin. Often a board sensor (not the die) and not
    # always exposed, so this is best-effort - null when unavailable.
    try {
        $t = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
             Select-Object -First 1
        if ($t -and $t.CurrentTemperature) { return [int][math]::Round(($t.CurrentTemperature / 10) - 273.15) }
    } catch {}
    return $null
}

# One snapshot in the design's mon{} shape (minus fps/frameMs/hist, which the UI
# keeps until PresentMon lands in a later phase).
function Get-MonitorTelemetry {
    $nv = Get-NvidiaSmiSnapshot
    $c  = Get-CpuCounters
    $os = $null; try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch {}
    [pscustomobject]@{
        cpu       = $c.cpu
        cores     = $c.cores
        cpuTemp   = Get-CpuTemperature
        gpu       = $(if ($nv) { $nv.gpu } else { Get-GpuUtilCounter })
        gpuTemp   = $(if ($nv) { $nv.gpuTemp } else { 0 })
        gpuClock  = $(if ($nv) { $nv.gpuClock } else { 0 })
        vram      = $(if ($nv) { [math]::Round($nv.memUsed / 1024, 1) } else { 0 })
        vramTotal = $(if ($nv) { [math]::Round($nv.memTotal / 1024, 0) } else { 0 })
        power     = $(if ($nv) { $nv.power } else { 0 })
        ramUsed   = $(if ($os) { [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1048576, 1) } else { 0 })
        ramTotal  = $(if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1048576, 0) } else { 0 })
        ping      = (Test-TcpLatency -HostName 'api.steampowered.com' -Port 443 -TimeoutMs 600)
    }
}
