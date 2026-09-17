Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Archive.Core.psm1')

$script:Runtimes = @{}
$script:StatePath = $null

function Get-HeaderValue {
    param($Headers, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]$key -ieq $Name) { return [string]$Headers[$key] }
        }
    }
    try {
        $values = $Headers.GetValues($Name)
        if ($values) { return [string]($values | Select-Object -First 1) }
    }
    catch { }
    $property = $Headers.PSObject.Properties | Where-Object Name -IEQ $Name | Select-Object -First 1
    if ($property) { return [string]$property.Value }
    return $null
}

function Get-RetryAfterSeconds {
    [CmdletBinding()]
    param($Headers, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

    $milliseconds = Get-HeaderValue $Headers 'x-ms-retry-after-ms'
    $msValue = 0.0
    if ($milliseconds -and [double]::TryParse($milliseconds, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$msValue)) {
        return [Math]::Max(0.0, $msValue / 1000)
    }
    $value = Get-HeaderValue $Headers 'Retry-After'
    $seconds = 0.0
    if ($value -and [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
        return [Math]::Max(0.0, $seconds)
    }
    $date = [DateTimeOffset]::MinValue
    if ($value -and [DateTimeOffset]::TryParseExact(
        $value,
        'r',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$date
    )) {
        return [Math]::Max(0.0, ($date - $Now).TotalSeconds)
    }
    return 0.0
}

function Get-FullJitterDelaySeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][double]$BaseDelaySeconds,
        [Parameter(Mandatory)][double]$MaxDelaySeconds,
        [double]$RandomFraction = ((Get-Random -Minimum 0 -Maximum 1000000) / 1000000.0)
    )
    if ($Attempt -lt 1 -or $BaseDelaySeconds -lt 0 -or $MaxDelaySeconds -le 0) { throw 'Invalid backoff arguments.' }
    if ($RandomFraction -lt 0 -or $RandomFraction -gt 1) { throw 'RandomFraction must be from 0 through 1.' }
    $cap = [Math]::Min($MaxDelaySeconds, $BaseDelaySeconds * [Math]::Pow(2, $Attempt - 1))
    return $cap * $RandomFraction
}

function Get-ApiFailureClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord, [ValidateSet('Graph', 'Purview', 'Azure', 'Defender')][string]$Service)

    $exception = $ErrorRecord.Exception
    $responseProperty = $exception.PSObject.Properties['Response']
    $response = if ($responseProperty) { $responseProperty.Value } else { $null }
    $statusCode = 0
    if ($response -and $response.StatusCode) { $statusCode = [int]$response.StatusCode }
    elseif ($exception.PSObject.Properties['StatusCode']) { $statusCode = [int]$exception.StatusCode }

    $kind = 'Permanent'
    if ($statusCode -eq 429) { $kind = 'Throttle' }
    elseif ($Service -eq 'Graph' -and $exception.Message -match '(?i)\b(TooManyRequests|Too Many Requests|status code:\s*429)\b') { $kind = 'Throttle' }
    elseif ($statusCode -in @(408, 500, 502, 503, 504)) { $kind = 'Transient' }
    elseif (
        $exception -is [Net.Http.HttpRequestException] -or
        $exception.InnerException -is [Net.Http.HttpRequestException] -or
        $exception -is [Threading.Tasks.TaskCanceledException] -or
        $exception -is [TimeoutException]
    ) { $kind = 'Transient' }
    elseif ($Service -eq 'Purview' -and $exception.Message -match '(?i)\b(throttl|server busy|server side error|temporar(?:y|ily) unavailable|timed? out|timeout|try again)\b') {
        $kind = if ($exception.Message -match '(?i)throttl|server busy') { 'Throttle' } else { 'Transient' }
    }

    [pscustomobject]@{
        Kind = $kind
        StatusCode = $statusCode
        Retryable = $kind -in @('Throttle', 'Transient')
        Headers = if ($response) { $response.Headers } else { $null }
    }
}

