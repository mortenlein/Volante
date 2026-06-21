<#
    Volante CS2 helpers: detect the Counter-Strike 2 install via Steam, surface
    recommended launch options, and (optionally) write a competitive autoexec.cfg
    with a backup. Read-only except Set-Cs2Autoexec, which backs up any existing
    file first. Dot-sourced into Optimizer.Engine.psm1.
#>

function Get-SteamPath {
    $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    if ($p) { return ($p -replace '/', '\') }
    return $null
}

function Get-SteamLibraryPaths {
    $steam = Get-SteamPath
    if (-not $steam) { return @() }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' | ForEach-Object {
            $libs += ($_.Matches[0].Groups[1].Value -replace '\\\\', '\')
        }
    }
    @($libs | Select-Object -Unique)
}

# CS2 / CS:GO share app id 730.
function Get-Cs2Info {
    $found = $null
    foreach ($lib in Get-SteamLibraryPaths) {
        $manifest = Join-Path $lib 'steamapps\appmanifest_730.acf'
        if (Test-Path -LiteralPath $manifest) {
            $m = Select-String -Path $manifest -Pattern '"installdir"\s+"([^"]+)"' | Select-Object -First 1
            if ($m) {
                $path = Join-Path $lib ("steamapps\common\" + $m.Matches[0].Groups[1].Value)
                if (Test-Path -LiteralPath $path) { $found = $path; break }
            }
        }
    }
    $cfg = if ($found) { Join-Path $found 'game\csgo\cfg' } else { $null }
    [pscustomobject]@{
        installed     = [bool]$found
        path          = $found
        cfgDir        = $cfg
        autoexec      = if ($cfg) { [bool](Test-Path -LiteralPath (Join-Path $cfg 'autoexec.cfg')) } else { $false }
        launchOptions = '-novid -high -nojoy +fps_max 0 +exec autoexec'
    }
}

# Conservative, widely-valid CS2 cvars. Edit to taste; unknown cvars are harmless
# (CS2 just prints "unknown command"). CS2 needs '+exec autoexec' in launch options.
function Get-Cs2AutoexecContent {
@'
// Volante - competitive CS2 autoexec. Add '+exec autoexec' to your launch options.
fps_max 0
rate 786432
cl_join_advertise 2
cl_disablehtmlmotd 1
con_enable 1
mm_dedicated_search_maxping 60
host_writeconfig
'@
}

function Set-Cs2Autoexec {
    $info = Get-Cs2Info
    if (-not $info.installed) { return [pscustomobject]@{ ok = $false; error = 'CS2 install not found.' } }
    $file = Join-Path $info.cfgDir 'autoexec.cfg'
    $backedUp = $false
    try {
        if (-not (Test-Path -LiteralPath $info.cfgDir)) { New-Item -ItemType Directory -Path $info.cfgDir -Force | Out-Null }
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination "$file.volante-backup" -Force; $backedUp = $true }
        Get-Cs2AutoexecContent | Set-Content -LiteralPath $file -Encoding ASCII
        Write-Log "Wrote CS2 autoexec: $file (backup=$backedUp)" 'OK'
        [pscustomobject]@{ ok = $true; path = $file; backedUp = $backedUp; launchOptions = $info.launchOptions }
    } catch {
        Write-Log "CS2 autoexec write failed: $($_.Exception.Message)" 'WARN'
        [pscustomobject]@{ ok = $false; error = "$($_.Exception.Message)" }
    }
}
