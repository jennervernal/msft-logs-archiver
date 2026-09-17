# Security

Microsoft 365 audit, sign-in, device, cloud-control-plane, and security records are sensitive. They can expose identities, IP addresses, device names, message metadata, resource paths, investigation details, and administrative activity. Treat the output root as security/audit data, not ordinary logs.

## Storage controls

- Place the archive on a dedicated NTFS volume or directory. Disable inherited broad access where policy permits and grant only archive operators, approved security/audit readers, backup service identities, and administrators with a documented need.
- Use separate read and write groups. Review effective ACLs and access-group membership routinely.
- Enable BitLocker or approved volume encryption and protect recovery keys. **The suite does not automatically encrypt local archive files.** Gzip is compression, not encryption.
- Encrypt backups in transit and at rest, restrict restore/export privileges, maintain immutable/versioned copies where required, and test restoration.
- Audit access to the archive location using Windows object-access policy or approved endpoint/storage monitoring, with attention to bulk reads, exports, ACL changes, and deletion.

## Identity and secrets

Use least-privileged delegated scopes and Microsoft roles from [authentication and permissions](authentication-and-permissions.md). The script does not persist tokens or credentials and process-scopes Graph/Azure contexts, but installed Microsoft authentication components may have their own caches. Protect the operator profile and workstation. Never put credentials, tokens, client secrets, certificates, real tenant exports, or bearer headers in configuration, command history, issues, or diagnostics.

## Data minimization and lifecycle

Enable only collectors needed for a documented purpose, limit ranges to required retention/backfill, restrict `UnifiedAuditRecordTypes` and Defender tables when complete breadth is unnecessary, and control downstream exports. Define local retention with privacy, legal, security, and records stakeholders. Cloud source expiration does not authorize local deletion; legal hold may require longer preservation.

## Operational boundaries and incidents

The integrity hash detects byte changes but is not a digital signature and does not establish independent chain of custody. Protect manifests and backups from the same principals that can alter archives when stronger evidentiary assurance is required. The local lock prevents concurrent writers to one root; it is not distributed authorization.
If archive exposure is suspected: preserve evidence, restrict access without destroying timestamps, identify affected ranges and identities, rotate/revoke relevant operator sessions where appropriate, review Microsoft and filesystem access logs, notify incident/privacy/legal teams, assess exported copies and backups, and document integrity results. Do not publish diagnostic bundles until scrubbed of tenant data.
If archive exposure is suspected: preserve evidence, restrict access without destroying timestamps, identify affected ranges and identities, rotate/revoke relevant operator sessions where appropriate, review Microsoft and filesystem access logs, notify incident/privacy/legal teams, assess exported copies and backups, and document integrity results. Do not publish diagnostic bundles until scrubbed of tenant data.
