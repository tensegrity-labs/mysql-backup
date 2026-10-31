# mysql-backup

Scheduled **Oracle MySQL logical dumps** for Docker Compose deployments.
Dumps are written to local staging first. An optional, separate worker then
copies them to an NFS share, verifies each copy, and publishes it.

- Uses Oracle's own `mysqldump` (**8.0.37**) from the official `mysql` image.
  It does not use the MariaDB dump client, which produces dumps that MySQL
  rejects for some generated columns (`ERROR 3105`).
- One database per producer. Output is a gzip-compressed SQL file that you can
  restore with plain `mysql`, without this project.
- A local dump never waits for the network share. If NFS is missing, hung or
  full, dumps continue locally for as long as staging has space.
- Tiered, time-zone-aware retention (hourly, daily and weekly tiers plus "keep
  latest N"). Strict capacity safeguards: undelivered dumps are never deleted
  to make room.
- `status` command and a Prometheus textfile that report local health and
  delivery health separately. The process exit codes are usable by any
  monitoring system.
- No privileged containers, no Docker socket and no published database port.

It is deliberately narrow. It does **not** do binary-log or point-in-time
recovery, physical backups, other database engines, cloud storage, or provide
a web UI.

## Quick start

```bash
git clone https://github.com/tensegrity-labs/mysql-backup && cd mysql-backup/deploy
cp .env.example .env            # then edit: namespace, database, paths, schedule
mkdir -p secrets && install -m 600 /dev/null secrets/mysql_password
printf '%s\n' 'the-backup-password' > secrets/mysql_password
```

Create a least-privilege account on the server:

```sql
CREATE USER 'backup'@'%' IDENTIFIED BY '...';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON myapp.* TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
```

Prepare staging on the host (a dedicated filesystem; see
[host preparation](docs/host-preparation.md)), then mark it **after** you
have verified that it is mounted:

```bash
findmnt /srv/backup-staging                 # must show the dedicated filesystem
echo staging | sudo tee /srv/backup-staging/.mysql-backup-staging
sudo chown 999:999 /srv/backup-staging      # or set BACKUP_UID/BACKUP_GID
```

Start the stack. Use `compose.local-only.yaml` if you have no NFS share:

```bash
docker compose up -d
docker compose exec backup mysql-backup dump      # take one now
docker compose exec backup mysql-backup status
```

The [reference Compose file](deploy/compose.yaml) uses no manager-specific
features, so it can also be deployed as a stack in Arcane or Portainer.

## Supported versions

| Image tag | MySQL client | Tested against servers | Platforms |
|---|---|---|---|
| `0.1.0` | Oracle `mysqldump` 8.0.37 | MySQL 8.0.37 | linux/amd64, linux/arm64 |

Other MySQL 8.0.x servers are expected to work but are **not tested**. The
producer warns about any server outside 8.0.x; set
`MYSQL_VERSION_CHECK=strict` to refuse instead. MySQL 8.0 reached end of life
in April 2026. See [compatibility](docs/compatibility.md) for the support
matrix and the upgrade path. The project's version (`0.1.0`) is independent of
the MySQL client version (`8.0.37`).

## Images

```text
ghcr.io/tensegrity-labs/mysql-backup:0.1.0                 # immutable release
ghcr.io/tensegrity-labs/mysql-backup:0.1.0-mysql8.0.37     # same image, client version explicit
ghcr.io/tensegrity-labs/mysql-backup@sha256:<digest>       # pin this in production
```

Each release is built once, tested on both architectures by digest, and only
then tagged. See [upgrade](docs/upgrade.md) and [releasing](docs/releasing.md).

## Commands

| Command | Purpose |
|---|---|
| `run` | Producer: scheduled local dumps (container default) |
| `deliver-loop` | Delivery worker: automatic delivery and retries |
| `dump` | One dump now (same lock and safeguards as scheduled runs) |
| `deliver` | One delivery pass now |
| `retention-preview --local\|--remote` | Show what would be kept or deleted; deletes nothing |
| `status [--json\|--prometheus]` | Health (0 OK, 1 WARNING, 2 CRITICAL) |
| `init-staging`, `init-destination` | Write the filesystem marker after you verified the mount |
| `check-config` | Print the effective configuration (no secrets) |

Exit codes: 0 ok, 1 failure, 2 configuration, 3 disabled, 4 capacity or queue
full, 5 busy, 6 staging or destination unavailable, 7 destination conflict,
8 interrupted.

## Documentation

- [Configuration reference](docs/configuration.md)
- [Architecture](docs/architecture.md): components, on-disk layout,
  atomicity, locking
- [Retention](docs/retention.md): tiers, calendar rules, local versus remote
- [Outages and capacity](docs/outage-behavior.md): what happens when NFS or
  disk space fails
- [Status and monitoring](docs/monitoring.md)
- [Recovery](docs/recovery.md): restoring into an isolated instance; repairing
  clerical errors
- [Host preparation](docs/host-preparation.md): dedicated filesystems, mount
  safeguards, sizing, VM backups
- [Migrating from a count-based cron backup container](docs/migration.md)
- [Compatibility and upgrades](docs/compatibility.md), [upgrade](docs/upgrade.md)
- [Registries (GHCR and Docker Hub)](docs/registries.md), [releasing](docs/releasing.md)
- [Testing](docs/testing.md)

## Limitations

- InnoDB tables get a consistent snapshot (`--single-transaction`). MyISAM and
  other non-transactional tables do not. Concurrent DDL (`ALTER`, `RENAME`,
  `TRUNCATE`, `DROP`) during a dump can make it fail or be inconsistent. See
  [architecture](docs/architecture.md#consistency).
- How long the system rides out an outage is limited by staging capacity. When
  staging is full, new dumps fail loudly and existing ones are kept.
- Users, grants and other server-level objects are not included. The dump
  covers one database's schema, data, views, triggers, routines and events.
- The NFS destination needs its own backup and protection policy. This tool
  only puts files there.

## License

The source in this repository is [MIT](LICENSE) © 2026 Tensegrity Labs. The
container image also contains MySQL (GPL-2.0 with the Universal FOSS Exception)
and Oracle Linux packages under their own licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
