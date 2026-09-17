# Security policy

## Reporting a vulnerability

Do not open a public issue containing an exploitable vulnerability, credential, token, tenant identifier, or Microsoft 365 record. Use GitHub's private vulnerability reporting for this repository when enabled, or contact the repository owner privately through their published GitHub contact channel. Include affected version/commit, impact, minimal reproduction with fabricated data, and suggested mitigation. Do not include real tenant exports.

The maintainer will acknowledge, triage, coordinate remediation, and publish appropriate release guidance. Please avoid accessing data you do not own, disrupting Microsoft services, or testing against production tenants without authorization.

## Operational security boundary

This project writes sensitive records to a user-selected local filesystem. It supplies gzip compression and SHA-256 integrity checks; it does **not** provide automatic encryption, a signed chain of custody, centralized access control, secret storage, unattended app-only identity, distributed locking, SIEM ingestion, or backup/retention enforcement.
Operators are responsible for least-privileged Microsoft access, host hardening, NTFS ACLs, BitLocker or approved at-rest encryption, secure backups, access auditing, retention/legal hold, diagnostic redaction, and incident response. See [docs/security.md](docs/security.md).
Operators are responsible for least-privileged Microsoft access, host hardening, NTFS ACLs, BitLocker or approved at-rest encryption, secure backups, access auditing, retention/legal hold, diagnostic redaction, and incident response. See [docs/security.md](docs/security.md).
