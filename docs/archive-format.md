# Archive format

## Directory layout

```text
<OutputRoot>\
  .archive.lock
  _state\
    incremental-<tenant-guid>.json
    throttle-state.json
  _runs\<run-id>\
    checkpoint.json
    run.log.jsonl
    run.manifest.json
  <Source>\yyyy\MM\dd\<run-id>\
    <start>_<end>.jsonl.gz
    <start>_<end>.manifest.json
```

`<Source>` is the collector name. Azure and Defender append the fabricated-safe subscription GUID or table name, for example `AzureActivity-11111111-2222-3333-4444-555555555555` or `DefenderXdr-AlertInfo`.

## Data files

Each `.jsonl.gz` is gzip-compressed, UTF-8 JSON Lines: one compact JSON object per line. Objects preserve the service response shape; the suite does not impose a common record schema. An empty successful partition is a valid empty gzip file.

Fabricated decompressed examples:

```json
{"id":"audit-fabricated-001","activityDateTime":"2026-09-15T10:04:12Z","activityDisplayName":"Example activity"}
{"id":"audit-fabricated-002","activityDateTime":"2026-09-15T10:07:31Z","activityDisplayName":"Example update"}
```

## Partition manifest

```json
{
  "schemaVersion": "1.0",
  "source": "EntraAudit",
  "runId": "20260915T000000Z-123456789abc",
  "queryStartUtc": "2026-09-15T00:00:00.0000000Z",
  "queryEndUtc": "2026-09-15T01:00:00.0000000Z",
  "collectedUtc": "2026-09-17T11:15:00.0000000Z",
  "recordCount": 42,
  "archiveFile": "20260915T000000Z_20260915T010000Z.jsonl.gz",
  "compression": "gzip",
  "format": "jsonl",
  "encoding": "utf-8",
  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "status": "success",
  "continuation": {"completed":true,"nextLink":null,"service":"Graph"}
}
```

A failed partition uses `status: "failed"`, `recordCount: 0`, null archive/hash, an `error`, and continuation with `completed: false`. In the current schema, successful partition status is named `success` (complete) rather than `complete`.

## Run manifest and statuses

The run manifest contains `schemaVersion`, `runId`, `tenantId`, query bounds, `completedUtc`, overall `status`, collector results, partition inventory, `checkpointFile`, `configFingerprint`, `scaleProfile`, resource preflight/limits, and `apiMetrics`. A fatal pre-run/post-run error produces a reduced failed manifest with `fatalError`.

Overall status is `completed`, `completed-with-skips-or-optional-errors`, or `failed`. Collector status is:

| Semantic class | Stored value |
|---|---|
| complete | `success` |
| partial required | `partial` |
| partial optional | `optional-partial` |
| skipped | `skipped-unavailable` |
| failed required | `failed` |
| failed optional | `optional-failed` |

Do not infer completeness from the presence of an archive alone; evaluate manifest status and hash. `configFingerprint` is a deterministic SHA-256 over collection-affecting configuration, not a configuration dump.

## Compatibility
Consumers must check `schemaVersion`, tolerate additive fields, preserve unknown source-record fields, and reject unsupported major versions. Version `1.0` hashes compressed bytes, uses partition-local JSONL fidelity, and has no cross-run normalized record schema. Keep archive and adjacent manifest together.
Consumers must check `schemaVersion`, tolerate additive fields, preserve unknown source-record fields, and reject unsupported major versions. Version `1.0` hashes compressed bytes, uses partition-local JSONL fidelity, and has no cross-run normalized record schema. Keep archive and adjacent manifest together.
