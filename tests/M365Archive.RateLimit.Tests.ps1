BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.Core.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\M365Archive.RateLimit.psm1') -Force
    $script:profiles = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\ScaleProfiles.psd1')
}

Describe 'Get-RetryAfterSeconds' {
    It 'parses delta seconds' {
        Get-RetryAfterSeconds -Headers @{ 'Retry-After' = '17' } | Should -Be 17
    }

    It 'parses HTTP-date values' {
        $now = [DateTimeOffset]'2026-01-01T00:00:00Z'
        Get-RetryAfterSeconds -Headers @{ 'Retry-After' = 'Thu, 01 Jan 2026 00:00:30 GMT' } -Now $now |
            Should -Be 30
    }

    It 'prefers Microsoft millisecond retry headers' {
        Get-RetryAfterSeconds -Headers @{ 'Retry-After' = '20'; 'x-ms-retry-after-ms' = '1250' } |
            Should -Be 1.25
    }
}

Describe 'Get-FullJitterDelaySeconds' {
    It 'stays inside the exponential cap' {
        Get-FullJitterDelaySeconds -Attempt 3 -BaseDelaySeconds 2 -MaxDelaySeconds 60 -RandomFraction 0 |
            Should -Be 0
        Get-FullJitterDelaySeconds -Attempt 3 -BaseDelaySeconds 2 -MaxDelaySeconds 60 -RandomFraction 1 |
            Should -Be 8
        Get-FullJitterDelaySeconds -Attempt 10 -BaseDelaySeconds 2 -MaxDelaySeconds 60 -RandomFraction 1 |
            Should -Be 60
    }
}

Describe 'Get-ApiFailureClassification' {
    It 'does not retry permanent authorization errors' {
        $exception = [Exception]::new('Forbidden')
        $exception | Add-Member -NotePropertyName StatusCode -NotePropertyValue 403
        $classification = Get-ApiFailureClassification -ErrorRecord ([Management.Automation.ErrorRecord]::new(
            $exception, 'forbidden', [Management.Automation.ErrorCategory]::PermissionDenied, $null
        )) -Service Graph
        $classification.Kind | Should -Be 'Permanent'
        $classification.Retryable | Should -BeFalse
    }

    It 'classifies timeout and cautious Purview throttle messages' {
        $timeout = [Management.Automation.ErrorRecord]::new([TimeoutException]::new('timeout'), 'timeout', 0, $null)
        (Get-ApiFailureClassification $timeout Graph).Kind | Should -Be 'Transient'
        $ual = [Management.Automation.ErrorRecord]::new([Exception]::new('Server busy; request throttled'), 'busy', 0, $null)
        (Get-ApiFailureClassification $ual Purview).Kind | Should -Be 'Throttle'
    }
}

