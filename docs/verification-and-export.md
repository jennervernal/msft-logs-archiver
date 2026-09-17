# Verification and export

## Verify integrity

Verify one partition manifest:

```powershell
.\Test-Archive.ps1 -Path 'D:\M365LogArchive\EntraAudit\2026\09\15\20260915T000000Z-123456789abc\20260915T000000Z_20260915T010000Z.manifest.json'
```

Verify every partition under a root:

```powershell
.\Test-Archive.ps1 -Path D:\M365LogArchive
if ($LASTEXITCODE -ne 0) { throw 'Archive verification failed.' }
```

The verifier excludes `run.manifest.json`, locates each partition's adjacent archive, and compares SHA-256 of compressed bytes to `sha256`. It reports validity and record count. It does not validate source-level semantics, recalculate decompressed record count, authenticate provenance, or repair files.

Recommended workflow: verify immediately after collection, before and after backup/copy, after restore, and periodically in place. Preserve verifier output in an approved operational system without sensitive paths where those are restricted.

## Inspect records

Stream objects without writing an export:

```powershell
.\Export-ArchiveRecords.ps1 -ArchivePath 'D:\M365LogArchive\EntraAudit\2026\09\15\*\*.jsonl.gz' |
    Select-Object -First 20
```

Export decompressed JSONL while retaining each source record's serialized line:

```powershell
$files = Get-ChildItem 'D:\M365LogArchive\UnifiedAudit' -Filter '*.jsonl.gz' -Recurse
.\Export-ArchiveRecords.ps1 -ArchivePath $files.FullName -OutputPath 'D:\ControlledExports\ual.jsonl'
```

Without `-OutputPath`, lines are parsed with `ConvertFrom-Json` and emitted as objects. With `-OutputPath`, decompressed lines are copied to a new UTF-8 JSONL file. Existing output is overwritten. The utility accepts wildcard paths through `Resolve-Path`; order inputs explicitly if order matters.

## Restore and inspection
Restore each `.jsonl.gz` with its `.manifest.json`, retain the original relative path when practical, and run verification before use. Treat exports as new sensitive copies: apply ACLs/encryption, document purpose, minimize fields downstream where permitted, and delete through approved lifecycle procedures.
Restore each `.jsonl.gz` with its `.manifest.json`, retain the original relative path when practical, and run verification before use. Treat exports as new sensitive copies: apply ACLs/encryption, document purpose, minimize fields downstream where permitted, and delete through approved lifecycle procedures.