function Assert-ServicePolicies {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Policies)
    $required = @(
        'MaxAttempts', 'BaseDelaySeconds', 'MaxDelaySeconds', 'MinSpacingMilliseconds',
        'MaxConcurrency', 'CircuitBreakerThreshold', 'CircuitBreakerCooldownSeconds',
        'InitialWindowMinutes', 'MinWindowMinutes', 'MaxWindowMinutes', 'PageSize',
        'MinPageSize', 'RecoverySuccesses'
    )
    foreach ($service in @('Graph', 'Purview', 'Azure', 'Defender')) {
        if (-not $Policies.ContainsKey($service)) { throw "Missing service policy '$service'." }
        $policy = $Policies[$service]
        foreach ($name in $required) {
            if (-not $policy.ContainsKey($name)) { throw "$service policy is missing '$name'." }
            if ([double]$policy[$name] -lt 0) { throw "$service policy '$name' cannot be negative." }
        }
        if ([int]$policy.MaxAttempts -lt 1 -or [int]$policy.MaxAttempts -gt 20) { throw "$service MaxAttempts must be 1-20." }
        if ([int]$policy.MaxConcurrency -lt 1 -or [int]$policy.MaxConcurrency -gt 16) { throw "$service MaxConcurrency must be 1-16." }
        if ([double]$policy.BaseDelaySeconds -gt [double]$policy.MaxDelaySeconds) { throw "$service BaseDelaySeconds exceeds MaxDelaySeconds." }
        if ([double]$policy.MinWindowMinutes -le 0 -or [double]$policy.InitialWindowMinutes -lt [double]$policy.MinWindowMinutes -or
            [double]$policy.InitialWindowMinutes -gt [double]$policy.MaxWindowMinutes) {
            throw "$service window sizing is invalid."
        }
        if ([int]$policy.MinPageSize -lt 1 -or [int]$policy.PageSize -lt [int]$policy.MinPageSize) { throw "$service page sizing is invalid." }
        $pageMaximum = switch ($service) { 'Graph' { 1000 }; 'Purview' { 5000 }; 'Azure' { 1000 }; 'Defender' { 100000 } }
        if ([int]$policy.PageSize -gt $pageMaximum) { throw "$service PageSize exceeds its supported safety ceiling ($pageMaximum)." }
        if ($service -eq 'Purview' -and [int]$policy.MaxConcurrency -ne 1) {
            throw 'Purview MaxConcurrency must remain 1 to preserve Search-UnifiedAuditLog session paging.'
        }
    }
    return $true
}

function Resolve-ServicePolicies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Profiles,
        [Parameter(Mandatory)][string]$ProfileName,
        [hashtable]$Overrides = @{}
    )
    if (-not $Profiles.ContainsKey($ProfileName)) { throw "Unknown scale profile '$ProfileName'." }
    $resolved = @{}
    foreach ($service in $Profiles[$ProfileName].Keys) {
        $resolved[$service] = @{}
        foreach ($key in $Profiles[$ProfileName][$service].Keys) {
            $resolved[$service][$key] = $Profiles[$ProfileName][$service][$key]
        }
        if ($Overrides.ContainsKey($service)) {
            foreach ($key in $Overrides[$service].Keys) {
                if (-not $resolved[$service].ContainsKey($key)) { throw "Unknown $service policy setting '$key'." }
                $resolved[$service][$key] = $Overrides[$service][$key]
            }
        }
    }
    Assert-ServicePolicies $resolved | Out-Null
    return $resolved
}

function Initialize-ApiRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Policies, [Parameter(Mandatory)][string]$StatePath)

    Assert-ServicePolicies $Policies | Out-Null
    $script:StatePath = $StatePath
    $persisted = @{}
    if (Test-Path -LiteralPath $StatePath) {
        try { $persisted = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
        catch { throw "Throttle state '$StatePath' is invalid: $($_.Exception.Message)" }
    }
    $script:Runtimes = @{}
    foreach ($service in $Policies.Keys) {
        $policy = $Policies[$service]
        $saved = if ($persisted.ContainsKey($service)) { $persisted[$service] } else { @{} }
        $script:Runtimes[$service] = @{
            Service = $service
            Policy = $policy
            EffectiveConcurrency = if ($saved.ContainsKey('effectiveConcurrency')) {
                [Math]::Min([int]$policy.MaxConcurrency, [Math]::Max(1, [int]$saved.effectiveConcurrency))
            } else { [int]$policy.MaxConcurrency }
            CurrentWindowMinutes = if ($saved.ContainsKey('currentWindowMinutes')) {
                [Math]::Min([double]$policy.MaxWindowMinutes, [Math]::Max([double]$policy.MinWindowMinutes, [double]$saved.currentWindowMinutes))
            } else { [double]$policy.InitialWindowMinutes }
            CurrentPageSize = if ($saved.ContainsKey('currentPageSize')) {
                [Math]::Min([int]$policy.PageSize, [Math]::Max([int]$policy.MinPageSize, [int]$saved.currentPageSize))
            } else { [int]$policy.PageSize }
            ConsecutiveFailures = if ($saved.ContainsKey('consecutiveFailures')) { [int]$saved.consecutiveFailures } else { 0 }
            SuccessStreak = 0
            OpenUntilUtc = if ($saved.ContainsKey('openUntilUtc') -and $saved.openUntilUtc) {
                [DateTimeOffset]::Parse($saved.openUntilUtc)
            } else { $null }
            LastRequestUtc = $null
            ActiveRequests = 0
            SyncRoot = [object]::new()
            StartedUtc = [DateTime]::UtcNow
            Metrics = @{
                attempts = 0; requests = 0; pages = 0; successes = 0; throttles = 0; transients = 0
                permanentFailures = 0; throttleWaitMilliseconds = 0.0; transientWaitMilliseconds = 0.0; spacingWaitMilliseconds = 0.0
                circuitBreakerEvents = 0; windowChanges = 0; concurrencyChanges = 0; pageSizeChanges = 0
                lowQuotaSignals = 0
            }
        }
    }
    Save-ApiRuntimeState
}

