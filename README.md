# Microsoft 365 local log archive suite

PowerShell 7 collectors for Microsoft Entra, Microsoft Purview unified audit, Intune, Azure Activity Log, and optionally Microsoft Defender XDR. Archives are written only to a local filesystem. Authentication is delegated and interactive; the suite does not accept, write, or persist credentials or access tokens.

The suite targets Microsoft 365 Education A3 audit preservation while keeping A5/add-on-only capabilities explicit. A3 commonly supports Entra P1, Audit Standard, and Intune sources, but tenant licensing and configuration control actual access. Complete risky-sign-in detail, Audit Premium features, and full Defender XDR coverage are not implied by A3.

## Prerequisites

Use PowerShell 7 or later on a supported Windows operator workstation with browser-based sign-in, sufficient local disk, the modules installed by `Install-ArchivePrerequisites.ps1`, and the delegated scopes/service roles for each selected collector. See [installation](docs/installation.md) and [authentication and permissions](docs/authentication-and-permissions.md) before a production run.

## Safety model

The suite fails explicitly on invalid configuration, required-source failures, corrupt successful partitions, resource thresholds, dense windows that cannot be split safely, and permanent API errors. Optional unavailable sources are recorded as skipped or failed rather than represented as empty success. Exclusive locking, bounded memory/queues/deduplication, atomic finalization, compressed-file SHA-256 manifests, and checkpoints protect local consistency. These controls do not encrypt data, sign evidence, provide distributed locking, or replace secure ACLs, backups, monitoring, and reviewed retention.

## Architecture and documentation

The entry script validates a hashtable configuration, establishes only the selected interactive service sessions, and coordinates service-specific collectors through a shared adaptive retry runtime. Records are written as bounded, partition-local UTF-8 JSONL, gzip-compressed, hashed, and committed with atomic renames before checkpoints advance. A deterministic run ID makes an identical rerun resumable and idempotent at the partition boundary.

- [Architecture](docs/architecture.md)
- [Installation](docs/installation.md)
- [Authentication and permissions](docs/authentication-and-permissions.md)
- [Configuration reference and scale examples](docs/configuration.md)
- [Operations runbook](docs/operations-runbook.md)
- [API limits and scaling](docs/api-limits-and-scaling.md)
- [Archive format](docs/archive-format.md)
- [Recovery and idempotency](docs/recovery-and-idempotency.md)
- [Security](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Collector reference](docs/collector-reference.md)
- [Verification and export](docs/verification-and-export.md)
- [M365 A3 retention reference](docs/retention-reference.md)
- [Contributing](CONTRIBUTING.md), [security policy](SECURITY.md), and [changelog](CHANGELOG.md)

## Quick start

1. Open PowerShell 7 and install prerequisites:

   ```powershell
   .\Install-ArchivePrerequisites.ps1
   ```

2. Copy `Config.example.psd1` to a protected local file such as `Config.psd1`. Set the tenant, mode/range, output root, collectors, and optional subscription IDs/workloads.
3. Run:

   ```powershell
   pwsh -NoProfile -File .\Archive-M365Logs.ps1 -ConfigPath .\Config.psd1
   ```

The process prompts in a browser for Microsoft Graph, Exchange Online, and Azure only when a selected collector needs that control plane. A required collector failure returns exit code 1. An unavailable optional collector is recorded as `skipped-unavailable` or `optional-failed` and does not produce false success data.

## Collectors, permissions, and roles

| Collector | Delegated permission / role | Licensing and notes |
|---|---|---|
| Entra directory audit | Graph `AuditLog.Read.All`; Reports Reader, Security Reader, Security Administrator, or suitable custom role | A3 generally includes Entra ID P1. Audit/sign-in API retention is normally 30 days with P1/P2. |
| Entra sign-ins | Graph `AuditLog.Read.All`; Global Reader, Reports Reader, Security Reader/Operator/Administrator | Sign-in download requires Entra ID P1/P2. Conditional Access policy details additionally require an appropriate role and policy permission; this suite does not request that broader permission. |
| Entra risky sign-ins | Same sign-in endpoint and `AuditLog.Read.All`; security/report role above | A3/P1 may return risk fields as `hidden`. Complete Identity Protection risk detail/reporting generally requires Entra ID P2 (Education A5 or qualifying add-on). This collector is optional by default. |
| Purview unified audit | Exchange Online `View-Only Audit Logs` or `Audit Logs` role; Purview Audit Reader/Manager as applicable | Education A3 normally has Audit Standard (180-day default retention), not A5 Audit Premium features. Covers Exchange, SharePoint, OneDrive, Teams, Entra, and other integrated workloads. |
| Intune audit | Graph `DeviceManagementApps.Read.All`; Intune Administrator or Intune RBAC `Audit data - Read` | Active Intune entitlement required. Graph exposes up to two years of Intune audit history. |
| Azure Activity Log | Azure RBAC Reader, Monitoring Reader, or custom `Microsoft.Insights/eventtypes/values/read`, per selected subscription | 90-day platform retention. Control-plane events only, not resource data-plane logs. |
| Defender XDR | Graph `ThreatHunting.Read.All` plus Defender XDR Unified RBAC/table access or qualifying security role | **M365 Education A3 alone is not a full Defender XDR entitlement.** A5, A3 + A5 Security, or separately licensed/onboarded Defender products are required. Available tables depend on the actual licenses and onboarding. |

