[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Path')][string]$ConfigPath,
    [Parameter(Mandatory, ParameterSetName = 'Object')][hashtable]$ConfigData,
    [Parameter(ParameterSetName = 'Object')][switch]$NoDisconnect,
    [Parameter(ParameterSetName = 'Object')][switch]$PassThruExitCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Archive.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'M365Archive.RateLimit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'M365Archive.Collectors.psm1') -Force

$lock = $null
$exchangeConnected = $false
$runStatuses = [Collections.Generic.List[object]]::new()
$exitCode = 0
$logInitialized = $false
$runtimeInitialized = $false
$runRoot = $null
$checkpoint = $null

try {
    $config = if ($PSCmdlet.ParameterSetName -eq 'Object') {
        $ConfigData
    }
    else {
        $resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
        $loadedConfig = & $resolvedConfig
        if ($loadedConfig -isnot [hashtable]) { throw "Configuration '$resolvedConfig' must return a hashtable." }
        $loadedConfig
    }
    Assert-ArchiveConfig $config | Out-Null
    $requiredModules = [Collections.Generic.List[string]]::new()
    if (@($config.Collectors) | Where-Object { $_ -in @('EntraAudit', 'EntraSignIns', 'EntraRiskySignIns', 'IntuneAudit', 'DefenderXdr') }) {
        $requiredModules.Add('Microsoft.Graph.Authentication')
    }
    if (@($config.Collectors) -contains 'UnifiedAudit') { $requiredModules.Add('ExchangeOnlineManagement') }
    if (@($config.Collectors) -contains 'AzureActivity') { $requiredModules.Add('Az.Accounts') }
    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "Required module '$moduleName' is not installed. Run Install-ArchivePrerequisites.ps1."
        }
        Import-Module $moduleName -ErrorAction Stop
    }

    $outputRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$config.OutputRoot))
    $capacity = Assert-ResourceCapacity -OutputRoot $outputRoot `
        -MinimumFreeDiskGB $config.ResourceControls.MinimumFreeDiskGB `
        -MaximumProcessMemoryMB $config.ResourceControls.MaximumProcessMemoryMB
    $incrementalStateName = if ($config.ContainsKey('IncrementalStateKey')) {
        "incremental-$($config.TenantId)-$($config.IncrementalStateKey).json"
    }
    else {
        "incremental-$($config.TenantId).json"
    }
    $incrementalStatePath = Join-Path $outputRoot (Join-Path '_state' $incrementalStateName)
    $dateRange = Resolve-ArchiveDateRange -Config $config -StatePath $incrementalStatePath
    $startUtc = $dateRange.StartUtc
    $endUtc = $dateRange.EndUtc
    $lock = Enter-ArchiveLock $outputRoot
    if ($config.ArchiveMode -eq 'Incremental') {
        $pendingState = [ordered]@{
            schemaVersion = '1.0'
            tenantId = $config.TenantId
            pendingStartUtc = $startUtc.ToString('o')
            pendingEndUtc = $endUtc.ToString('o')
            updatedUtc = [DateTime]::UtcNow.ToString('o')
        }
        if ($config.ContainsKey('IncrementalStateKey')) {
            $pendingState.incrementalStateKey = $config.IncrementalStateKey
        }
        if (Test-Path -LiteralPath $incrementalStatePath) {
            $existingIncrementalState = Get-Content -LiteralPath $incrementalStatePath -Raw -Encoding utf8 |
                ConvertFrom-Json -AsHashtable
            if ($existingIncrementalState.ContainsKey('lastSuccessfulEndUtc')) {
                $pendingState.lastSuccessfulEndUtc = $existingIncrementalState.lastSuccessfulEndUtc
            }
        }
        Write-JsonAtomic -Path $incrementalStatePath -Value $pendingState
    }
    $azureSelection = if ($config.ContainsKey('AzureSubscriptionIds')) { @($config.AzureSubscriptionIds) -join ',' } else { '' }
    $unifiedSelection = if ($config.ContainsKey('UnifiedAuditRecordTypes')) { @($config.UnifiedAuditRecordTypes) -join ',' } else { '' }
    $defenderSelection = if ($config.ContainsKey('DefenderXdrTables')) { @($config.DefenderXdrTables) -join ',' } else { '' }
    $overrideFingerprint = if ($config.ContainsKey('ServicePolicyOverrides')) { $config.ServicePolicyOverrides | ConvertTo-Json -Compress -Depth 10 } else { '' }
    $resourceFingerprint = $config.ResourceControls | ConvertTo-Json -Compress -Depth 5
    $fingerprintInput = "$($config.TenantId)|$($startUtc.ToString('o'))|$($endUtc.ToString('o'))|$(@($config.Collectors) -join ',')|$($config.WindowHours)|$azureSelection|$unifiedSelection|$defenderSelection|$($config.ScaleProfile)|$overrideFingerprint|$resourceFingerprint"
    $runId = "$($startUtc.ToString('yyyyMMddTHHmmssZ'))-$((Get-StableHash $fingerprintInput).Substring(0, 12))"
    $runRoot = Join-Path $outputRoot (Join-Path '_runs' $runId)
    Initialize-ArchiveLog (Join-Path $runRoot 'run.log.jsonl')
    $logInitialized = $true
    $profiles = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'ScaleProfiles.psd1')
    $policyOverrides = if ($config.ContainsKey('ServicePolicyOverrides')) { $config.ServicePolicyOverrides } else { @{} }
    $servicePolicies = Resolve-ServicePolicies -Profiles $profiles -ProfileName $config.ScaleProfile -Overrides $policyOverrides
    $configuredMaximumWindowMinutes = [double]$config.WindowHours * 60
    foreach ($service in $servicePolicies.Keys) {
        $servicePolicies[$service].MaxConcurrency = [Math]::Min(
            [int]$servicePolicies[$service].MaxConcurrency,
            [int]$config.ResourceControls.MaximumTotalWorkers
        )
        $servicePolicies[$service].MaxWindowMinutes = [Math]::Min(
            [double]$servicePolicies[$service].MaxWindowMinutes,
            $configuredMaximumWindowMinutes
        )
        $servicePolicies[$service].InitialWindowMinutes = [Math]::Min(
            [double]$servicePolicies[$service].InitialWindowMinutes,
            [double]$servicePolicies[$service].MaxWindowMinutes
        )
        $servicePolicies[$service].MinWindowMinutes = [Math]::Min(
            [double]$servicePolicies[$service].MinWindowMinutes,
            [double]$servicePolicies[$service].InitialWindowMinutes
        )
    }
    Initialize-ApiRuntime -Policies $servicePolicies -StatePath (Join-Path $outputRoot '_state\throttle-state.json')
    $runtimeInitialized = $true
    $checkpointPath = Join-Path $runRoot 'checkpoint.json'
    $checkpoint = Read-Checkpoint $checkpointPath
    $checkpoint['runId'] = $runId
    $checkpoint['configFingerprint'] = Get-StableHash $fingerprintInput
    $checkpoint['queryStartUtc'] = $startUtc.ToString('o')
    $checkpoint['queryEndUtc'] = $endUtc.ToString('o')
    if (-not $checkpoint.ContainsKey('collectorCursors')) { $checkpoint['collectorCursors'] = @{} }
    if (-not $checkpoint.ContainsKey('activeWindows')) { $checkpoint['activeWindows'] = @{} }
    Save-Checkpoint $checkpointPath $checkpoint
    Write-ArchiveLog INFO "Starting archive run $runId."

    $collectors = @($config.Collectors)
    if ($collectors -contains 'UnifiedAudit') {
        $exchangeUpn = if ($config.ContainsKey('ExchangeUserPrincipalName')) { [string]$config.ExchangeUserPrincipalName } else { '' }
        Connect-ArchiveExchange -UserPrincipalName $exchangeUpn
        $exchangeConnected = $true
    }
    if ($collectors -contains 'AzureActivity') {
        Connect-ArchiveAzure -TenantId $config.TenantId
    }
    $graphScopes = [Collections.Generic.List[string]]::new()
    if ($collectors | Where-Object { $_ -in @('EntraAudit', 'EntraSignIns', 'EntraRiskySignIns') }) { $graphScopes.Add('AuditLog.Read.All') }
    if ($collectors -contains 'IntuneAudit') { $graphScopes.Add('DeviceManagementApps.Read.All') }
    if ($collectors -contains 'DefenderXdr') { $graphScopes.Add('ThreatHunting.Read.All') }
    if ($graphScopes.Count -gt 0) { Connect-ArchiveGraph -TenantId $config.TenantId -Scopes $graphScopes.ToArray() }
    $selectedAzureSubscriptions = @()
    if ($collectors -contains 'AzureActivity') {
        $selectedAzureSubscriptions = @($config.AzureSubscriptionIds)
        if ($selectedAzureSubscriptions.Count -eq 0) {
            $selectedAzureSubscriptions = @((Invoke-ServiceOperation -Service Azure -OperationName 'List Azure subscriptions' -Operation {
                Get-AzSubscription -TenantId $config.TenantId
            } | Where-Object State -eq 'Enabled').Id)
        }
    }

    foreach ($collector in $collectors) {
        $collectorStarted = [DateTime]::UtcNow
        $service = switch ($collector) {
            'UnifiedAudit' { 'Purview' }
            'AzureActivity' { 'Azure' }
            'DefenderXdr' { 'Defender' }
            default { 'Graph' }
        }
        $isOptional = $collector -notin @($config.RequiredCollectors)
        if ($collector -eq 'AzureActivity' -and $selectedAzureSubscriptions.Count -eq 0) {
            $runStatuses.Add([pscustomobject]@{
                source = $collector; status = 'skipped-unavailable'; optional = $isOptional
                error = 'No enabled Azure subscriptions are visible to the signed-in user.'
                partitions = 0; records = 0
                elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $collectorStarted).TotalSeconds, 3)
                recordsPerSecond = 0
            })
            Write-ArchiveLog WARN 'Azure Activity is unavailable because no enabled subscriptions are visible; collector skipped.'
            continue
        }
        if ($collector -eq 'IntuneAudit') {
            $capability = Test-IntuneAuditCapability -TenantId $config.TenantId
            if (-not $capability.Available) {
                $runStatuses.Add([pscustomobject]@{
                    source = $collector; status = 'skipped-unavailable'; optional = $isOptional
                    error = $capability.Reason; partitions = 0; records = 0
                    elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $collectorStarted).TotalSeconds, 3)
                    recordsPerSecond = 0
                })
                Write-ArchiveLog WARN 'Intune audit is unavailable for this tenant; collector skipped.' @{ reason = $capability.Reason }
                continue
            }
        }
        if ($collector -eq 'DefenderXdr') {
            $capability = Test-DefenderXdrCapability -TenantId $config.TenantId
            if (-not $capability.Available) {
                $runStatuses.Add([pscustomobject]@{
                    source = $collector; status = 'skipped-unavailable'; optional = $true
                    error = $capability.Reason; partitions = 0; records = 0
                    elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $collectorStarted).TotalSeconds, 3)
                    recordsPerSecond = 0
                })
                Write-ArchiveLog WARN 'Defender XDR is unavailable or not authorized; collector skipped.' @{ reason = $capability.Reason }
                continue
            }
        }

        $partitionCount = 0
        $recordCount = 0
        try {
            $cursor = if ($checkpoint.collectorCursors.ContainsKey($collector)) {
                ConvertTo-UtcDateTime $checkpoint.collectorCursors[$collector] "collector cursor for $collector"
            }
            else { $startUtc }
            while ($cursor -lt $endUtc) {
                if ($checkpoint.activeWindows.ContainsKey($collector)) {
                    $savedWindow = $checkpoint.activeWindows[$collector]
                    $window = [pscustomobject]@{
                        StartUtc = ConvertTo-UtcDateTime $savedWindow.startUtc "active window start for $collector"
                        EndUtc = ConvertTo-UtcDateTime $savedWindow.endUtc "active window end for $collector"
                    }
                }
                else {
                    $runtime = Get-ServiceRuntime $service
                    $windowEnd = $cursor.AddMinutes($runtime.CurrentWindowMinutes)
                    if ($windowEnd -gt $endUtc) { $windowEnd = $endUtc }
                    $window = [pscustomobject]@{ StartUtc = $cursor; EndUtc = $windowEnd }
                    $checkpoint.activeWindows[$collector] = @{
                        startUtc = $window.StartUtc.ToString('o')
                        endUtc = $window.EndUtc.ToString('o')
                        service = $service
                    }
                    Save-Checkpoint $checkpointPath $checkpoint
                }
                $targets = if ($collector -eq 'AzureActivity') {
                    @($selectedAzureSubscriptions | ForEach-Object { [pscustomobject]@{ Suffix = $_; SubscriptionId = $_ } })
                }
                elseif ($collector -eq 'DefenderXdr') {
                    @($config.DefenderXdrTables | ForEach-Object {
                        [pscustomobject]@{ Suffix = $_; SubscriptionId = $null; Table = $_ }
                    })
                }
                else { @([pscustomobject]@{ Suffix = $null; SubscriptionId = $null; Table = $null }) }

                foreach ($target in $targets) {
                    $source = if ($target.Suffix) { "$collector-$($target.Suffix)" } else { $collector }
                    $partitionKey = "$source|$($window.StartUtc.ToString('o'))|$($window.EndUtc.ToString('o'))"
                    if ($checkpoint.completedPartitions.ContainsKey($partitionKey)) {
                        Write-ArchiveLog INFO "Skipping completed partition $partitionKey."
                        continue
                    }
                    Write-ArchiveLog INFO "Collecting $source from $($window.StartUtc.ToString('o')) to $($window.EndUtc.ToString('o'))."
                    try {
                        $recordProducer = {
                            switch ($collector) {
                                'EntraAudit' { Get-EntraAuditRecords -TenantId $config.TenantId -StartUtc $window.StartUtc -EndUtc $window.EndUtc }
                                'EntraSignIns' { Get-EntraSignInRecords -TenantId $config.TenantId -StartUtc $window.StartUtc -EndUtc $window.EndUtc }
                                'EntraRiskySignIns' { Get-EntraSignInRecords -TenantId $config.TenantId -StartUtc $window.StartUtc -EndUtc $window.EndUtc -RiskyOnly }
                                'UnifiedAudit' {
                                    Get-UnifiedAuditRecords -StartUtc $window.StartUtc -EndUtc $window.EndUtc `
                                        -Workloads @($config.UnifiedAuditRecordTypes) `
                                        -MaximumBufferedRecords $config.ResourceControls.MaximumQueueRecords
                                }
                                'IntuneAudit' { Get-IntuneAuditRecords -TenantId $config.TenantId -StartUtc $window.StartUtc -EndUtc $window.EndUtc }
                                'AzureActivity' { Get-AzureActivityRecords -SubscriptionId $target.SubscriptionId -StartUtc $window.StartUtc -EndUtc $window.EndUtc }
                                'DefenderXdr' {
                                    Get-DefenderXdrHuntingRecords -TenantId $config.TenantId -StartUtc $window.StartUtc `
                                        -EndUtc $window.EndUtc -Table $target.Table `
                                        -MaximumBufferedRecords $config.ResourceControls.MaximumQueueRecords `
                                        -MinimumWindow ([TimeSpan]::FromMinutes((Get-ServiceRuntime Defender).Policy.MinWindowMinutes))
                                }
                                default { throw "Collector '$collector' is not implemented." }
                            }
                        }
                        $keySelector = switch ($collector) {
                            'UnifiedAudit' { {
                                param($r)
                                $id = Get-RecordValue $r 'Id'
                                if ($id) { $id } else { Get-RecordValue $r 'Identity' }
                            } }
                            'AzureActivity' { {
                                param($r)
                                $id = Get-RecordValue $r 'eventDataId'
                                if ($id) { $id } else { Get-RecordValue $r 'id' }
                            } }
                            'DefenderXdr' { {
                                param($r)
                                $reportId = Get-RecordValue $r 'ReportId'
                                $deviceId = Get-RecordValue $r 'DeviceId'
                                if ($reportId -or $deviceId) {
                                    "$(Get-RecordValue $r 'Timestamp')|$reportId|$deviceId"
                                }
                                else { $null }
                            } }
                            default { { param($r) Get-RecordValue $r 'id' } }
                        }
                        $manifest = Write-ArchivePartition -OutputRoot $outputRoot -Source $source -RunId $runId `
                            -StartUtc $window.StartUtc -EndUtc $window.EndUtc -RecordProducer $recordProducer `
                            -DeduplicationKey $keySelector -MaximumDeduplicationKeys $config.ResourceControls.MaximumDeduplicationKeysPerPartition `
                            -MaximumProcessMemoryMB $config.ResourceControls.MaximumProcessMemoryMB `
                            -MinimumFreeDiskGB $config.ResourceControls.MinimumFreeDiskGB `
                            -Continuation @{ completed = $true; nextLink = $null; service = $service }
                    }
                    catch {
                        Write-FailedPartitionManifest -OutputRoot $outputRoot -Source $source -RunId $runId `
                            -StartUtc $window.StartUtc -EndUtc $window.EndUtc -ErrorMessage $_.Exception.Message `
                            -Continuation @{ completed = $false; retryable = $true }
                        throw
                    }
                    $checkpoint.completedPartitions[$partitionKey] = @{
                        source = $source
                        queryStartUtc = $window.StartUtc.ToString('o')
                        queryEndUtc = $window.EndUtc.ToString('o')
                        archiveFile = $manifest.archiveFile
                        sha256 = $manifest.sha256
                        recordCount = $manifest.recordCount
                        status = 'success'
                    }
                    Save-Checkpoint $checkpointPath $checkpoint
                    $partitionCount++
                    $recordCount += [int]$manifest.recordCount
                    if ($collector -eq 'UnifiedAudit' -and $manifest.recordCount -ge 40000) {
                        Update-AdaptiveState -Service Purview -Outcome Dense
                    }
                }
                $cursor = $window.EndUtc
                $checkpoint.collectorCursors[$collector] = $cursor.ToString('o')
                $checkpoint.activeWindows.Remove($collector)
                Save-Checkpoint $checkpointPath $checkpoint
            }
            $runStatuses.Add([pscustomobject]@{
                source = $collector; status = 'success'; optional = $isOptional
                error = $null; partitions = $partitionCount; records = $recordCount
                elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $collectorStarted).TotalSeconds, 3)
                recordsPerSecond = [Math]::Round($recordCount / [Math]::Max(0.001, ([DateTime]::UtcNow - $collectorStarted).TotalSeconds), 3)
            })
        }
        catch {
            $status = if ($partitionCount -gt 0) {
                if ($isOptional) { 'optional-partial' } else { 'partial' }
            }
            elseif ($isOptional) { 'optional-failed' } else { 'failed' }
            $runStatuses.Add([pscustomobject]@{
                source = $collector; status = $status; optional = $isOptional
                error = $_.Exception.Message; partitions = $partitionCount; records = $recordCount
                elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $collectorStarted).TotalSeconds, 3)
                recordsPerSecond = [Math]::Round($recordCount / [Math]::Max(0.001, ([DateTime]::UtcNow - $collectorStarted).TotalSeconds), 3)
            })
            Write-ArchiveLog ERROR "Collector $collector failed: $($_.Exception.Message)"
            if (-not $isOptional) { $exitCode = 1 }
        }
    }

    if ($exitCode -ne 0) {
        $overallStatus = 'failed'
    }
    elseif (@($runStatuses.status | Where-Object { $_ -ne 'success' }).Count -gt 0) {
        $overallStatus = 'completed-with-skips-or-optional-errors'
    }
    else {
        $overallStatus = 'completed'
    }
    $runManifest = [ordered]@{
        schemaVersion = '1.0'
        runId = $runId
        tenantId = $config.TenantId
        queryStartUtc = $startUtc.ToString('o')
        queryEndUtc = $endUtc.ToString('o')
        completedUtc = [DateTime]::UtcNow.ToString('o')
        status = $overallStatus
        collectors = $runStatuses
        partitions = @($checkpoint.completedPartitions.GetEnumerator() | ForEach-Object {
            [ordered]@{ key = $_.Key; details = $_.Value }
        })
        checkpointFile = 'checkpoint.json'
        configFingerprint = $checkpoint['configFingerprint']
        scaleProfile = $config.ScaleProfile
        resourcePreflight = @{
            freeDiskGB = [Math]::Round($capacity.FreeDiskGB, 2)
            processMemoryMB = [Math]::Round($capacity.ProcessMemoryMB, 1)
        }
        resourceLimits = $config.ResourceControls
        apiMetrics = (Get-ApiRuntimeSnapshot)
    }
    Write-JsonAtomic -Path (Join-Path $runRoot 'run.manifest.json') -Value $runManifest
    $requiredCollectorsComplete = Test-RequiredCollectorsComplete `
        -Statuses $runStatuses -RequiredCollectors @($config.RequiredCollectors)
    if ($exitCode -eq 0 -and $requiredCollectorsComplete -and $config.ArchiveMode -eq 'Incremental') {
        Write-JsonAtomic -Path $incrementalStatePath -Value @{
            schemaVersion = '1.0'
            tenantId = $config.TenantId
            lastSuccessfulEndUtc = $endUtc.ToString('o')
            updatedUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    Write-ArchiveLog INFO "Archive run $runId finished with status $($runManifest.status)."
}
catch {
    $exitCode = 1
    if ($logInitialized) {
        Write-ArchiveLog ERROR $_.Exception.Message
        $failureRunId = if ($checkpoint -and $checkpoint.ContainsKey('runId')) { $checkpoint.runId } else { $null }
        $failureMetrics = if ($runtimeInitialized) { Get-ApiRuntimeSnapshot } else { @{} }
        $failureManifest = [ordered]@{
            schemaVersion = '1.0'
            runId = $failureRunId
            completedUtc = [DateTime]::UtcNow.ToString('o')
            status = 'failed'
            fatalError = $_.Exception.Message
            collectors = $runStatuses
            apiMetrics = $failureMetrics
        }
        Write-JsonAtomic -Path (Join-Path $runRoot 'run.manifest.json') -Value $failureManifest
    }
    else { Write-Error $_ }
}
finally {
    if (-not $NoDisconnect) {
        if ($exchangeConnected) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
        if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
    }
    if ($lock) { Exit-ArchiveLock $lock }
}

if ($PassThruExitCode) { return $exitCode }
exit $exitCode
