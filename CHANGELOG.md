# Changelog

All notable changes are listed here. Versions follow semantic versioning and
are independent of the bundled MySQL client version.

## 0.1.0 - 2026-10-31

First release.

- Producer: scheduled (5-field cron, time-zone aware) Oracle `mysqldump`
  8.0.37 logical dumps of one database, streamed through gzip, verified
  (pipeline status and completion trailer) and published atomically on local
  staging.
- Delivery worker: copies completed dumps to a host-mounted destination
  (NFS), verifies size and SHA-256 by reading the copy back, publishes
  atomically without overwriting, and records delivery afterwards. Retries are
  idempotent. Conflicting remote files are never replaced.
- Tiered retention (latest/hourly/daily/weekly; union; calendar-based in
  `BACKUP_TZ`) for the destination. Local staging keeps undelivered dumps plus
  24 h of delivered history.
- Capacity safeguards: reserve, queue limits, growth-aware estimate,
  reclamation of delivered files only, an in-dump watchdog, and clear failures
  that preserve existing dumps.
- Staging and destination identity checks: mount point, marker file,
  filesystem type, mount source.
- `status` (text, JSON, Prometheus), healthcheck, `retention-preview`,
  `dump`, `deliver`, `check-config`.
- Reference Compose deployments (`deploy/compose.yaml`,
  `deploy/compose.local-only.yaml`). Containers are unprivileged and
  read-only, with no Docker socket.
- Tested on linux/amd64 and linux/arm64 against MySQL 8.0.37.
