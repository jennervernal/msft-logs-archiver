Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Archive.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'M365Archive.RateLimit.psm1')

function Connect-ArchiveGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string[]]$Scopes)

    $context = Get-MgContext -ErrorAction SilentlyContinue
    $missing = @($Scopes | Where-Object { -not $context -or $_ -notin @($context.Scopes) })
    if (-not $context -or $context.TenantId -ne $TenantId -or $missing.Count -gt 0) {
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ContextScope Process -NoWelcome | Out-Null
    }
}

function Invoke-GraphPagedRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)

    $next = $Uri
    while ($next) {
        $page = Invoke-ServiceOperation -Service Graph -OperationName "Microsoft Graph page" -IsPage -Operation {
            Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        }
        foreach ($item in @($page.value)) { $item }
        $next = Get-RecordValue $page '@odata.nextLink'
    }
}

function Get-EntraAuditRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][DateTime]$StartUtc, [Parameter(Mandatory)][DateTime]$EndUtc)
    Connect-ArchiveGraph -TenantId $TenantId -Scopes @('AuditLog.Read.All')
    $filter = [Uri]::EscapeDataString("activityDateTime ge $($StartUtc.ToString('o')) and activityDateTime lt $($EndUtc.ToString('o'))")
    $pageSize = (Get-ServiceRuntime Graph).CurrentPageSize
    Invoke-GraphPagedRequest "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?`$filter=$filter&`$top=$pageSize"
}

function Get-EntraSignInRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [switch]$RiskyOnly
    )
    Connect-ArchiveGraph -TenantId $TenantId -Scopes @('AuditLog.Read.All')
    $expression = "createdDateTime ge $($StartUtc.ToString('o')) and createdDateTime lt $($EndUtc.ToString('o'))"
    $filter = [Uri]::EscapeDataString($expression)
    $pageSize = [Math]::Min(1000, (Get-ServiceRuntime Graph).CurrentPageSize)
    foreach ($record in Invoke-GraphPagedRequest "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=$filter&`$top=$pageSize") {
        if (-not $RiskyOnly) {
            $record
            continue
        }
        $riskDuring = Get-RecordValue $record 'riskLevelDuringSignIn'
        $riskAggregated = Get-RecordValue $record 'riskLevelAggregated'
        $riskDetail = Get-RecordValue $record 'riskDetail'
        $riskState = Get-RecordValue $record 'riskState'
        if (@($riskDuring, $riskAggregated, $riskDetail) -contains 'hidden') {
            throw 'Risk fields are hidden for this tenant/user; complete risky sign-in evidence requires Entra ID P2 and an authorized role.'
        }
        if (
            $riskState -eq 'atRisk' -or
            $riskDuring -in @('low', 'medium', 'high') -or
            $riskAggregated -in @('low', 'medium', 'high')
        ) {
            $record
        }
    }
}

function Get-IntuneAuditRecords {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][DateTime]$StartUtc, [Parameter(Mandatory)][DateTime]$EndUtc)
    Connect-ArchiveGraph -TenantId $TenantId -Scopes @('DeviceManagementApps.Read.All')
    $retentionStartUtc = [DateTime]::UtcNow.AddYears(-2).AddMinutes(1)
    if ($EndUtc -le $retentionStartUtc) { return }
    if ($StartUtc -lt $retentionStartUtc) { $StartUtc = $retentionStartUtc }
    $inclusiveEndUtc = $EndUtc.AddTicks(-1)
    $filter = [Uri]::EscapeDataString("activityDateTime ge $($StartUtc.ToString('o')) and activityDateTime le $($inclusiveEndUtc.ToString('o'))")
    $pageSize = [Math]::Min(100, (Get-ServiceRuntime Graph).CurrentPageSize)
    Invoke-GraphPagedRequest "https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?`$filter=$filter&`$top=$pageSize"
}

