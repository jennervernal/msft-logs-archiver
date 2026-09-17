[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'M365Archive.Core.psm1') -Force

$resolved = (Resolve-Path -LiteralPath $Path).Path
$manifests = if ((Get-Item -LiteralPath $resolved).PSIsContainer) {
    @(Get-ChildItem -LiteralPath $resolved -Filter '*.manifest.json' -File -Recurse |
        Where-Object Name -ne 'run.manifest.json')
}
else { @((Get-Item -LiteralPath $resolved)) }

if ($manifests.Count -eq 0) { throw "No partition manifests found under '$resolved'." }
$results = @($manifests | ForEach-Object { Test-ArchiveManifest -ManifestPath $_.FullName })
$results | Format-Table Valid, RecordCount, ManifestPath, Error -AutoSize
if ($results.Valid -contains $false) { exit 1 }
exit 0
