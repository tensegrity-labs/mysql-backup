# Status and monitoring

`mysql-backup status` reads only local staging. It never touches the
destination, never takes locks and never connects to MySQL, so it answers even
while NFS is hung. Its exit code follows the Nagios/monitoring-plugin
convention:

| Exit | State | Raised when |
|---|---|---|
| 0 | OK (or DISABLED) | |
| 1 | WARNING | last dump attempt failed (not for capacity) or was interrupted; last delivery pass failed; oldest pending dump older than `STATUS_MAX_PENDING_AGE`; newest delivered dump older than `STATUS_MAX_DELIVERED_AGE` |
| 2 | CRITICAL | no completed dump yet; newest local dump older than `STATUS_MAX_LOCAL_AGE`; last dump failed for **capacity** or a full queue; staging invalid (marker or mount); delivery **stalled**; destination **conflict** |
| 3 | UNKNOWN | reserved |

**Local** health (are dumps being produced?) and **delivery** health (are they
reaching NFS?) are reported separately.

```text
$ docker compose exec backup mysql-backup status
mysql-backup 0.1.0  namespace=myapp-prod  state=WARNING
  ! 5 backup(s) pending delivery, oldest 6h12m (limit 6h)
local:
  latest backup      myapp-prod-20260715T170001Z.sql.gz (14m ago)
  last dump attempt  ok - dump completed
  staged backups     29 (41.0GiB)
  staging free       52.3GiB of 100.0GiB
delivery:
  latest delivered   myapp-prod-20260715T110002Z.sql.gz (6h14m ago)
  pending            5 backup(s), 7.1GiB, oldest 6h12m
  last attempt       failed - destination unavailable: destination marker ... is missing
```

## JSON

`status --json` returns one JSON object:

```json
{"version":"0.1.0","namespace":"myapp-prod","state":"WARNING","time":1784134440,
 "enabled":true,"delivery_enabled":true,"problems":["..."],
 "local":{"latest_file":"...","latest_age_seconds":840,"count":29,"bytes":44023414784,
          "last_result":"ok","last_message":"dump completed","consecutive_failures":0,
          "capacity_failure":false,"staging_ok":true,
          "staging_available_bytes":56157...,"staging_total_bytes":107374...},
 "delivery":{"latest_delivered_file":"...","latest_delivered_age_seconds":22440,
             "pending_count":5,"pending_bytes":7623...,"pending_oldest_age_seconds":22320,
             "last_result":"failed","last_message":"...","stalled":false}}
```

## Prometheus textfile

Set `STATUS_TEXTFILE=/metrics/mysql_backup.prom` in **one** container (the
producer is a good choice). Mount that directory into node_exporter's
textfile collector. The file is rewritten atomically after every run and
every minute. Available metrics:

```text
mysql_backup_status{namespace}                         0/1/2
mysql_backup_enabled{namespace}
mysql_backup_latest_local_timestamp_seconds{namespace}
mysql_backup_latest_delivered_timestamp_seconds{namespace}
mysql_backup_local_count / _local_bytes{namespace}
mysql_backup_pending_count / _pending_bytes{namespace}
mysql_backup_pending_oldest_timestamp_seconds{namespace}
mysql_backup_producer_consecutive_failures{namespace}
mysql_backup_capacity_failure{namespace}
mysql_backup_staging_available_bytes{namespace}
mysql_backup_delivery_stalled{namespace}
```

Example alert: `time() - mysql_backup_latest_local_timestamp_seconds > 26*3600`.

## Docker health

Both services have a `healthcheck`:

- `healthcheck producer` fails if the worker loop's heartbeat is older than
  3 minutes, or if any local CRITICAL condition is present.
- `healthcheck delivery` does the same for delivery conditions (stalled,
  conflict).

Delivery WARNINGs, such as a temporary NFS outage, do not mark the container
unhealthy. Docker only reports health; it does not restart unhealthy
containers. Monitor the health state, or call `status` from your monitoring
system:

```bash
docker compose -f /opt/stacks/myapp-backup/compose.yaml exec -T backup mysql-backup status --json
```

`ops/mysql-backup-status` is a host-side wrapper suitable for Nagios, Icinga,
Zabbix or Uptime Kuma push checks. It prints one line and exits 0, 1 or 2.

## Logs

Logs are single lines on stderr (`docker compose logs`), with a UTC timestamp,
level, role and namespace:

```text
2026-07-15T17:00:02Z INFO  [producer/myapp-prod] dump completed: myapp-prod-20260715T170001Z.sql.gz 1.4GiB in 96s sha256=…
2026-07-15T17:00:41Z ERROR [delivery/myapp-prod] destination unavailable: destination marker /destination/.mysql-backup-destination is missing; …; 5 backup(s) remain queued locally
```

Logs never contain passwords, and they do not contain row data. `mysqldump`
error output (at most 20 lines) is logged as a warning. In the reference
Compose file the json-file log driver is limited to 5 × 10 MB.

No external notification service is included. Use your existing monitoring.