Describe 'adaptive service runtime' {
    BeforeEach {
        $policies = Resolve-ServicePolicies -Profiles $profiles -ProfileName Medium
        Initialize-ApiRuntime -Policies $policies -StatePath (Join-Path $TestDrive 'throttle.json')
    }

    It 'decreases concurrency, page size, and window after throttling' {
        $before = Get-ServiceRuntime Graph
        $oldConcurrency = $before.EffectiveConcurrency
        $oldPage = $before.CurrentPageSize
        $oldWindow = $before.CurrentWindowMinutes
        Update-AdaptiveState Graph Throttle
        $after = Get-ServiceRuntime Graph
        $after.EffectiveConcurrency | Should -BeLessOrEqual $oldConcurrency
        $after.CurrentPageSize | Should -BeLessThan $oldPage
        $after.CurrentWindowMinutes | Should -BeLessThan $oldWindow
    }

    It 'recovers gradually after the configured sustained success count' {
        Update-AdaptiveState Graph Throttle
        $reduced = (Get-ServiceRuntime Graph).CurrentWindowMinutes
        $needed = (Get-ServiceRuntime Graph).Policy.RecoverySuccesses
        1..$needed | ForEach-Object { Update-AdaptiveState Graph Success }
        (Get-ServiceRuntime Graph).CurrentWindowMinutes | Should -BeGreaterThan $reduced
    }

    It 'opens the circuit after consecutive transient failures without real sleeping' {
        $runtime = Get-ServiceRuntime Graph
        $runtime.Policy.CircuitBreakerThreshold = 2
        $runtime.Policy.MaxAttempts = 4
        {
            Invoke-ServiceOperation -Service Graph -OperationName 'deterministic timeout' `
                -Operation { throw [TimeoutException]::new('timeout') } `
                -Sleep { param($Milliseconds) } -Clock { [DateTimeOffset]'2026-01-01T00:00:00Z' } -Random { 0 }
        } | Should -Throw
        (Get-ApiRuntimeSnapshot).Graph.circuitBreakerEvents | Should -Be 1
    }

    It 'blocks during cooldown and permits a probe after cooldown' {
        $runtime = Get-ServiceRuntime Graph
        $runtime.OpenUntilUtc = [DateTimeOffset]'2026-01-01T00:01:00Z'
        {
            Invoke-ServiceOperation -Service Graph -OperationName 'open circuit' -Operation { 'not called' } `
                -Clock { [DateTimeOffset]'2026-01-01T00:00:30Z' } -Sleep { param($Milliseconds) }
        } | Should -Throw
        $result = Invoke-ServiceOperation -Service Graph -OperationName 'half-open probe' -Operation { 'ok' } `
            -Clock { [DateTimeOffset]'2026-01-01T00:01:01Z' } -Sleep { param($Milliseconds) }
        $result | Should -Be 'ok'
        (Get-ServiceRuntime Graph).OpenUntilUtc | Should -BeNullOrEmpty
    }
}

Describe 'service policy validation' {
    It 'rejects unbounded concurrency' {
        $policies = Resolve-ServicePolicies -Profiles $profiles -ProfileName Small
        $policies.Graph.MaxConcurrency = 17
        { Assert-ServicePolicies $policies } | Should -Throw
    }

    It 'merges known overrides and rejects unknown knobs' {
        $resolved = Resolve-ServicePolicies -Profiles $profiles -ProfileName Small -Overrides @{
            Graph = @{ MaxConcurrency = 2 }
        }
        $resolved.Graph.MaxConcurrency | Should -Be 2
        { Resolve-ServicePolicies -Profiles $profiles -ProfileName Small -Overrides @{ Graph = @{ Invented = 1 } } } |
            Should -Throw
    }

    It 'enforces service page ceilings and serialized Purview paging' {
        $policies = Resolve-ServicePolicies -Profiles $profiles -ProfileName Small
        $policies.Graph.PageSize = 1001
        { Assert-ServicePolicies $policies } | Should -Throw
        $policies = Resolve-ServicePolicies -Profiles $profiles -ProfileName Small
        $policies.Purview.MaxConcurrency = 2
        { Assert-ServicePolicies $policies } | Should -Throw
    }
}

Describe 'Invoke-ServiceOperation deterministic retries' {
    BeforeEach {
        $policies = Resolve-ServicePolicies -Profiles $profiles -ProfileName Small
        Initialize-ApiRuntime -Policies $policies -StatePath (Join-Path $TestDrive 'invoke-state.json')
    }

    It 'honors Retry-After and succeeds on the next attempt' {
        $script:calls = 0
        $script:sleeps = [Collections.Generic.List[int]]::new()
        $result = Invoke-ServiceOperation -Service Graph -OperationName 'mock Graph request' -Operation {
            $script:calls++
            if ($script:calls -eq 1) {
                $response = [pscustomobject]@{ StatusCode = 429; Headers = @{ 'Retry-After' = '3' } }
                $exception = [Exception]::new('throttled')
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
                throw $exception
            }
            [pscustomobject]@{ value = 'ok' }
        } -Sleep { param($Milliseconds) $script:sleeps.Add($Milliseconds) } `
            -Clock { [DateTimeOffset]'2026-01-01T00:00:00Z' } -Random { 0.99 }
        $result.value | Should -Be 'ok'
        $script:calls | Should -Be 2
        $script:sleeps | Should -Contain 3000
        (Get-ApiRuntimeSnapshot).Graph.throttles | Should -Be 1
    }

    It 'does not retry a permanent query error' {
        $script:calls = 0
        {
            Invoke-ServiceOperation -Service Defender -OperationName 'bad KQL' -Operation {
                $script:calls++
                $exception = [Exception]::new('Bad Request')
                $exception | Add-Member -NotePropertyName StatusCode -NotePropertyValue 400
                throw $exception
            } -Sleep { param($Milliseconds) throw 'sleep should not be called' }
        } | Should -Throw
        $script:calls | Should -Be 1
    }
}