function Test-IntuneAuditCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)

    Connect-ArchiveGraph -TenantId $TenantId -Scopes @('DeviceManagementApps.Read.All')
    try {
        Invoke-ServiceOperation -Service Graph -OperationName 'Intune audit capability check' -Operation {
            Invoke-MgGraphRequest -Method GET `
                -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/auditEvents?$top=1' `
                -OutputType PSObject
        } | Out-Null
        return [pscustomobject]@{ Available = $true; Reason = $null }
    }
    catch {
        $exception = $_.Exception
        $responseProperty = $exception.PSObject.Properties['Response']
        $response = if ($responseProperty) { $responseProperty.Value } else { $null }
        $statusCode = if ($response -and $response.StatusCode) {
            [int]$response.StatusCode
        }
        elseif ($exception.PSObject.Properties['StatusCode']) {
            [int]$exception.StatusCode
        }
        else { 0 }
        if ($statusCode -eq 404) {
            return [pscustomobject]@{
                Available = $false
                Reason = 'The Intune audit endpoint is unavailable for this tenant.'
            }
        }
        throw
    }
}

function Get-UnifiedAuditRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [string[]]$Workloads = @(),
        [TimeSpan]$MinimumWindow = ([TimeSpan]::FromMinutes(5)),
        [int]$MaximumBufferedRecords = 50000
    )

    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ StartUtc = $StartUtc; EndUtc = $EndUtc })
    while ($queue.Count -gt 0) {
        $window = $queue.Dequeue()
        $sessionInput = "$($window.StartUtc.ToString('o'))|$($window.EndUtc.ToString('o'))|$($Workloads -join ',')"
        $sessionId = "m365archive-$((Get-StableHash $sessionInput).Substring(0, 20))"
        $records = [Collections.Generic.List[object]]::new()
        do {
            $params = @{
                StartDate      = $window.StartUtc
                EndDate        = $window.EndUtc.AddTicks(-1)
                SessionId      = $sessionId
                SessionCommand = 'ReturnLargeSet'
                ResultSize     = [Math]::Min($MaximumBufferedRecords, [Math]::Min(5000, (Get-ServiceRuntime Purview).CurrentPageSize))
                ErrorAction    = 'Stop'
            }
            if ($Workloads.Count -gt 0) { $params.RecordType = $Workloads }
            $batch = @(Invoke-ServiceOperation -Service Purview -OperationName 'Search-UnifiedAuditLog page' -IsPage -Operation {
                Search-UnifiedAuditLog @params
            })
            foreach ($item in $batch) {
                if ($item.AuditData) {
                    try { $records.Add(($item.AuditData | ConvertFrom-Json)) }
                    catch { throw "Unified Audit Log returned invalid AuditData JSON for identity '$($item.Identity)'." }
                }
                else { $records.Add($item) }
            }
        } while ($batch.Count -gt 0 -and $records.Count -lt [Math]::Min(50000, $MaximumBufferedRecords))

        if ($records.Count -ge [Math]::Min(50000, $MaximumBufferedRecords)) {
            try {
                $halves = @(Split-TimeWindow -StartUtc $window.StartUtc -EndUtc $window.EndUtc -MinimumWindow $MinimumWindow)
            }
            catch {
                throw "Unified Audit Log result cap reached for $($window.StartUtc.ToString('o')) through $($window.EndUtc.ToString('o')); reduce MinimumWindow."
            }
            Write-ArchiveLog -Level WARN -Message 'Unified Audit Log cap reached; splitting query window.' -Data @{
                startUtc = $window.StartUtc.ToString('o'); endUtc = $window.EndUtc.ToString('o')
            }
            Update-AdaptiveState -Service Purview -Outcome Dense
            $queue.Enqueue($halves[0])
            $queue.Enqueue($halves[1])
        }
        else {
            foreach ($record in $records) { $record }
        }
    }
}

function Connect-ArchiveExchange {
    [CmdletBinding()]
    param([string]$UserPrincipalName)
    $params = @{ ShowBanner = $false; DisableWAM = $true }
    if ($UserPrincipalName) { $params.UserPrincipalName = $UserPrincipalName }
    Connect-ExchangeOnline @params
}

function Connect-ArchiveAzure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Tenant $TenantId -Scope Process | Out-Null
}