function Save-ApiRuntimeState {
    if (-not $script:StatePath) { return }
    $state = @{ schemaVersion = '1.0'; updatedUtc = [DateTime]::UtcNow.ToString('o') }
    foreach ($service in $script:Runtimes.Keys) {
        $runtime = $script:Runtimes[$service]
        $state[$service] = @{
            effectiveConcurrency = $runtime.EffectiveConcurrency
            currentWindowMinutes = $runtime.CurrentWindowMinutes
            currentPageSize = $runtime.CurrentPageSize
            consecutiveFailures = $runtime.ConsecutiveFailures
            openUntilUtc = if ($runtime.OpenUntilUtc) { $runtime.OpenUntilUtc.ToString('o') } else { $null }
        }
    }
    Write-JsonAtomic -Path $script:StatePath -Value $state
}

function Get-ServiceRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Graph', 'Purview', 'Azure', 'Defender')][string]$Service)
    if (-not $script:Runtimes.ContainsKey($Service)) { throw "API runtime for '$Service' is not initialized." }
    return $script:Runtimes[$Service]
}

function Update-AdaptiveState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Graph', 'Purview', 'Azure', 'Defender')][string]$Service,
        [Parameter(Mandatory)][ValidateSet('Success', 'Throttle', 'Transient', 'Dense', 'LowQuota')][string]$Outcome
    )
    $runtime = Get-ServiceRuntime $Service
    $policy = $runtime.Policy
    $oldConcurrency = $runtime.EffectiveConcurrency
    $oldWindow = $runtime.CurrentWindowMinutes
    $oldPage = $runtime.CurrentPageSize
    if ($Outcome -in @('Throttle', 'Transient', 'Dense', 'LowQuota')) {
        $runtime.SuccessStreak = 0
        if ($Outcome -ne 'Dense') {
            $runtime.EffectiveConcurrency = [Math]::Max(1, [int][Math]::Floor($runtime.EffectiveConcurrency / 2))
            $runtime.CurrentPageSize = [Math]::Max([int]$policy.MinPageSize, [int][Math]::Floor($runtime.CurrentPageSize / 2))
        }
        $runtime.CurrentWindowMinutes = [Math]::Max([double]$policy.MinWindowMinutes, $runtime.CurrentWindowMinutes / 2)
        if ($oldConcurrency -ne $runtime.EffectiveConcurrency) { $runtime.Metrics.concurrencyChanges++ }
        if ($oldWindow -ne $runtime.CurrentWindowMinutes) { $runtime.Metrics.windowChanges++ }
        if ($oldPage -ne $runtime.CurrentPageSize) { $runtime.Metrics.pageSizeChanges++ }
    }
    else {
        $runtime.SuccessStreak++
        if ($runtime.SuccessStreak -ge [int]$policy.RecoverySuccesses) {
            $runtime.SuccessStreak = 0
            if ($runtime.EffectiveConcurrency -lt [int]$policy.MaxConcurrency) {
                $runtime.EffectiveConcurrency++
                $runtime.Metrics.concurrencyChanges++
            }
            if ($runtime.CurrentWindowMinutes -lt [double]$policy.MaxWindowMinutes) {
                $runtime.CurrentWindowMinutes = [Math]::Min([double]$policy.MaxWindowMinutes, $runtime.CurrentWindowMinutes * 1.25)
                $runtime.Metrics.windowChanges++
            }
            if ($runtime.CurrentPageSize -lt [int]$policy.PageSize) {
                $runtime.CurrentPageSize = [Math]::Min([int]$policy.PageSize, [Math]::Max($runtime.CurrentPageSize + 1, [int][Math]::Ceiling($runtime.CurrentPageSize * 1.25)))
                $runtime.Metrics.pageSizeChanges++
            }
        }
    }
    if (
        $oldConcurrency -ne $runtime.EffectiveConcurrency -or
        $oldWindow -ne $runtime.CurrentWindowMinutes -or
        $oldPage -ne $runtime.CurrentPageSize
    ) {
        $level = if ($Outcome -eq 'Success') { 'INFO' } else { 'WARN' }
        Write-ArchiveLog -Level $level -Message "$Service adaptive settings changed." -Data @{
            outcome = $Outcome
            effectiveConcurrency = $runtime.EffectiveConcurrency
            windowMinutes = $runtime.CurrentWindowMinutes
            pageSize = $runtime.CurrentPageSize
        }
    }
    Save-ApiRuntimeState
}

