<#
    Volante engine + bridge tests (Pester 3.4, the version built into Windows
    PowerShell 5.1). Run:  Invoke-Pester -Path tests
    These exercise the pure logic and the JSON command contract. Read-only except
    a guarded round-trip on one Safe HKCU tweak (restored) and app-data writes
    under %ProgramData%\Volante (profiles/history).
#>
$enginePath = Join-Path $PSScriptRoot '..\src\Engine\Optimizer.Engine.psm1'
Import-Module $enginePath -Force

Describe 'Tweak catalog integrity' {
    $cat = Get-TweakCatalog
    It 'has tweaks' { @($cat).Count | Should BeGreaterThan 0 }
    It 'every tweak is well-formed' {
        foreach ($t in $cat) {
            $t.Id    | Should Not BeNullOrEmpty
            $t.Name  | Should Not BeNullOrEmpty
            $t.Risk  | Should Match '^(Safe|Caution|Advanced)$'
            $t.Scope | Should Match '^(User|Machine)$'
            $t.Test  | Should Not BeNullOrEmpty
            $t.Apply | Should Not BeNullOrEmpty
            $t.Revert| Should Not BeNullOrEmpty
        }
    }
    It 'has unique ids' {
        $ids = $cat.Id
        ($ids | Select-Object -Unique).Count | Should Be $ids.Count
    }
}

Describe 'Telemetry / version parsing (locale-safe)' {
    It 'parses dot-decimal regardless of locale' {
        InModuleScope Optimizer.Engine {
            $v = ConvertTo-NumOrNull '50.84'
            [math]::Abs($v - 50.84) | Should BeLessThan 0.001
            ConvertTo-NumOrNull '[N/A]' | Should Be $null
        }
    }
    It 'decodes the NVIDIA marketing version' {
        InModuleScope Optimizer.Engine {
            Convert-NvidiaDriverVersion '32.0.15.9579' | Should Be '595.79'
            Convert-NvidiaDriverVersion '31.0.15.5186' | Should Be '551.86'
        }
    }
}

Describe 'Readiness scoring' {
    It 'returns a 0-100 score from synthetic inputs' {
        InModuleScope Optimizer.Engine {
            $refresh = @([pscustomobject]@{ optimal = $true })
            $drivers = @([pscustomobject]@{ stale = $false })
            $pings   = @([pscustomobject]@{ ms = 20 })
            $r = Get-ReadinessFrom -Refresh $refresh -Drivers $drivers -Pings $pings
            $r.score | Should BeGreaterThan -1
            $r.score | Should BeLessThan 101
            $r.issues | Should BeGreaterThan -1
        }
    }
}

Describe 'Command dispatcher (JSON contract)' {
    It 'getDashboard returns ok with readiness + lists' {
        $d = Invoke-VolanteCommand -Message '{"id":"t1","command":"getDashboard","args":{}}' | ConvertFrom-Json
        $d.ok | Should Be $true
        $d.data.readiness.score | Should BeGreaterThan -1
        @($d.data.refresh).Count | Should BeGreaterThan 0
    }
    It 'getTweaks returns cards with required fields' {
        $d = Invoke-VolanteCommand -Message '{"id":"t2","command":"getTweaks","args":{}}' | ConvertFrom-Json
        $d.ok | Should Be $true
        $first = @($d.data)[0]
        $first.id      | Should Not BeNullOrEmpty
        $first.name    | Should Not BeNullOrEmpty
        ($first.enabled -is [bool]) | Should Be $true
    }
    It 'getMonitor returns cpu/gpu/cores' {
        $d = Invoke-VolanteCommand -Message '{"id":"t3","command":"getMonitor","args":{}}' | ConvertFrom-Json
        $d.ok | Should Be $true
        ($d.data.cpu -ge 0) | Should Be $true
        ($d.data.cores).Count | Should BeGreaterThan 0
    }
    It 'revertTweaks + getRestorePoints respond ok' {
        $a = Invoke-VolanteCommand -Message '{"id":"t5","command":"revertTweaks","args":{"ids":[]}}' | ConvertFrom-Json
        $a.ok | Should Be $true
        $a.data.reverted | Should Be 0
        $b = Invoke-VolanteCommand -Message '{"id":"t6","command":"getRestorePoints","args":{}}' | ConvertFrom-Json
        $b.ok | Should Be $true
    }
    It 'unknown command returns ok:false' {
        $d = Invoke-VolanteCommand -Message '{"id":"t4","command":"nope","args":{}}' | ConvertFrom-Json
        $d.ok | Should Be $false
        $d.error | Should Not BeNullOrEmpty
    }
}

