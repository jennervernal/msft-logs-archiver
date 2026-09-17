# Operations runbook

## Initial backfill

1. Run `.\Start-M365LogArchive.ps1 -ShowPlan` to review the default output and independent 30-day Entra, 180-day UAL, two-year Intune, and 90-day Azure targets without signing in.
2. Confirm ample disk for compressed output and temporary uncompressed JSONL. The default preflight requires 10 GB but a complete first run can require substantially more and take many hours.
3. Run `pwsh -NoProfile -File .\Start-M365LogArchive.ps1` and complete only official Microsoft sign-in prompts. No configuration question is asked.
4. Review exit code, `_runs\<run-id>\run.manifest.json`, collector statuses, errors, counts, API wait/circuit metrics, and free capacity.
5. Run `.\Test-Archive.ps1 -Path D:\M365LogArchive`.
6. Preserve archive files and manifests together. Microsoft retention/licensing can return less than the target range.

## Incremental operation

Run the same launcher again. Each default collector has a durable tenant/collector-specific state file and begins at its last successful end minus its own overlap. Entra/Azure use 15-minute delay/overlap, Intune 60 minutes, and UAL 120 minutes. A required partial, failed, or skipped collector does not advance its cursor, while successful collectors retain their progress independently. Preserve overlapping runs and reconcile downstream by source IDs.

For custom ranges or collectors, use `Archive-M365Logs.ps1 -ConfigPath .\Config.psd1`; this advanced mode remains supported.

Recommended operator workflow: sign in with the designated least-privileged account, confirm storage/backup health, launch one run per output root, complete browser prompts, monitor structured console/log output, inspect the run manifest, verify hashes, and record operational exceptions. Do not launch a second run to bypass a slow first run.

## Scheduling limitation

Windows Task Scheduler may launch the script only as an attended convenience:

```text
Program: pwsh.exe
Arguments: -NoProfile -File "C:\Tools\msft-logs-archiver\Start-M365LogArchive.ps1"
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
