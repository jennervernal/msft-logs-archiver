# Recovery and idempotency

## Interruption and rerun

Rerun the identical command and configuration. The deterministic run ID selects the same `_runs` directory. Checkpointed completed partitions are skipped; the saved active window is reused; an incomplete partition is recollected. A valid successful partition is never overwritten. A successful manifest whose archive is missing or hash-invalid causes a hard failure rather than silent replacement.

With `Start-M365LogArchive.ps1`, each collector is a separate deterministic incremental invocation. The exact pending start/end is persisted before API work, so interruption reselects the same run ID and checkpoint instead of shifting a two-year backfill forward with wall-clock time. Successful collector state advances independently. A partial, failed, or skipped required collector retains its pending range on the next launch; it does not force successful sources to repeat their maximum-history backfill.

Deduplication occurs within each partition. Incremental overlap can repeat the same source record across different runs by design; consumers should reconcile by stable source ID (or appropriate composite key) without discarding legitimate updates.

## Partial failures

Required collector failure/partial status yields exit code 1 and prevents incremental state advancement. Optional collectors produce `optional-failed`, `optional-partial`, or `skipped-unavailable`, allowing the overall run to complete with visible exceptions. Correct permission, licensing, service health, or capacity and rerun the same configuration. Do not edit a run manifest to claim completion.

## Lock recovery

The process keeps `.archive.lock` open with exclusive sharing and removes it in `finally`. If a crash leaves the path, a later process can reopen and replace its contents when no handle owns it. If locking fails, confirm no archive process is running and no remote filesystem client owns the handle. Delete only the exact `.archive.lock` after that confirmation; never disable locking.

## Corruption

Run `Test-Archive.ps1`. For a hash mismatch, quarantine the archive and manifest pair, compare a known-good backup, and restore both together. If no trusted copy exists, preserve the corrupt evidence, document the loss, and rerun only while the source range remains available. Invalid checkpoint or throttle-state JSON is surfaced explicitly. Preserve the invalid file for investigation before replacing state; understand that changing checkpoint/config may select different work.

## Disk exhaustion and resource bounds

Collection checks disk and process memory before work and periodically during writing. On exhaustion, stop other consumers or expand storage; remove only identified temporary `.tmp` files after confirming no run is active. Do not delete completed partitions merely to let the same run proceed unless an approved retention/recovery decision accepts that data loss. Lower windows/queue bounds if a partition exceeds memory or dedupe limits.

## Safe deletion
Deletion is not a retry mechanism. Apply a reviewed retention policy to complete run units, retain legal/incident holds, verify backups first, and delete archive/manifest pairs consistently. Preserve run manifests/checkpoints needed for provenance. Never delete `_state` during an incremental workflow without recording the last successful boundary and approving a replacement backfill. See [security](security.md) and [archive format](archive-format.md).
Deletion is not a retry mechanism. Apply a reviewed retention policy to complete run units, retain legal/incident holds, verify backups first, and delete archive/manifest pairs consistently. Preserve run manifests/checkpoints needed for provenance. Never delete `_state` during an incremental workflow without recording the last successful boundary and approving a replacement backfill. See [security](security.md) and [archive format](archive-format.md).
