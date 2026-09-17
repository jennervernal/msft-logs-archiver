# Operations runbook

## Initial backfill

1. Confirm source-native retention and choose a fixed range inside it. Backfill oldest-first in reviewable ranges rather than one maximum-size request.
2. Start with `ScaleProfile = 'Small'`, one-hour `WindowHours`, entitlement-dependent collectors optional, and ample free disk.
3. Run `pwsh -NoProfile -File .\Archive-M365Logs.ps1 -ConfigPath .\Config.psd1`.
4. Review exit code, `_runs\<run-id>\run.manifest.json`, collector statuses, errors, counts, API wait/circuit metrics, and free capacity.
5. Run `.\Test-Archive.ps1 -Path D:\M365LogArchive`.
6. Preserve archive files and manifests together, then proceed to the next range.

## Incremental operation

After backfill, switch to `ArchiveMode = 'Incremental'`. The first run uses `IncrementalInitialLookbackHours`; later runs begin at the last successful end minus `IncrementalOverlapMinutes` and end at current UTC minus `IngestionDelayMinutes`. Incremental state advances only when all required collectors succeed. Preserve overlapping runs and reconcile downstream by source IDs.

Recommended operator workflow: sign in with the designated least-privileged account, confirm storage/backup health, launch one run per output root, complete browser prompts, monitor structured console/log output, inspect the run manifest, verify hashes, and record operational exceptions. Do not launch a second run to bypass a slow first run.

## Scheduling limitation

Windows Task Scheduler may launch the script only as an attended convenience:

```text
Program: pwsh.exe
Arguments: -NoProfile -File "C:\Tools\msft-logs-archiver\Archive-M365Logs.ps1" -ConfigPath "C:\Secure\Config.psd1"
```

Choose **Run only when user is logged on** and expect browser prompts whenever sessions require authentication. This delegated build is not unattended. A background task without an available operator must fail rather than bypass sign-in. Do not store passwords in task arguments. Unattended operation requires a future certificate app-only design.

## Monitoring

Monitor run `status`; collector `status`, `records`, `partitions`, `elapsedSeconds`, and `recordsPerSecond`; and per-service `requests`, `pages`, `throttles`, `transients`, `permanentFailures`, cumulative wait, circuit events, low-quota signals, setting changes, and `requestsPerSecond`. Alert on missing expected runs, required failures/partials, hash failures, repeated optional failures, rising throttle wait, circuit events, or sustained record-count discontinuity.

## Capacity, retention, logs, and backups

Estimate compressed and temporary uncompressed needs from representative runs, then retain safety headroom above `MinimumFreeDiskGB`. Capacity depends on event volume and payload shape, not user count alone. Keep `_runs`, `_state`, partition manifests, and archives in backup scope. Use versioned or immutable backup where policy requires it, encrypt backup media, restrict restore operators, and test restores.

`run.log.jsonl` is per-run, so no in-place rotation is needed. Apply a reviewed lifecycle policy to old run logs; do not remove manifests needed to prove archive integrity. Local retention must be defined by legal, audit, privacy, and records teams and is independent of Microsoft source retention.

## Routine integrity verification
Run `Test-Archive.ps1` after each run and after copy/restore operations. Periodically compare file inventory to backup inventory, verify random exports, validate filesystem ACLs, review free disk, inspect stale lock files only when no process owns them, and confirm current Microsoft permissions, licensing, retention, and API documentation.
Run `Test-Archive.ps1` after each run and after copy/restore operations. Periodically compare file inventory to backup inventory, verify random exports, validate filesystem ACLs, review free disk, inspect stale lock files only when no process owns them, and confirm current Microsoft permissions, licensing, retention, and API documentation.
