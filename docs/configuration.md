# Configuration reference

All settings are environment variables, validated when the container starts.
An invalid value exits with code 2 and names the variable. Sizes accept `K`,
`M`, `G` and `T` (binary units). Durations accept `s`, `m`, `h`, `d` and `w`;
a plain number means seconds. `mysql-backup check-config` prints the effective
values. It never prints secrets.

## General

| Variable | Default | Meaning |
|---|---|---|
| `BACKUP_ENABLED` | `true` | `false` stops **all** activity: no dumps, deliveries or pruning, and `dump`/`deliver` exit 3. Status reports `DISABLED`. |
| `BACKUP_NAMESPACE` | *(required)* | Matches `^[a-z0-9][a-z0-9._-]{0,62}$`. Used as the file name prefix and directory name. Every file, lock, status record and retention decision is scoped to it. Use separate namespaces for production and development (`myapp-prod`, `myapp-dev`). |
| `BACKUP_TZ` | `TZ` or `UTC` | IANA zone used for the schedule and for retention calendar days and weeks. File names are always UTC. |
| `BACKUP_SCHEDULE` | `0 * * * *` | 5-field cron expression evaluated in `BACKUP_TZ`. See [Schedule](#schedule). |
| `BACKUP_ON_START` | `false` | Also dump once each time the producer starts. |
| `LOG_LEVEL` | `info` | `debug` adds capacity and selection details. |

## Database (producer only)

| Variable | Default | Meaning |
|---|---|---|
| `MYSQL_HOST` | *(required)* | Host name on the shared Docker network, usually the database service name. |
| `MYSQL_PORT` | `3306` | |
| `MYSQL_DATABASE` | *(required)* | Exactly one database. |
| `MYSQL_USER` / `MYSQL_USER_FILE` | *(required)* | Set one of the two. |
| `MYSQL_PASSWORD` / `MYSQL_PASSWORD_FILE` | *(required)* | Set one of the two. The `_FILE` form (Compose or Docker secret) is recommended. Setting both is an error. |
| `MYSQL_SSL_MODE` | `PREFERRED` | `DISABLED`, `PREFERRED`, `REQUIRED`, `VERIFY_CA` or `VERIFY_IDENTITY`. |
| `MYSQL_SSL_CA` | | Path to a CA file inside the container. |
| `MYSQL_CONNECT_TIMEOUT` | `15` | Seconds, for the preflight connection. |
| `MYSQL_VERSION_CHECK` | `warn` | `warn`, `strict` (refuse servers outside the tested 8.0 series) or `off`. |
| `MYSQLDUMP_SET_GTID_PURGED` | `OFF` | `OFF` keeps dumps restorable into any instance. |
| `MYSQLDUMP_EXTRA_ARGS` | | Extra `mysqldump` flags, split on spaces. Flags that change credentials, connection, database selection or output are rejected. |
| `GZIP_LEVEL` | `6` | 1–9. |
| `DUMP_VERIFY` | `true` | Re-read the compressed file and require mysqldump's completion trailer before publishing. |

Credentials are written only to a private option file (mode 0600) under the
container's `/tmp`, which is a tmpfs in the reference Compose file. That file
is passed to the clients with `--defaults-file` and deleted afterwards.
Credentials never appear in command lines, process environments of the dump
clients, logs or status output.

## Staging

| Variable | Default | Meaning |
|---|---|---|
| `STAGING_DIR` | `/staging` | Path inside the container. |
| `STAGING_REQUIRE_MOUNTPOINT` | `true` | Refuse to run if `STAGING_DIR` is not a mount point inside the container. |
| `STAGING_MARKER_ID` | | If set, the first line of `STAGING_DIR/.mysql-backup-staging` must equal it. The marker file itself is always required. |
| `STAGING_EXPECT_FSTYPE` | | Comma-separated list, for example `ext4,xfs`. |
| `STAGING_RESERVE` | `2G` | Free space that dumps must never consume. |
| `STAGING_RESERVE_PERCENT` | `5` | The reserve is the larger of `STAGING_RESERVE` and this percentage of the filesystem. |
| `STAGING_FIRST_DUMP_ESTIMATE` | `1G` | Size assumed before any dump exists. |
| `DUMP_SIZE_GROWTH_PERCENT` | `150` | The estimate is the largest of the last 5 dumps × this percentage. |
| `STAGING_MAX_PENDING_COUNT` | `0` | Refuse new dumps once this many are undelivered (0 = no count limit). |
| `STAGING_MAX_PENDING_BYTES` | `0` | Refuse new dumps if undelivered bytes plus the estimate would exceed this (0 = no limit). |
| `LOCAL_KEEP_DELIVERED` | `24h` | Delivered dumps stay in staging this long (by dump time). |
| `LOCAL_KEEP_LATEST` | `1` | Always keep the newest N local dumps, delivered or not. |
| `LOCAL_RETENTION_KEEP_LATEST`, `LOCAL_RETENTION_HOURLY_DAYS`, `LOCAL_RETENTION_DAILY_DAYS`, `LOCAL_RETENTION_WEEKLY_WEEKS` | the `RETENTION_*` values | Tiered policy for staging, used only when `DELIVERY_ENABLED=false`. |

## Delivery

| Variable | Default | Meaning |
|---|---|---|
| `DELIVERY_ENABLED` | `false` (image), `true` (reference compose.yaml) | Must be identical for the producer and the delivery worker. The producer uses it to decide how local staging is pruned. |
| `DELIVERY_DIR` | `/destination` | Path inside the delivery container. |
| `DELIVERY_REQUIRE_MOUNTPOINT` | `true` | |
| `DELIVERY_MARKER_ID` | | If set, the first line of `DELIVERY_DIR/.mysql-backup-destination` must equal it. The marker itself is always required. |
| `DELIVERY_EXPECT_FSTYPE` | | For example `nfs,nfs4`. |
| `DELIVERY_EXPECT_SOURCE` | | Exact mount source, for example `192.0.2.10:/export/mysql-backups`. |
| `DELIVERY_POLL_INTERVAL` | `60s` | How often the worker checks for pending dumps. This check reads local staging only. |
| `DELIVERY_RETRY_INTERVAL` | `5m` | Wait after a failed pass before trying again. |
| `DELIVERY_ATTEMPT_TIMEOUT` | `2h` | Deadline for one pass. See [outage behaviour](outage-behavior.md#unresponsive-nfs). |
| `DELIVERY_VERIFY_READ` | `auto` | `direct` re-reads copies with O_DIRECT (bypassing the client cache), `cached` uses a normal read, `auto` tries direct and falls back. |
| `REMOTE_RETENTION_ENABLED` | `true` | |
| `RETENTION_KEEP_LATEST` | `3` | Remote policy; see [retention](retention.md). Minimum 1. |
| `RETENTION_HOURLY_DAYS` | `2` | |
| `RETENTION_DAILY_DAYS` | `14` | |
| `RETENTION_WEEKLY_WEEKS` | `8` | |

## Status

| Variable | Default | Meaning |
|---|---|---|
| `STATUS_MAX_LOCAL_AGE` | `26h` | CRITICAL when the newest local dump is older. |
| `STATUS_MAX_DELIVERED_AGE` | `26h` | WARNING when the newest delivered dump is older. |
| `STATUS_MAX_PENDING_AGE` | `6h` | WARNING when the oldest undelivered dump is older. |
| `STATUS_TEXTFILE` | | If set, a Prometheus textfile is rewritten after every run. Set it in one container only. |

## Schedule

The schedule uses five fields: `minute hour day-of-month month day-of-week`.
Each field accepts `*`, numbers, ranges (`6-21`), steps (`*/15`, `0-30/10`),
lists (`1,15`), month names (`JAN`–`DEC`) and weekday names (`SUN`–`SAT`;
both `0` and `7` mean Sunday). When both day fields are restricted, a time
matches if **either** one matches. This is standard cron behaviour.

Examples, evaluated in `BACKUP_TZ`:

| Expression | Meaning |
|---|---|
| `0 6-21 * * *` | Every day on the hour from 06:00 through 21:00 inclusive: 16 dumps a day, none overnight. |
| `0 * * * *` | Hourly, around the clock. |
| `30 2 * * *` | Daily at 02:30. |
| `*/15 8-18 * * MON-FRI` | Every 15 minutes during business hours on weekdays. |

Daylight-saving time:

- At spring-forward, a time that does not exist locally (for example 02:30)
  does not run that day.
- At fall-back, a time that occurs twice runs only once.
- Schedules such as `0 6-21 * * *` are unaffected, because US DST changes
  happen at 02:00.

Missed runs, for example while the container was stopped, are not caught up.
Use `BACKUP_ON_START=true` if you want a dump whenever the producer starts. If
a dump is still running when the next scheduled time arrives, that run is
skipped and logged. It is never run in parallel.

## Secrets with stack managers

The reference Compose file mounts `./secrets/mysql_password` as a Compose
secret. If your manager cannot provide file secrets:

1. Remove the `secrets:` entries.
2. Set `MYSQL_PASSWORD_FILE=` (empty) and `MYSQL_PASSWORD=...` in the
   manager's environment.

The password then exists in the container's environment, where anyone with
Docker access to the host can read it. It still never reaches `mysqldump`'s
command line or the logs.