function Get-AzureActivityRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc
    )
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $inclusiveEndUtc = $EndUtc.AddTicks(-1)
    $filter = [Uri]::EscapeDataString("eventTimestamp ge '$($StartUtc.ToString('o'))' and eventTimestamp le '$($inclusiveEndUtc.ToString('o'))'")
    $uri = "/subscriptions/$SubscriptionId/providers/microsoft.insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$filter"
    while ($uri) {
        $response = Invoke-ServiceOperation -Service Azure -OperationName "Azure Activity Log page for $SubscriptionId" -IsPage -Operation {
            if ([Uri]::IsWellFormedUriString($uri, [UriKind]::Absolute)) {
                Invoke-AzRestMethod -Method GET -Uri $uri
            }
            else {
                Invoke-AzRestMethod -Method GET -Path $uri
            }
        }
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "Azure Activity Log request failed with HTTP $($response.StatusCode): $($response.Content)"
        }
        $page = $response.Content | ConvertFrom-Json
        foreach ($record in @($page.value)) { $record }
        $uri = Get-RecordValue $page 'nextLink'
    }
}

function Test-DefenderXdrCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)
    try {
        Connect-ArchiveGraph -TenantId $TenantId -Scopes @('ThreatHunting.Read.All')
        $body = @{
            Query = 'union isfuzzy=true * | take 1'
            Timespan = "$([DateTime]::UtcNow.AddMinutes(-5).ToString('o'))/$([DateTime]::UtcNow.ToString('o'))"
        } | ConvertTo-Json -Compress
        Invoke-ServiceOperation -Service Defender -OperationName 'Defender XDR capability check' -Operation {
            Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' `
                -ContentType 'application/json; charset=utf-8' -Body $body -OutputType PSObject
        } | Out-Null
        return [pscustomobject]@{ Available = $true; Reason = $null }
    }
    catch {
        return [pscustomobject]@{ Available = $false; Reason = $_.Exception.Message }
    }
}

function Get-DefenderXdrHuntingRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTime]$StartUtc,
        [Parameter(Mandatory)][DateTime]$EndUtc,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Table,
        [int]$MaximumBufferedRecords = 25000,
        [TimeSpan]$MinimumWindow = ([TimeSpan]::FromMinutes(1))
    )
    Connect-ArchiveGraph -TenantId $TenantId -Scopes @('ThreatHunting.Read.All')
    if ($Table -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "Invalid Defender table name '$Table'." }
    $queryLimit = [Math]::Min(99999, $MaximumBufferedRecords + 1)
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ StartUtc = $StartUtc; EndUtc = $EndUtc })
    while ($queue.Count -gt 0) {
        $window = $queue.Dequeue()
        $body = @{
            Query = "$Table | where Timestamp >= datetime($($window.StartUtc.ToString('o'))) and Timestamp < datetime($($window.EndUtc.ToString('o'))) | take $queryLimit"
            Timespan = "$($window.StartUtc.ToString('o'))/$($window.EndUtc.ToString('o'))"
        } | ConvertTo-Json -Compress
        $result = Invoke-ServiceOperation -Service Defender -OperationName "Defender XDR advanced hunting table $Table" -Operation {
            Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' `
                -ContentType 'application/json; charset=utf-8' -Body $body -OutputType PSObject
        }
        $rows = @($result.results)
        if ($rows.Count -gt $MaximumBufferedRecords) {
            Update-AdaptiveState -Service Defender -Outcome Dense
            try {
                $halves = @(Split-TimeWindow -StartUtc $window.StartUtc -EndUtc $window.EndUtc -MinimumWindow $MinimumWindow)
            }
            catch {
                throw "Defender XDR query for '$Table' exceeded the configured buffer at the minimum window; lower event density or raise MaximumQueueRecords safely."
            }
            $queue.Enqueue($halves[0])
            $queue.Enqueue($halves[1])
        }
        else { $rows }
    }
}

Export-ModuleMember -Function @(
    'Connect-ArchiveGraph', 'Invoke-GraphPagedRequest', 'Get-EntraAuditRecords',
    'Get-EntraSignInRecords', 'Get-IntuneAuditRecords', 'Test-IntuneAuditCapability', 'Connect-ArchiveExchange',
    'Get-UnifiedAuditRecords', 'Connect-ArchiveAzure', 'Get-AzureActivityRecords',
    'Test-DefenderXdrCapability', 'Get-DefenderXdrHuntingRecords'
)
