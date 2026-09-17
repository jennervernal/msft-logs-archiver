Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-M365TenantIdFromGraphContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $tenantId = if ($Context -is [Collections.IDictionary]) {
        $Context['TenantId']
    }
    else {
        $property = $Context.PSObject.Properties['TenantId']
        if ($property) { $property.Value } else { $null }
    }
    $parsed = [Guid]::Empty
    if ([string]::IsNullOrWhiteSpace([string]$tenantId) -or
        -not [Guid]::TryParse([string]$tenantId, [ref]$parsed) -or
        $parsed -eq [Guid]::Empty) {
        throw 'Microsoft Graph sign-in did not return a valid tenant ID.'
    }
    return $parsed.ToString()
}

function Get-M365QuickStartPlan {
    [CmdletBinding()]
    param([DateTime]$NowUtc = [DateTime]::UtcNow)

    $now = $NowUtc.ToUniversalTime()
    $definitions = @(
        @{ Collector = 'EntraAudit'; Lookback = '30 days'; Delay = 15; Overlap = 15; Start = { param($end) $end.AddDays(-30) } }
        @{ Collector = 'EntraSignIns'; Lookback = '30 days'; Delay = 15; Overlap = 15; Start = { param($end) $end.AddDays(-30) } }
        @{ Collector = 'UnifiedAudit'; Lookback = '180 days'; Delay = 120; Overlap = 120; Start = { param($end) $end.AddDays(-180) } }
        @{ Collector = 'IntuneAudit'; Lookback = '2 years'; Delay = 60; Overlap = 60; Start = { param($end) $end.AddYears(-2) } }
        @{ Collector = 'AzureActivity'; Lookback = '90 days'; Delay = 15; Overlap = 15; Start = { param($end) $end.AddDays(-90) } }
    )

    foreach ($definition in $definitions) {
        $end = $now.AddMinutes(-[double]$definition.Delay)
        [pscustomobject]@{
            Collector = $definition.Collector
            NativeHistoryTarget = $definition.Lookback
            InitialStartUtc = (& $definition.Start $end)
            InitialEndUtc = $end
            IngestionDelayMinutes = $definition.Delay
            OverlapMinutes = $definition.Overlap
            IncrementalStateKey = "quick-$($definition.Collector)"
        }
    }
}

function New-M365QuickStartConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PlanItem,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$OutputRoot,
        [ValidateSet('Small', 'Medium', 'Large')][string]$ScaleProfile = 'Small'
    )

    $lookbackHours = [Math]::Max(1, ($PlanItem.InitialEndUtc - $PlanItem.InitialStartUtc).TotalHours)
    return @{
        TenantId = $TenantId
        OutputRoot = $OutputRoot
        ArchiveMode = 'Incremental'
        IncrementalInitialLookbackHours = $lookbackHours
        IncrementalInitialStartUtc = $PlanItem.InitialStartUtc.ToString('o')
        IncrementalOverlapMinutes = $PlanItem.OverlapMinutes
        IngestionDelayMinutes = $PlanItem.IngestionDelayMinutes
        IncrementalStateKey = $PlanItem.IncrementalStateKey
        WindowHours = 1
        ScaleProfile = $ScaleProfile
        ServicePolicyOverrides = @{}
        ResourceControls = @{
            MaximumTotalWorkers = 2
            MinimumFreeDiskGB = 10
            MaximumProcessMemoryMB = 2048
            MaximumDeduplicationKeysPerPartition = 500000
            MaximumQueueRecords = 25000
        }
        Collectors = @($PlanItem.Collector)
        RequiredCollectors = @($PlanItem.Collector)
        AzureSubscriptionIds = @()
        ExchangeUserPrincipalName = ''
        UnifiedAuditRecordTypes = @()
    }
}

Export-ModuleMember -Function @(
    'Get-M365TenantIdFromGraphContext',
    'Get-M365QuickStartPlan',
    'New-M365QuickStartConfig'
)
