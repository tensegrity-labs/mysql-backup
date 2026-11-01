# Architecture

```text
                 Docker network of the existing database (no published port)
 ┌──────────┐  mysql protocol  ┌──────────────────────┐
 │  MySQL   │◀─────────────────│ backup  (producer)   │  command: run
 │  server  │                  │ mysqldump | gzip     │
 └──────────┘                  └─────────┬────────────┘
                                         │ writes, atomically publishes
                               ┌─────────▼────────────┐   host filesystem dedicated
                               │  /staging  (local)   │   to staging (bind mount)
                               └─────────┬────────────┘
                                         │ reads pending, records delivery
                               ┌─────────▼────────────┐
                               │ backup-delivery      │  command: deliver-loop
                               │ copy → verify →      │  network_mode: none
                               │ publish → record     │
                               └─────────┬────────────┘
                                         │ host-mounted NFS (bind mount)
                               ┌─────────▼────────────┐
                               │ /destination (NFS)   │
                               └──────────────────────┘
```

The producer and the delivery worker are **two containers running the same
image with different commands**. They share code but nothing at runtime except
the staging directory.

- The producer mounts staging and connects to MySQL. It never mounts or
  touches the destination, so a missing, hung or full NFS share cannot block
  or fail a local dump.
- The delivery worker mounts staging and the destination. It needs no network
  because the host handles NFS, and it never connects to MySQL.
- Neither is privileged, neither mounts the Docker socket, and both run as an
  unprivileged user with a read-only root filesystem and all capabilities
  dropped. Mounting NFS is the host's job (see
  [host preparation](host-preparation.md)), which is why the containers need
  no `CAP_SYS_ADMIN`.
- Stopping, crashing or misconfiguring the delivery worker only lets the
  pending queue grow. See [outage behaviour](outage-behavior.md).

## On-disk layout

```text
/staging/                                   # STAGING_DIR (dedicated filesystem)
├── .mysql-backup-staging                   # marker written by the operator
├── myapp-prod/                             # completed dumps ONLY
│   ├── myapp-prod-20260715T120002Z.sql.gz
│   └── myapp-prod-20260715T130001Z.sql.gz
├── myapp-dev/                              # another namespace: fully independent
└── .mysql-backup/myapp-prod/               # bookkeeping, never *.sql.gz
    ├── work/<name>.sql.gz.<pid>.partial    # in-progress dump
    ├── meta/<base>.meta                    # size, sha256, versions, timing
    ├── delivered/<base>.delivered          # written only after verified delivery
    ├── status/{producer,delivery,delivery-loop}.state
    └── locks/{producer,delivery,local-prune}.lock

/destination/                               # DELIVERY_DIR (NFS export)
├── .mysql-backup-destination               # marker written by the operator
├── myapp-prod/myapp-prod-20260715T120002Z.sql.gz
└── .mysql-backup/myapp-prod/
    ├── incoming/<name>.partial             # in-progress transfer
    └── checksums/<name>.sha256             # `sha256sum -c` compatible
```

Naming rules that keep tools and humans from picking up the wrong file:

- A completed dump is **exactly** `<namespace>-YYYYMMDDTHHMMSSZ.sql.gz`, a
  regular file, in the namespace directory. The timestamp is UTC, so names
  sort chronologically and are unique per second.
- Temporary files end in `.partial`. Bookkeeping files end in `.meta`,
  `.delivered`, `.state`, `.lock` or `.sha256`. They all live in hidden
  `.mysql-backup` trees, outside the namespace directory. No `*.sql.gz` glob
  can match them.
- Retention, delivery and pruning act only on names that match the strict
  pattern for the configured namespace. Anything else in these directories is
  never touched: legacy backups, symlinks such as `latest.*.sql.gz`, other
  namespaces, and notes.

## Dump pipeline

1. Validate staging (mount point, marker, optional filesystem type). Refuse
   with exit code 6 if validation fails.
2. Take the producer lock, a non-blocking `flock` on local staging. A second
   run (scheduled or manual) exits with code 5 instead of overlapping.
3. Remove `.partial` leftovers from runs that were killed. This is safe
   because we hold the lock.