Admin consent is normally required for the Graph delegated permissions. Assign only the listed reader roles needed by the selected collectors. References: [Graph directory audits](https://learn.microsoft.com/graph/api/directoryaudit-list), [Graph sign-ins](https://learn.microsoft.com/graph/api/signin-list), [Intune audit events](https://learn.microsoft.com/graph/api/intune-auditing-auditevent-list), [Search-UnifiedAuditLog](https://learn.microsoft.com/powershell/module/exchangepowershell/search-unifiedauditlog), [Azure Activity Log](https://learn.microsoft.com/azure/azure-monitor/platform/activity-log), and [Graph advanced hunting](https://learn.microsoft.com/graph/api/security-security-runhuntingquery).

## Configuration

`Collectors` accepts:

- `EntraAudit`
- `EntraSignIns`
- `EntraRiskySignIns`
- `UnifiedAudit`
- `IntuneAudit`
- `AzureActivity`
- `DefenderXdr`

`RequiredCollectors` determines exit behavior. Keep entitlement-dependent surfaces such as `EntraRiskySignIns` and `DefenderXdr` optional unless the tenant is known to license and authorize them.

`ArchiveMode = 'Fixed'` uses `StartUtc` and `EndUtc`. `ArchiveMode = 'Incremental'` calculates a delayed end time, uses `IncrementalInitialLookbackHours` for the first run, then advances from `_state\incremental-<tenant>.json` with `IncrementalOverlapMinutes`. State advances only after every required collector succeeds. The overlap protects against late arrivals; source record IDs support downstream reconciliation.

`WindowHours` is the upper ceiling for each adaptive API query/archive partition. One hour is conservative. Unified audit bisects a query if `Search-UnifiedAuditLog` reaches either the configured buffer or its 50,000-record session cap and fails explicitly if density remains too high at the minimum interval. Defender uses a limit-plus-one query and bisects before accepting a potentially truncated response. Results use half-open `[start,end)` windows; the Exchange query subtracts one .NET tick from its inclusive end to avoid boundary duplication without a representable gap.

`AzureSubscriptionIds = @()` selects every enabled subscription visible to the signed-in user. Otherwise list exact subscription GUIDs. `UnifiedAuditRecordTypes` uses `Search-UnifiedAuditLog -RecordType` enum values; empty collects all available workloads. This is preferable when the goal is complete Exchange, SharePoint, OneDrive, Teams, and cross-workload coverage.

## Scaling and Microsoft service limits

Start with `ScaleProfile = 'Small'` for every tenant. `ScaleProfiles.psd1` also provides `Medium` and `Large` ceilings, but these are operational presets—not statements of Microsoft capacity. Graph, ARM, Purview, and Defender limits are dynamic, tenant/workload-specific, and can change. Move profiles or add `ServicePolicyOverrides` only after reviewing several successful runs.

Each service has independent controls for maximum attempts, base/maximum delay, minimum request spacing, maximum concurrency, circuit-breaker threshold/cooldown, initial/minimum/maximum window, page/minimum page size, and sustained-success recovery count. `WindowHours` remains a global upper bound. Graph pages are sequential within each stream and `@odata.nextLink` is followed verbatim; batching is not used and would not bypass throttling. Purview remains single-stream because `SessionId` paging must remain stable. ARM traverses each subscription and continuation token safely with a bounded ceiling. Defender tables are independent streams.

The shared runtime:

- honors `Retry-After` delta-seconds and HTTP-date values and `x-ms-retry-after-ms`;
- reacts to low ARM/Graph remaining-quota headers when exposed by the module;
- retries only 429, 408, selected 5xx, network/timeouts, and narrowly recognized Purview busy/throttle failures;
- uses capped exponential backoff with full jitter to prevent synchronized retries;
- halves effective concurrency, page size, and windows under throttling/transient pressure, then recovers one step only after sustained success;
- opens a service-local circuit after repeated transient failures instead of hammering an unhealthy API. `MaxDelaySeconds` caps generated jitter backoff; an explicit longer service `Retry-After` remains authoritative.

Exchange Online cmdlets do not expose raw HTTP headers consistently, so UAL uses minimum spacing plus conservative classification of explicit throttling, server-busy, temporary-unavailable, and timeout errors. Authentication, authorization, invalid KQL/filter, and other permanent errors are not retried indiscriminately.

`_state\throttle-state.json` persists only effective concurrency/window/page size and circuit state. It contains no token or credential. Run manifests expose per-service requests, pages, attempts, 429/transient/permanent counts, cumulative throttle/spacing wait, circuit events, window/concurrency/page changes, low-quota signals, effective settings, and measured request throughput. Collector status distinguishes `success`, `partial`, `failed`, `optional-partial`, `optional-failed`, and `skipped-unavailable`.

`ResourceControls` caps total workers, enforces free-disk and process-memory thresholds before collection and periodically during streaming writes, and bounds queues. Graph and ARM records stream directly into temporary JSONL files. UAL and Defender buffers are bounded by `MaximumQueueRecords`; dense windows are bisected without gaps until they fit or reach the configured minimum, at which point collection fails explicitly. Deduplication keys are capped per partition to prevent unbounded memory growth. Atomic rename, the output lock, and per-partition checkpoints remain the only commit boundary.

**Metric interpretation:** throttles/transients above zero, rising wait time, circuit events, or repeated window/page reductions indicate the profile is too aggressive or the service is under pressure. Keep concurrency low, shorten windows first, and avoid launching multiple interactive runs for the same tenant. Low throughput without throttle signals can reflect source latency or sparse data rather than insufficient concurrency.

## Archive and recovery behavior

Layout:

```text
<OutputRoot>\
  _runs\<run-id>\checkpoint.json
  _runs\<run-id>\run.log.jsonl
  _runs\<run-id>\run.manifest.json
  <Source>\yyyy\MM\dd\<run-id>\<start>_<end>.jsonl.gz
  <Source>\yyyy\MM\dd\<run-id>\<start>_<end>.manifest.json
```

Each gzip file contains UTF-8 JSON Lines preserving the object returned by the source API. Defender tables and Azure subscriptions use distinct source partitions so no tagging mutation is required. The adjacent manifest records source, query interval, collection time, count, schema/format, completion state, continuation state, error, and SHA-256. The run manifest records collector status, counts, errors, a partition hash inventory, and a deterministic configuration fingerprint. The checkpoint stores each completed partition and its hash.

The run ID is deterministic for tenant, date range, collector list, scale/resource policy, and window ceiling. Re-running the same configuration resumes completed partitions and never overwrites an existing valid partition. The checkpoint records each collector cursor and any active adaptive window before API work begins, so a restart reuses exactly the same in-flight boundary even if persisted throttle state changed. A present but invalid manifest is a hard failure. Files and checkpoints are written to unique temporary files and atomically renamed. A filesystem lock prevents overlapping runs against one output root.

## Verify and inspect

Validate one manifest or every partition under a root:

```powershell
.\Test-Archive.ps1 -Path D:\M365LogArchive
```

Inspect decompressed objects:

```powershell
.\Export-ArchiveRecords.ps1 -ArchivePath 'D:\M365LogArchive\EntraAudit\2026\09\15\<run-id>\*.jsonl.gz' |
    Select-Object -First 20
```

Export JSON Lines without changing record fidelity:

```powershell
$files = Get-ChildItem D:\M365LogArchive\UnifiedAudit -Filter *.jsonl.gz -Recurse
.\Export-ArchiveRecords.ps1 -ArchivePath $files.FullName -OutputPath D:\Exports\unified-audit.jsonl
```

## Incremental operation, scheduling, and retention

Allow for ingestion delay: Purview unified audit commonly lags 60-90 minutes. For a daily collection, use a trailing overlap in the requested date range and retain prior archives; source IDs and bounded partitioning make reconciliation possible. Do not request data beyond each source's retention period.

Windows Task Scheduler can start the script, but **interactive delegated authentication cannot make a truly unattended task**. Run only when the designated operator is logged on, select “Run only when user is logged on,” invoke `pwsh.exe -NoProfile -File ...`, and expect browser prompts when sessions expire. A scheduled launch without a user available must fail rather than bypass authentication.

Truly unattended collection requires a separately designed certificate-based app-only identity, tenant admin consent, protected certificate lifecycle, and workload-specific application permissions. That is intentionally not implemented because this suite is delegated-interactive only.

Interactive delegated sessions also limit safe horizontal scaling: module contexts and user sign-in lifetimes are process/user scoped. Do not fan this suite out across hosts as a pseudo-unattended collector. Unattended horizontal workers require certificate-based app-only authentication, durable work coordination, per-tenant/service quotas, and a central archive/checkpoint architecture.

Apply filesystem ACLs so only archive operators and approved security/audit readers can access the root. Use volume encryption, back up manifests with archives, test restores, and define a retention policy that meets institutional/legal requirements. Avoid deleting local data merely because the cloud source aged out; use reviewed lifecycle jobs and preserve hold-required records.

## Tests

Pure helpers are covered with Pester:

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

The tests cover window/cap splitting, checkpoint/resume persistence, deduplication, compressed archive hashes and manifest validation, tamper detection, configuration/policy bounds, Retry-After seconds/HTTP-date parsing, full-jitter bounds, permanent versus retryable failures, adaptive decrease/recovery, circuit-breaker cooldown, and deterministic mocked retries.