Describe 'Profiles persistence' {
    It 'persists the active profile' {
        $orig = (Get-AppProfiles).active
        Set-ActiveProfile -Id 'apex' | Out-Null
        (Get-AppProfiles).active | Should Be 'apex'
        Set-ActiveProfile -Id $orig | Out-Null   # restore
        (Get-AppProfiles).active | Should Be $orig
    }
    It 'saves and resets a custom tweak set' {
        InModuleScope Optimizer.Engine {
            $default = @(Get-ProfileTweakIds -Id 'cs2')
            Save-ProfileTweaks -Id 'cs2' -Ids @('mouse-accel-off', 'game-mode-on') | Out-Null
            (Get-ProfileTweakIds -Id 'cs2').Count | Should Be 2
            Reset-ProfileTweaks -Id 'cs2' | Out-Null
            (Get-ProfileTweakIds -Id 'cs2').Count | Should Be $default.Count
        }
    }
}

Describe 'Settings' {
    It 'round-trips and affects the stale-driver threshold' {
        $orig = (Get-AppSettings).staleDriverDays
        Set-AppSettings -StaleDriverDays 120 | Out-Null
        (Get-AppSettings).staleDriverDays | Should Be 120
        Set-AppSettings -StaleDriverDays $orig | Out-Null
        (Get-AppSettings).staleDriverDays | Should Be $orig
    }
}

Describe 'FPS (bundled PresentMon)' {
    It 'detects the bundled PresentMon' {
        Get-FpsAvailable | Should Be $true
        (Get-PresentMonPath) | Should Match 'PresentMon.*\.exe$'
    }
}

Describe 'Config export/import' {
    It 'round-trips a custom profile set through a file' {
        InModuleScope Optimizer.Engine {
            Save-ProfileTweaks -Id 'apex' -Ids @('mouse-accel-off', 'game-mode-on', 'gamedvr-off') | Out-Null
            $exp = Export-AppConfig
            $exp.ok | Should Be $true
            Test-Path -LiteralPath $exp.path | Should Be $true
            Reset-ProfileTweaks -Id 'apex' | Out-Null
            (Get-ProfileTweakIds -Id 'apex').Count | Should Not Be 3
            $imp = Import-AppConfig -Path $exp.path
            $imp.ok | Should Be $true
            (Get-ProfileTweakIds -Id 'apex').Count | Should Be 3
            Reset-ProfileTweaks -Id 'apex' | Out-Null   # cleanup
        }
    }
}

Describe 'Telemetry history persistence' {
    It 'records and reads back samples' {
        InModuleScope Optimizer.Engine {
            Add-TelemetrySample -Cpu 42 -Gpu 71 -GpuTemp 64 -Force
            $h = Get-TelemetryHistory -Take 10
            @($h).Count | Should BeGreaterThan 0
            $last = @($h)[-1]
            ($last.cpu -ge 0) | Should Be $true
        }
    }
}

Describe 'History persistence' {
    It 'records and reads back an entry' {
        $marker = "test-$([guid]::NewGuid())"
        Add-AppHistory -Type 'check' -Text $marker
        (Get-AppHistory -Take 5 | Where-Object { $_.text -eq $marker }).Count | Should BeGreaterThan 0
    }
}

Describe 'Safe tweak round-trip (HKCU, reversible)' {
    It 'applies then reverts menu-show-delay to its prior state' {
        $t = Get-TweakCatalog | Where-Object Id -eq 'menu-show-delay' | Select-Object -First 1
        $t | Should Not BeNullOrEmpty
        $before = (Invoke-TweakTest $t).Applied
        if (-not $before) {
            (Invoke-TweakApply $t).Result   | Should Be 'Applied'
            (Invoke-TweakTest $t).Applied   | Should Be $true
            (Invoke-TweakRevert $t).Result  | Should Be 'Reverted'
            (Invoke-TweakTest $t).Applied   | Should Be $false
        }
    }
}
