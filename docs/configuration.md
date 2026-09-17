# Configuration

## Zero-configuration mode

No configuration file is needed for the default workflow:

```powershell
.\Start-M365LogArchive.ps1
```

It discovers the authenticated tenant, uses `%USERPROFILE%\M365LogsArchive`, selects `Small`, enables `EntraAudit`, `EntraSignIns`, `UnifiedAudit`, `IntuneAudit`, and `AzureActivity`, and discovers every visible enabled Azure subscription. Optional overrides are:

| Launcher parameter | Default | Meaning |
|---|---|---|
| `-OutputRoot` | `%USERPROFILE%\M365LogsArchive` | Protected local archive root |
| `-ScaleProfile` | `Small` | `Small`, `Medium`, or `Large`; increase only from measured results |
| `-ShowPlan` | off | Display ranges and perform no authentication or API collection |

The launcher composes in-memory, one-collector incremental configurations. It writes no user-edited or temporary configuration. Separate `IncrementalStateKey` values prevent the 30-day, 90-day, 180-day, and two-year cursors from corrupting one another.

## Advanced configuration

Copy `Config.example.psd1` to ignored `Config.psd1`. It must return a hashtable.

## Properties

| Property | Required | Example/default | Meaning |
|---|---|---|---|
| `TenantId` | Yes | fabricated GUID | Microsoft Entra tenant GUID |
| `OutputRoot` | Yes | `D:\M365LogArchive` | Local archive root; environment variables are expanded |
| `ArchiveMode` | Yes | `Fixed` | `Fixed` or `Incremental` |
| `StartUtc`, `EndUtc` | Fixed only | ISO 8601 UTC | Fixed half-open range; start must precede end and end cannot be future |
| `IncrementalInitialLookbackHours` | Incremental only | `24` | First-run lookback; must be positive |
| `IncrementalInitialStartUtc` | No | absent | Exact first-run UTC start used by quick mode; overrides the hour lookback when state is absent |
| `IncrementalOverlapMinutes` | Incremental only | `15` | Overlap before last successful end |
| `IngestionDelayMinutes` | Incremental only | `120` | Lag subtracted from current UTC time |
| `IncrementalStateKey` | No | absent | Safe suffix isolating an incremental stream; letters, numbers, dot, underscore, hyphen |
| `WindowHours` | Yes | `1` | Global partition/window ceiling; greater than 0, at most 168 |
| `ScaleProfile` | Yes | `Small` | `Small`, `Medium`, or `Large` ceilings from `ScaleProfiles.psd1` |
| `ServicePolicyOverrides` | No | `@{}` | Per-service override of existing policy keys only |
| `ResourceControls` | Yes | see below | Worker, disk, memory, dedupe, and queue safety bounds |
| `Collectors` | Yes | source names | At least one enabled collector |
| `RequiredCollectors` | Yes | core sources | Selected collectors whose failure makes exit code nonzero |
| `AzureSubscriptionIds` | With Azure | `@()` | Exact GUIDs; empty discovers all visible enabled subscriptions |
| `ExchangeUserPrincipalName` | No | `''` | Interactive Exchange sign-in hint |
| `UnifiedAuditRecordTypes` | With UAL | `@()` | `Search-UnifiedAuditLog -RecordType` values; empty requests all |
| `DefenderXdrTables` | With Defender | five examples | At least one safe table identifier |

`ResourceControls` requires positive values:

| Key | Example default | Enforced behavior |
|---|---:|---|
| `MaximumTotalWorkers` | 2 | Caps each service's configured concurrency; maximum 16 |
| `MinimumFreeDiskGB` | 10 | Checked before and during partition writes |
| `MaximumProcessMemoryMB` | 2048 | Checked before and every 1,000 written records |
| `MaximumDeduplicationKeysPerPartition` | 500000 | Fails a partition before unbounded hash-set growth |
| `MaximumQueueRecords` | 25000 | Bounds UAL/Defender buffering and triggers window split |

Collectors are `EntraAudit`, `EntraSignIns`, `EntraRiskySignIns`, `UnifiedAudit`, `IntuneAudit`, `AzureActivity`, and `DefenderXdr`. A selected collector not in `RequiredCollectors` is optional. Optional unavailable/failed sources remain visible in run status and do not masquerade as successful data.

Service override keys are `MaxAttempts`, `BaseDelaySeconds`, `MaxDelaySeconds`, `MinSpacingMilliseconds`, `MaxConcurrency`, `CircuitBreakerThreshold`, `CircuitBreakerCooldownSeconds`, `InitialWindowMinutes`, `MinWindowMinutes`, `MaxWindowMinutes`, `PageSize`, `MinPageSize`, and `RecoverySuccesses`. Valid ranges and service page safety ceilings are enforced. Purview concurrency must remain 1.

## Deployment examples

Small tenant / first production run:

```powershell
ScaleProfile = 'Small'
WindowHours = 1
ServicePolicyOverrides = @{}
ResourceControls = @{
    MaximumTotalWorkers = 2; MinimumFreeDiskGB = 10
    MaximumProcessMemoryMB = 2048
    MaximumDeduplicationKeysPerPartition = 500000
    MaximumQueueRecords = 25000
}
```

Measured medium tenant:

```powershell
ScaleProfile = 'Medium'
WindowHours = 0.75
ServicePolicyOverrides = @{ Purview = @{ MinSpacingMilliseconds = 1000 } }
ResourceControls = @{
    MaximumTotalWorkers = 3; MinimumFreeDiskGB = 25
    MaximumProcessMemoryMB = 3072
    MaximumDeduplicationKeysPerPartition = 750000
    MaximumQueueRecords = 35000
}
```

Large/high-density tenant, tuned conservatively:

```powershell
ScaleProfile = 'Large'
WindowHours = 0.5
ServicePolicyOverrides = @{
    Graph = @{ MaxConcurrency = 2 }
    Defender = @{ InitialWindowMinutes = 3; MaxConcurrency = 1 }
}
ResourceControls = @{
    MaximumTotalWorkers = 4; MinimumFreeDiskGB = 100
    MaximumProcessMemoryMB = 4096
    MaximumDeduplicationKeysPerPartition = 1000000
    MaximumQueueRecords = 50000
}
```
Profiles are local ceilings, not Microsoft quotas. Start with `Small`; increase only from observed successful metrics. See [API limits and scaling](api-limits-and-scaling.md).
Profiles are local ceilings, not Microsoft quotas. Start with `Small`; increase only from observed successful metrics. See [API limits and scaling](api-limits-and-scaling.md).
