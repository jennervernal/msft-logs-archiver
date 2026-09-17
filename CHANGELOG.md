# Changelog

All notable changes to this project are documented here.

## [0.1.0] - 2026-09-17

### Added

- Interactive delegated collectors for Entra audit/sign-ins, Purview Unified Audit Log, Intune audit, Azure Activity Log, and optional Defender XDR.
- One-command `Start-M365LogArchive.ps1` workflow with Graph tenant discovery, A3-safe defaults, per-service maximum-history targets, and independent durable incremental cursors.
- Atomic gzip JSONL partitions, SHA-256 manifests, deterministic checkpoints/resume, partition-local deduplication, and integrity/export utilities.
- Adaptive per-service retries, jitter, pacing, quota signals, window/page/concurrency reduction, recovery, and circuit breakers.
- Pester coverage for core persistence/integrity and rate-limit behavior.
- Production installation, permission, configuration, architecture, operations, scaling, archive, recovery, security, troubleshooting, collector, verification, and retention documentation.
