# Testing

There are five kinds of test. They are reported separately because they
prove different things.

| Kind | Command | Needs | Proves |
|---|---|---|---|
| **Static** | `tests/static.sh` | bash, shellcheck, docker compose (parse only) | Syntax, lint, Compose files render, example config uses documentation addresses, no dumps or secrets tracked |
| **Unit / component** | `IMAGE=… tests/run-unit.sh` | Docker | Logic **inside the image under test**, against a fake `mysqldump`, with tmpfs mounts as staging and destination: cron, retention boundaries/DST/overlaps/gaps, namespace isolation and legacy preservation, capacity on a real 8 MiB filesystem, disabled mode, signals, overlap prevention, atomic publication, delivery bookkeeping/idempotency/conflicts, **simulated** hung transfers, status formats |
| **Container + restore** | `IMAGE=… tests/integration/restore.sh`, `tests/integration/compose.sh` | Docker | Real `mysqldump` 8.0.37 against disposable MySQL 8.0.37 servers; full restore with plain `mysql` into a separate server; comparison of objects and data; the reference `compose.yaml` deployed unchanged, with simulated destination outages (marker removed, worker stopped) |
| **Evidence** | `tests/integration/mariadb-client-regression.sh` | Docker | Dumps the fixture with the MariaDB client and shows that restoring it into MySQL 8.0.37 fails with `ERROR 3105` |
| **Real NFS** | `tests/integration/nfs.sh` (CI only) | root on a disposable Linux host | Kernel NFS server on loopback, NFSv4.2 **hard** mount, late mount via `rslave`, fstype/source/marker checks, O_DIRECT verification, and a **real server outage** with recovery |

## Isolation

- Unit tests run inside a container with `--network none` and tmpfs mounts.
  They refuse to start unless `/staging`, `/destination` and `/small` are
  mount points. The CLI is always invoked through `env -i` with an explicit
  variable list.
- Integration tests create every container, volume and network with a random
  run id and a `mbtest=<id>` label, on an `--internal` network with no
  published ports, and remove them on exit. Database passwords are random and
  generated in the script. Of the caller's environment, only `IMAGE` and
  `MYSQL_SERVER_IMAGE` are read, and both are validated as image references.
- The NFS test refuses to run unless `CI=true`, `MBTEST_ALLOW_HOST_NFS=1` and
  root. It configures host NFS and must only run on a throwaway machine.
- Test data is synthetic (`tests/fixtures/schema.sql`).

## Simulated versus real failures

- `t_simulated_hung_transfer_is_bounded` replaces `cp` with a process that
  sleeps. It proves the supervisor's deadline, single-pass and cleanup logic.
  It does **not** reproduce uninterruptible NFS I/O.
- `compose.sh` simulates an unavailable destination by removing the marker
  and stopping the worker.
- Only `nfs.sh` exercises a real NFS server going away under a hard mount.

## Running locally

```bash
docker build -t mysql-backup:dev .
tests/static.sh
IMAGE=mysql-backup:dev tests/run-unit.sh
IMAGE=mysql-backup:dev tests/integration/restore.sh
IMAGE=mysql-backup:dev tests/integration/compose.sh
```

Behind a TLS-intercepting proxy, the build can receive an extra CA bundle as
a BuildKit secret. The bundle is removed again in the same layer:
`docker build --secret id=extra_ca,src=/path/ca.crt …`.