4. Prune local staging, then run the [capacity check](outage-behavior.md#capacity).
5. Preflight connection with `mysql`, which records the server version.
6. Run `mysqldump … | gzip > work/<name>.<pid>.partial` in its own process
   group. A watchdog aborts the pipeline if free space falls below the
   reserve.
7. Check every stage's exit status (`PIPESTATUS`). With `DUMP_VERIFY=true`,
   decompress the whole file and require mysqldump's `-- Dump completed`
   trailer.
8. `fsync`, record size and SHA-256 in `meta/`, then publish with `ln`. The
   hard link is atomic and fails if the target exists, so nothing is ever
   overwritten. Remove the temporary name and `fsync` the directory.

`SIGTERM`/`SIGINT` (for example `docker stop`) stop the pipeline's process
group, delete the partial file, record `interrupted`, and exit with code 8.
The loop itself exits 0. Nothing half-written is ever published.

### mysqldump options

```text
--single-transaction --quick --skip-lock-tables
--routines --triggers --events
--hex-blob --no-tablespaces --default-character-set=utf8mb4
--set-gtid-purged=OFF
<database>
```

- `--databases` is **not** used. The dump contains no `CREATE DATABASE` or
  `USE` statements, so it can be restored into any database name. That makes
  restores into isolated copies safe by default.
- Oracle's mysqldump writes full definitions for generated columns
  (`GENERATED ALWAYS AS … STORED|VIRTUAL`). It leaves their values out of the
  `INSERT` column lists, so the server recomputes them on restore. This is
  what avoids `ERROR 3105`.
- `--hex-blob` keeps binary data intact. `--set-gtid-purged=OFF` keeps the
  dump restorable into servers with their own GTID history.
  `--no-tablespaces` avoids needing the `PROCESS` privilege.

Minimum privileges (tested):

```sql
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON myapp.* TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';   -- MySQL 8.0.20+, needed for --routines
```

### Consistency

- **InnoDB:** `--single-transaction` gives a consistent snapshot of all
  InnoDB tables without blocking writers.
- **Non-transactional tables** (MyISAM, MEMORY and others) are read without
  a lock, so they may be inconsistent with each other and with InnoDB tables.
- **DDL during a dump:** `ALTER TABLE`, `RENAME TABLE`, `TRUNCATE`, `DROP`
  and `CREATE` on the dumped database can make the dump fail (for example
  "Table definition has changed"). They can also produce a dump that does not
  match any single point in time. Schedule migrations away from dump times, or
  run `mysql-backup dump` straight after a migration. A failed dump is never
  published, and the next scheduled run tries again.
- Users, grants and server variables are not part of the dump.

## Delivery pipeline

The supervisor (`deliver-loop`) reads only local staging to decide whether
anything is pending. It starts at most **one** delivery pass at a time, in a
separate process group with a deadline (`DELIVERY_ATTEMPT_TIMEOUT`). Each pass:

1. Validates staging, then takes the delivery lock on local staging.
2. Returns immediately if nothing is pending, without touching the destination.
3. Validates the destination: mount point, marker, and optionally the
   filesystem type and the exact export source. A writable directory where the
   mount should be is not enough. If validation fails, nothing is written.
4. Removes stale `incoming/*.partial` files from interrupted passes.
5. For each pending dump, oldest first:
   - If a file with the same name already exists at the destination, it is
     read back and compared by SHA-256. If identical, the dump is recorded as
     delivered. This covers a crash after publication but before bookkeeping,
     so retries are idempotent. If it differs, it is a **conflict**: the
     remote file is never replaced, the local copy is kept, and status turns
     CRITICAL.
   - Otherwise the dump is copied to `incoming/<name>.partial` and `fsync`ed.
     The copy is read back (with O_DIRECT where supported), its size and
     SHA-256 are checked, and it is published with `ln` (atomic, no clobber)
     or `mv -n` on filesystems without hard links. The directory is then
     `fsync`ed and a `.sha256` file is written.
   - Only then is `delivered/<base>.delivered` written locally.
6. Prunes local staging.
7. Applies remote retention, but only if every pending dump was delivered
   without errors or conflicts **and** the destination validates again.

## Locking

| Lock | Holder | Purpose |
|---|---|---|
| `producer.lock` | a dump (scheduled or manual) | No overlapping dumps per namespace |
| `delivery.lock` | a delivery pass | No overlapping transfers or remote retention |
| `local-prune.lock` | producer or delivery | Serialises local deletions |

All locks are `flock` locks on files in local staging, never on NFS. The
kernel releases a lock when its holder exits, so stale locks cannot exist.
Child processes inherit the lock on purpose. If the producer is killed with
`SIGKILL` while `mysqldump` keeps running, or a transfer is blocked inside NFS,
the lock stays held until that process ends. This prevents a second dump or
pass from starting next to it.

## Why bash

The runtime is about 1,700 lines of bash (including comments) plus `gawk`, `coreutils` and
`util-linux-core` from Oracle Linux 9. This avoids a second language runtime
in the image.

## Image contents

The image is client-only, about 210 MB unpacked:

- Oracle Linux 9 slim (the distribution the official MySQL image is built
  on), with OS security updates applied at build time.
- `mysqldump` and `mysql` 8.0.37, copied from the official `mysql:8.0.37`
  image pinned by digest. They link only against system libraries (OpenSSL 3,
  libstdc++, zlib, ncurses).
- The scripts under `/opt/mysql-backup`.

There is no MySQL server, MySQL Shell or server plugin, and no `VOLUME`
declaration. Client authentication plugins that are loaded from files
(LDAP SASL, Kerberos, FIDO, OCI) are not included. The built-in
`caching_sha2_password` and `mysql_native_password` methods are, and they are
what the tests use. The behaviour is covered by the tests described in
[testing](testing.md).
