# M365 Education A3 retention reference

> **Verify current Microsoft documentation before every production backfill or retention decision.** Licensing, service terms, defaults, and API availability change. The values below are concise planning references, not contractual guarantees.

| Source | Typical native availability relevant to A3 | Important limitation | Microsoft reference |
|---|---:|---|---|
| Microsoft Entra audit and sign-in logs | 30 days with Entra ID P1 | Risk detail may require P2; export before expiration | [Entra data retention](https://learn.microsoft.com/entra/identity/monitoring-health/reference-reports-data-retention) |
| Purview Unified Audit Log, including Exchange, SharePoint, OneDrive, Teams, and integrated workloads | 180 days for Audit Standard | A3 does not imply Audit Premium policies/features; workload ingestion varies | [Audit solutions retention](https://learn.microsoft.com/purview/audit-solutions-overview) |
| Intune audit logs | 1 year in Intune portal; up to 2 years through Graph | Requires active Intune entitlement and audit permissions | [Intune audit logs](https://learn.microsoft.com/intune/intune-service/fundamentals/monitor-audit-logs) |
| Azure Activity Log | 90 days | Subscription control plane only; longer Azure retention requires separate export/diagnostic settings | [Azure Activity Log](https://learn.microsoft.com/azure/azure-monitor/platform/activity-log) |
| Defender XDR advanced hunting | Entitlement/product dependent | Education A3 alone is not a complete Defender XDR entitlement; A5, A5 Security add-on, or qualifying Defender products/onboarding may be required | [Advanced hunting data schema](https://learn.microsoft.com/defender-xdr/advanced-hunting-schema-tables) |
Local archive retention is independent of these source windows and must be approved under institutional records, privacy, legal-hold, incident-response, and storage policies.
Local archive retention is independent of these source windows and must be approved under institutional records, privacy, legal-hold, incident-response, and storage policies.
