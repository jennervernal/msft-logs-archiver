# Troubleshooting

| Symptom | Checks and action |
|---|---|
| Browser/authentication loop | Confirm PowerShell 7, system time, browser access, correct `TenantId`, conditional-access compliance, and that stale module sessions are disconnected. Reopen a clean `pwsh` process. |
| Quick start cannot discover tenant | Complete Graph sign-in, then confirm `Get-MgContext` returns a nonempty valid `TenantId`. The launcher does not accept a manually typed tenant ID. |
| Consent required / 403 | Compare selected collector with exact delegated scope and role in [authentication and permissions](authentication-and-permissions.md). Admin consent and user role are separate requirements. |
| Source skipped unavailable | No visible enabled Azure subscription and an unavailable Intune endpoint are skipped without inventing data. Permission/consent failures remain failures. Defender XDR and complete risky-sign-in details are not quick-mode defaults or guaranteed by A3. |
| 429 or rising waits | Honor service recovery; do not restart in parallel. Use `Small`, shorten `WindowHours`, lower overrides, and inspect throttle/low-quota metrics. |
| 5xx/timeouts/circuit open | Wait through cooldown, check Microsoft service health/network, and rerun identical configuration. Persistent permanent errors are intentionally not retried. |
| UAL cap reached | Shorten windows. The collector bisects at its configured buffer/50,000 session boundary and fails at minimum window rather than accept truncation. |
| Missing UAL records | Account for ingestion delay, verify audit roles and record-type values, use overlap, and compare source retention. Empty `UnifiedAuditRecordTypes` requests all available types. |
| Pagination concern | Graph follows `@odata.nextLink`; ARM follows `nextLink`; UAL uses stable session paging. Preserve diagnostics and inspect page/request metrics. |
| Memory or queue bound | Shorten windows, select fewer Defender tables/UAL record types, or cautiously raise host-aligned bounds. Avoid unbounded changes. |
| Low disk | Include temporary uncompressed JSONL in capacity planning. Expand storage or apply approved retention; do not delete active-run files. |
| SHA-256 mismatch | Quarantine pair, compare/restore trusted backup, and verify after copy. Do not edit expected hash to match corrupt bytes. |
| Stale lock | Confirm no process or remote client owns it, then remove only `<OutputRoot>\.archive.lock`. |
| Invalid checkpoint/state | Preserve the invalid JSON, identify cause, restore from backup or approve a controlled backfill. Do not silently reset boundaries. |
| Module/cmdlet behavior differs | Run `Get-Module ... -ListAvailable`, update to supported versions with the installer, and record exact selected versions. Test before production. |

## Diagnostic collection

Collect the exact command with secrets/real IDs removed, PowerShell version, module names/versions, configuration with tenant/subscription IDs and paths replaced by fabricated values, exit code, affected run ID, relevant collector status/error, API metrics, and the minimal redacted portion of `run.log.jsonl`. Include `Test-Archive.ps1` results and free disk/memory observations.

Never attach raw archive records, tokens, authorization headers, unredacted UPNs/IPs, or real tenant/subscription identifiers to public issues. Reproduce pure logic failures with fabricated records and use:

```powershell
$PSVersionTable.PSVersion
Get-Module Microsoft.Graph.Authentication,ExchangeOnlineManagement,Az.Accounts,Pester -ListAvailable |
    Select-Object Name,Version,Path
Invoke-Pester -Path .\tests -Output Detailed
```
