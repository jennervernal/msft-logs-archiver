# Authentication and permissions

This build supports **interactive delegated authentication only**. It opens Microsoft sign-in as required by selected collectors and scopes module contexts to the current process. It does not accept credentials, save tokens, or implement a token cache of its own. Microsoft modules and operating-system sign-in components may maintain their own caches; manage those according to organizational policy.

Truly unattended operation requires a future, separately reviewed certificate-based app-only design, workload-specific application permissions, certificate lifecycle protection, and durable centralized coordination. It is not supported by this interactive build.

## Exact access by collector

| Collector | Delegated API scope | Microsoft role / data-plane authorization |
|---|---|---|
| `EntraAudit` | Graph `AuditLog.Read.All` | Reports Reader, Security Reader, Security Administrator, or an appropriate custom directory role |
| `EntraSignIns` | Graph `AuditLog.Read.All` | Global Reader, Reports Reader, Security Reader, Security Operator, or Security Administrator |
| `EntraRiskySignIns` | Graph `AuditLog.Read.All` | Same sign-in roles; full risk details generally require Entra ID P2 |
| `UnifiedAudit` | Exchange Online delegated session; no Graph scope | `View-Only Audit Logs` or `Audit Logs`; Purview Audit Reader/Audit Manager as applicable |
| `IntuneAudit` | Graph `DeviceManagementApps.Read.All` | Intune Administrator or Intune RBAC permission `Audit data - Read` |
| `AzureActivity` | Azure delegated session; no Graph scope | Reader, Monitoring Reader, or custom `Microsoft.Insights/eventtypes/values/read` on each subscription |
| `DefenderXdr` | Graph `ThreatHunting.Read.All` | Defender XDR Unified RBAC/table access or a qualifying security role |

Graph permissions commonly require administrator consent. Consent grants the client permission to act within the signed-in user's effective access; it does not replace directory, Intune, Azure, Purview, or Defender role assignments. Use a dedicated named operator identity, assign only the collectors it operates, review sign-in controls, and remove access when duties change.

## A3 versus optional A5/add-on capabilities

Education A3 commonly supplies Entra ID P1, Audit Standard, and Intune entitlements, subject to the tenant's purchased plan and configuration. It does not imply Entra ID P2 risk visibility, Audit Premium capabilities, or full Defender XDR entitlement. Complete risky-sign-in fields and Defender datasets may require Education A5, A3 plus A5 Security, or separately licensed products. Keep `EntraRiskySignIns` and `DefenderXdr` optional unless entitlement and authorization have been verified.

`Connect-MgGraph` uses `-ContextScope Process`; Azure context autosave is disabled for the process; Exchange is disconnected in `finally`. No script code writes tokens into configuration, logs, manifests, checkpoints, or archives. Never place passwords, client secrets, refresh tokens, certificates, or copied bearer tokens in `Config.psd1`.
Official references: [Graph audit permissions](https://learn.microsoft.com/graph/api/directoryaudit-list), [Graph sign-ins permissions](https://learn.microsoft.com/graph/api/signin-list), [Intune audit events](https://learn.microsoft.com/graph/api/intune-auditing-auditevent-list), [Search-UnifiedAuditLog](https://learn.microsoft.com/powershell/module/exchangepowershell/search-unifiedauditlog), [Azure Activity Log access](https://learn.microsoft.com/azure/azure-monitor/platform/activity-log), and [Defender advanced hunting API](https://learn.microsoft.com/graph/api/security-security-runhuntingquery).
Official references: [Graph audit permissions](https://learn.microsoft.com/graph/api/directoryaudit-list), [Graph sign-ins permissions](https://learn.microsoft.com/graph/api/signin-list), [Intune audit events](https://learn.microsoft.com/graph/api/intune-auditing-auditevent-list), [Search-UnifiedAuditLog](https://learn.microsoft.com/powershell/module/exchangepowershell/search-unifiedauditlog), [Azure Activity Log access](https://learn.microsoft.com/azure/azure-monitor/platform/activity-log), and [Defender advanced hunting API](https://learn.microsoft.com/graph/api/security-security-runhuntingquery).