function Test-LowQuotaHeaders {
    param($Headers)
    foreach ($name in @(
        'x-ms-ratelimit-remaining-subscription-reads',
        'x-ms-ratelimit-remaining-tenant-reads',
        'x-ms-ratelimit-remaining-subscription-global-reads',
        'x-ms-ratelimit-remaining-subscription-resource-requests',
        'x-ms-ratelimit-remaining-resource',
        'RateLimit-Remaining'
    )) {
        $value = Get-HeaderValue $Headers $name
        $remaining = 0
        if ($value -and $value -match '(\d+)\D*$') {
            $remaining = [int]$Matches[1]
            if ($remaining -le 10) { return $true }
        }
    }
    return $false
}

function Invoke-ServiceOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Graph', 'Purview', 'Azure', 'Defender')][string]$Service,
        [Parameter(Mandatory)][scriptblock]$Operation,
        [Parameter(Mandatory)][string]$OperationName,
        [switch]$IsPage,
        [scriptblock]$Sleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [scriptblock]$Clock = { [DateTimeOffset]::UtcNow },
        [scriptblock]$Random = { (Get-Random -Minimum 0 -Maximum 1000000) / 1000000.0 }
    )

    $runtime = Get-ServiceRuntime $Service
    $policy = $runtime.Policy
    for ($attempt = 1; $attempt -le [int]$policy.MaxAttempts; $attempt++) {
        $now = & $Clock
        if ($runtime.OpenUntilUtc -and $now -lt $runtime.OpenUntilUtc) {
            throw "Circuit breaker for $Service is open until $($runtime.OpenUntilUtc.ToString('o'))."
        }
        if ($runtime.LastRequestUtc) {
            $elapsed = ($now - $runtime.LastRequestUtc).TotalMilliseconds
            $spacingWait = [Math]::Max(0, [double]$policy.MinSpacingMilliseconds - $elapsed)
            if ($spacingWait -gt 0) {
                $runtime.Metrics.spacingWaitMilliseconds += $spacingWait
                & $Sleep ([int][Math]::Ceiling($spacingWait))
                $now = & $Clock
            }
        }
        $runtime.LastRequestUtc = $now
        $runtime.Metrics.attempts++
        $runtime.Metrics.requests++
        try {
            while ($runtime.ActiveRequests -ge $runtime.EffectiveConcurrency) {
                & $Sleep 25
                $runtime.Metrics.spacingWaitMilliseconds += 25
            }
            $runtime.ActiveRequests++
            try { $result = & $Operation }
            finally { $runtime.ActiveRequests-- }
            $runtime.ConsecutiveFailures = 0
            $runtime.OpenUntilUtc = $null
            $runtime.Metrics.successes++
            if ($IsPage) { $runtime.Metrics.pages++ }
            $responseHeaders = if ($result) { Get-RecordValue $result 'Headers' } else { $null }
            if ($responseHeaders -and (Test-LowQuotaHeaders $responseHeaders)) {
                $runtime.Metrics.lowQuotaSignals++
                Update-AdaptiveState -Service $Service -Outcome LowQuota
            }
            else { Update-AdaptiveState -Service $Service -Outcome Success }
            return $result
        }
        catch {
            $classification = Get-ApiFailureClassification -ErrorRecord $_ -Service $Service
            if (-not $classification.Retryable) {
                $runtime.Metrics.permanentFailures++
                throw
            }
            if ($classification.Kind -eq 'Throttle') {
                $runtime.Metrics.throttles++
                Update-AdaptiveState -Service $Service -Outcome Throttle
            }
            else {
                $runtime.Metrics.transients++
                Update-AdaptiveState -Service $Service -Outcome Transient
            }
            $runtime.ConsecutiveFailures++
            if ($runtime.ConsecutiveFailures -ge [int]$policy.CircuitBreakerThreshold) {
                $runtime.OpenUntilUtc = $now.AddSeconds([double]$policy.CircuitBreakerCooldownSeconds)
                $runtime.Metrics.circuitBreakerEvents++
                Write-ArchiveLog WARN "$Service circuit breaker opened." @{ openUntilUtc = $runtime.OpenUntilUtc.ToString('o'); operation = $OperationName }
                Save-ApiRuntimeState
                throw
            }
            Save-ApiRuntimeState
            if ($attempt -eq [int]$policy.MaxAttempts) { throw }
            $retryAfter = Get-RetryAfterSeconds -Headers $classification.Headers -Now $now
            $delay = if ($retryAfter -gt 0) {
                $retryAfter
            }
            else {
                Get-FullJitterDelaySeconds -Attempt $attempt -BaseDelaySeconds $policy.BaseDelaySeconds `
                    -MaxDelaySeconds $policy.MaxDelaySeconds -RandomFraction (& $Random)
            }
            if ($classification.Kind -eq 'Throttle') {
                $runtime.Metrics.throttleWaitMilliseconds += ($delay * 1000)
            }
            else {
                $runtime.Metrics.transientWaitMilliseconds += ($delay * 1000)
            }
            Write-ArchiveLog WARN "$OperationName will retry after service backpressure." @{
                service = $Service; attempt = $attempt; maxAttempts = $policy.MaxAttempts
                classification = $classification.Kind; statusCode = $classification.StatusCode
                delayMilliseconds = [int][Math]::Ceiling($delay * 1000)
                effectiveConcurrency = $runtime.EffectiveConcurrency
                windowMinutes = $runtime.CurrentWindowMinutes
                pageSize = $runtime.CurrentPageSize
            }
            & $Sleep ([int][Math]::Ceiling($delay * 1000))
        }
    }
}

function Get-ApiRuntimeSnapshot {
    [CmdletBinding()]
    param()
    $result = @{}
    foreach ($service in $script:Runtimes.Keys) {
        $runtime = $script:Runtimes[$service]
        $elapsed = [Math]::Max(0.001, ([DateTime]::UtcNow - $runtime.StartedUtc).TotalSeconds)
        $result[$service] = [ordered]@{
            attempts = $runtime.Metrics.attempts
            requests = $runtime.Metrics.requests
            pages = $runtime.Metrics.pages
            successes = $runtime.Metrics.successes
            throttles = $runtime.Metrics.throttles
            transients = $runtime.Metrics.transients
            permanentFailures = $runtime.Metrics.permanentFailures
            cumulativeThrottleWaitSeconds = [Math]::Round($runtime.Metrics.throttleWaitMilliseconds / 1000, 3)
            cumulativeTransientWaitSeconds = [Math]::Round($runtime.Metrics.transientWaitMilliseconds / 1000, 3)
            cumulativeSpacingWaitSeconds = [Math]::Round($runtime.Metrics.spacingWaitMilliseconds / 1000, 3)
            effectiveConcurrency = $runtime.EffectiveConcurrency
            currentWindowMinutes = [Math]::Round($runtime.CurrentWindowMinutes, 3)
            currentPageSize = $runtime.CurrentPageSize
            circuitBreakerEvents = $runtime.Metrics.circuitBreakerEvents
            windowChanges = $runtime.Metrics.windowChanges
            concurrencyChanges = $runtime.Metrics.concurrencyChanges
            pageSizeChanges = $runtime.Metrics.pageSizeChanges
            lowQuotaSignals = $runtime.Metrics.lowQuotaSignals
            requestsPerSecond = [Math]::Round($runtime.Metrics.requests / $elapsed, 3)
        }
    }
    return $result
}

Export-ModuleMember -Function @(
    'Get-RetryAfterSeconds', 'Get-FullJitterDelaySeconds', 'Get-ApiFailureClassification',
    'Assert-ServicePolicies', 'Resolve-ServicePolicies', 'Initialize-ApiRuntime', 'Save-ApiRuntimeState', 'Get-ServiceRuntime',
    'Update-AdaptiveState', 'Invoke-ServiceOperation', 'Get-ApiRuntimeSnapshot'
)
