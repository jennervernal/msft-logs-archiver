[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or newer is required.'
}

$modules = @(
    @{ Name = 'Microsoft.Graph.Authentication'; MinimumVersion = '2.0.0' }
    @{ Name = 'ExchangeOnlineManagement'; MinimumVersion = '3.0.0' }
    @{ Name = 'Az.Accounts'; MinimumVersion = '3.0.0' }
    @{ Name = 'Pester'; MinimumVersion = '5.5.0' }
)

foreach ($module in $modules) {
    if ($PSCmdlet.ShouldProcess("$($module.Name) >= $($module.MinimumVersion)", 'Install/update PowerShell module')) {
        Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Scope $Scope -Repository PSGallery -Force -AllowClobber
    }
}

Write-Host 'Prerequisites installed. No tenant credentials or tokens were stored by this script.'
