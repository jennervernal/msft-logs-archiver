@{
    TenantId = '00000000-0000-0000-0000-000000000000'
    OutputRoot = 'D:\M365LogArchive'

    ArchiveMode = 'Fixed'

    # Fixed mode: use UTC ISO 8601.
    StartUtc = '2026-09-15T00:00:00Z'
    EndUtc = '2026-09-16T00:00:00Z'

    # Incremental mode: first run looks back this far; later runs resume from durable state.
    IncrementalInitialLookbackHours = 24
    IncrementalOverlapMinutes = 15
    IngestionDelayMinutes = 120
    WindowHours = 1

    # Begin with Small. Medium/Large raise ceilings but adaptation may reduce them at runtime.
    ScaleProfile = 'Small'
    # Override only measured bottlenecks. Supported keys are shown in ScaleProfiles.psd1.
    ServicePolicyOverrides = @{}
    ResourceControls = @{
        MaximumTotalWorkers = 2
        MinimumFreeDiskGB = 10
        MaximumProcessMemoryMB = 2048
        MaximumDeduplicationKeysPerPartition = 500000
        MaximumQueueRecords = 25000
    }

    Collectors = @(
        'EntraAudit'
        'EntraSignIns'
        'EntraRiskySignIns'
        'UnifiedAudit'
        'IntuneAudit'
        'AzureActivity'
        # 'DefenderXdr'
    )

    # Any selected collector not listed here is optional and will not make the run exit nonzero.
    RequiredCollectors = @(
        'EntraAudit'
        'EntraSignIns'
        'UnifiedAudit'
        'IntuneAudit'
        'AzureActivity'
    )

    # Optional. Leave empty to choose all enabled subscriptions visible to the signed-in user.
    AzureSubscriptionIds = @()

    # Optional Exchange interactive sign-in hint.
    ExchangeUserPrincipalName = ''

    # Search-UnifiedAuditLog RecordType values, not friendly workload names. Empty means all.
    UnifiedAuditRecordTypes = @()

    # Defender XDR is optional and requires A5/A5 Security or qualifying Defender licenses.
    DefenderXdrTables = @(
        'AlertInfo'
        'AlertEvidence'
        'DeviceEvents'
        'EmailEvents'
        'IdentityLogonEvents'
    )
}
