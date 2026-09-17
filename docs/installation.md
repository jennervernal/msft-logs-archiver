# Installation

## Supported environment

- Windows with PowerShell 7 or later (`pwsh`), a browser-capable interactive operator session, and TLS access to Microsoft sign-in and service endpoints.
- A local or mounted filesystem that supports exclusive file handles and same-volume rename.
- Enough free disk for the requested source range plus temporary uncompressed JSONL. The default preflight requires 10 GB.

The implementation is designed and tested as a local interactive PowerShell workflow. Windows PowerShell 5.1 is not supported. Non-Windows PowerShell may run the pure code, but production collection and the documented operational/security guidance target Windows and have not been qualified on other platforms.

## Install modules

From PowerShell 7:

```powershell
Set-Location C:\Tools\msft-logs-archiver
.\Install-ArchivePrerequisites.ps1
```

The installer requests these minimum versions from PowerShell Gallery:

| Module | Minimum | Used for |
|---|---:|---|
| `Microsoft.Graph.Authentication` | 2.0.0 | Graph delegated sign-in and raw Graph requests |
| `ExchangeOnlineManagement` | 3.0.0 | `Search-UnifiedAuditLog` |
| `Az.Accounts` | 3.0.0 | Azure sign-in, subscription discovery, and ARM requests |
| `Pester` | 5.5.0 | Tests |

Use `-Scope AllUsers` only from an elevated shell when centrally managed installation is intended. The default is `CurrentUser`.

```powershell
.\Install-ArchivePrerequisites.ps1 -Scope CurrentUser -WhatIf
Get-Module Microsoft.Graph.Authentication,ExchangeOnlineManagement,Az.Accounts,Pester -ListAvailable |
    Sort-Object Name,Version -Descending
```

## Tenant prerequisites

Before collection, confirm:

1. Microsoft 365 Education A3 (or equivalent qualifying service licenses) is active for the sources being collected.
2. Unified auditing is available and the operator has the required Purview/Exchange audit role.
3. Intune is licensed and configured if `IntuneAudit` is selected.
4. Azure subscriptions are visible to the operator if `AzureActivity` is selected.
5. Defender products are separately licensed/onboarded if `DefenderXdr` is selected; A3 alone is not sufficient for the complete Defender XDR surface.
6. Tenant administrators have approved the delegated scopes and assigned least-privileged reader roles described in [authentication and permissions](authentication-and-permissions.md).
After module installation, the normal path requires no tenant ID or configuration file:

```powershell
pwsh -NoProfile -File .\Start-M365LogArchive.ps1
```

The operator signs in through Microsoft; the launcher discovers the tenant and writes to `%USERPROFILE%\M365LogsArchive`. Use `-ShowPlan` for an offline preview. Only advanced/custom collection requires copying `Config.example.psd1` to ignored `Config.psd1`; see [configuration](configuration.md) and [operations runbook](operations-runbook.md).
