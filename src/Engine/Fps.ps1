<#
    Volante FPS via PresentMon (Intel/GameTechDev, MIT). A vetted PresentMon 1.10
    build is bundled in lib\presentmon and preferred; a settings path or a copy on
    PATH overrides it. If none is found, FPS is reported unavailable and the UI shows
    "n/a". Dot-sourced into Optimizer.Engine.psm1.
#>

function Get-PresentMonPath {
    # Explicit override first, then the bundled/known folders, then PATH.
    try { $p = (Get-AppSettings).presentMonPath; if ($p -and (Test-Path -LiteralPath $p)) { return $p } } catch {}
    $dirs = @(
        (Join-Path $PSScriptRoot '..\..\lib\presentmon'),
        (Join-Path $PSScriptRoot '..\..\tools\presentmon'),
        (Join-Path $script:DataRoot 'presentmon')
    )
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) {
            $exe = Get-ChildItem -LiteralPath $d -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }
    $cmd = Get-Command 'PresentMon.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-FpsAvailable { [bool](Get-PresentMonPath) }

# Capture frame timing for $Seconds and return avg / 1% low / max FPS.
# Requires a game (or any presenting app) to be running during the capture.
function Invoke-FpsBenchmark {
    param([int]$Seconds = 20)
    $pm = Get-PresentMonPath
    if (-not $pm) {
        return [pscustomobject]@{ available = $false; ok = $false
            error = 'PresentMon not found.' }
    }
    $csv = Join-Path $env:TEMP ("volante_pm_{0}.csv" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    try {
        # PresentMon 1.x CLI (single-dash); captures all processes by default.
        $argList = @('-output_file', "`"$csv`"", '-timed', "$Seconds",
                     '-terminate_after_timed', '-stop_existing_session', '-no_top')
        Start-Process -FilePath $pm -ArgumentList $argList -Wait -WindowStyle Hidden -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $csv)) {
            return [pscustomobject]@{ available = $true; ok = $false
                error = 'No frames captured - is a game running?' }
        }
        $rows = @(Import-Csv -LiteralPath $csv)
        if ($rows.Count -eq 0) {
            return [pscustomobject]@{ available = $true; ok = $false; error = 'No frames captured.' }
        }
        # Column name for frame interval varies by PresentMon version.
        $colNames = @($rows[0].PSObject.Properties.Name)
        $col = @('msBetweenPresents', 'MsBetweenPresents', 'msBetweenDisplayChange') |
               Where-Object { $colNames -contains $_ } | Select-Object -First 1
        if (-not $col) {
            return [pscustomobject]@{ available = $true; ok = $false; error = 'Unrecognised PresentMon output.' }
        }
        $fps = @()
        foreach ($r in $rows) {
            $ms = 0.0
            if ([double]::TryParse(("$($r.$col)" -replace ',', '.'), [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$ms) -and $ms -gt 0) {
                $fps += (1000.0 / $ms)
            }
        }
        if ($fps.Count -eq 0) {
            return [pscustomobject]@{ available = $true; ok = $false; error = 'No valid frame data.' }
        }
        $sorted = $fps | Sort-Object
        $avg = [int][math]::Round(($fps | Measure-Object -Average).Average)
        $low = [int][math]::Round($sorted[[math]::Floor($sorted.Count * 0.01)])
        $max = [int][math]::Round($sorted[$sorted.Count - 1])
        [pscustomobject]@{ available = $true; ok = $true; avg = $avg; low1 = $low; max = $max; frames = $fps.Count }
    } catch {
        [pscustomobject]@{ available = $true; ok = $false; error = "$($_.Exception.Message)" }
    } finally {
        if (Test-Path -LiteralPath $csv) { Remove-Item -LiteralPath $csv -Force -ErrorAction SilentlyContinue }
    }
}
