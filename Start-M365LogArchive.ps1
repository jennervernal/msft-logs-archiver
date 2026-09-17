[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'M365LogsArchive'),
    [ValidateSet('Small', 'Medium', 'Large')][string]$ScaleProfile = 'Small',
    [switch]$ShowPlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Archive.QuickStart.psm1') -Force

$plan = @(Get-M365QuickStartPlan)
Write-Host 'Microsoft 365 zero-configuration archive plan'
Write-Host "Output root: $([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputRoot)))"
$plan | Select-Object Collector, NativeHistoryTarget, InitialStartUtc, InitialEndUtc |
    Format-Table -AutoSize | Out-Host
Write-Warning 'The first run can take many hours and require substantial disk space. Microsoft retention and licensing vary, so older records may be unavailable.'
Write-Host 'Authentication uses official Microsoft delegated sign-in. Enter credentials only in Microsoft browser/device sign-in; this script never reads or stores passwords.'

if ($ShowPlan) {
    Write-Host 'Plan only: no authentication or API collection was performed.'
    return
}

$requiredModules = @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement', 'Az.Accounts')
foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "Required module '$moduleName' is not installed. Run .\Install-ArchivePrerequisites.ps1."
    }
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Write-Host 'Sign in to Microsoft Graph to discover the tenant and authorize Entra and Intune audit collection.'
Connect-MgGraph -Scopes @('AuditLog.Read.All', 'DeviceManagementApps.Read.All') -ContextScope Process -NoWelcome | Out-Null
$tenantId = Get-M365TenantIdFromGraphContext -Context (Get-MgContext)
Write-Host "Authenticated tenant: $tenantId"
Write-Host 'Exchange Online and Azure may show separate Microsoft consent/sign-in prompts when their collectors begin.'

$resolvedOutputRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OutputRoot))
$overallExitCode = 0
try {
    foreach ($item in $plan) {
        Write-Host ""
        Write-Host "Starting $($item.Collector) ($($item.NativeHistoryTarget) first-run target; incremental thereafter)."
        $config = New-M365QuickStartConfig -PlanItem $item -TenantId $tenantId `
            -OutputRoot $resolvedOutputRoot -ScaleProfile $ScaleProfile
        $collectorExitCode = & (Join-Path $PSScriptRoot 'Archive-M365Logs.ps1') `
            -ConfigData $config -NoDisconnect -PassThruExitCode
        if ([int]$collectorExitCode -ne 0) {
            $overallExitCode = 1
            Write-Warning "$($item.Collector) did not complete successfully. Its incremental cursor was not advanced."
        }
    }
}
finally {
    if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (Get-Command Disconnect-AzAccount -ErrorAction SilentlyContinue) {
        Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null
    }
    if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
}

exit $overallExitCode
