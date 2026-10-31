# Migrating from a count-based cron backup container

This guide covers the common setup where one container runs `mysqldump` (often
the MariaDB client, as in `fradelg/mysql-cron-backup`-style images) from cron,
writes to a single directory, and keeps the last *N* files.

Why migrate:

- **Restorability.** A MariaDB dump client can emit statements that MySQL 8
  rejects. A typical failure is `ERROR 3105 (HY000): The value specified for
  generated column '…' in table '…' is not allowed`, for tables with generated
  columns. Oracle's mysqldump omits generated values and restores cleanly.
  This is covered by the restore test.
- **Retention by time, not by count.** "Keep 30 files" means different things
  at 16 dumps a day and at 1 dump a day, and it shrinks after an outage. Tiers
  keep predictable recovery points.
- **Separation.** Network storage problems cannot stop local dumps, and no
  file is deleted just because a quota was reached.

## Example: hourly daytime dumps in Denver

Old service (illustrative):

```yaml
  backup:
    image: fradelg/mysql-cron-backup
    environment:
      MYSQL_HOST: db
      MYSQL_USER: root
      MYSQL_PASS: ${DB_ROOT_PASSWORD}
      CRON_TIME: "0 * * * *"
      MAX_BACKUPS: 48
      GZIP_LEVEL: 6
    volumes:
      - ./backups:/backup
```

New configuration (`.env`):

```text
COMPOSE_PROJECT_NAME=myapp-backup-prod
BACKUP_NAMESPACE=myapp-prod
BACKUP_TZ=America/Denver
BACKUP_SCHEDULE=0 6-21 * * *
MYSQL_NETWORK=myapp_default
MYSQL_HOST=db
MYSQL_DATABASE=myapp
MYSQL_USER=backup
STAGING_HOST_PATH=/srv/backup-staging
DELIVERY_HOST_PATH=/mnt/mysql-backups
DELIVERY_EXPECT_SOURCE=192.0.2.10:/export/mysql-backups
RETENTION_HOURLY_DAYS=2
RETENTION_DAILY_DAYS=14
RETENTION_WEEKLY_WEEKS=8
LOCAL_KEEP_DELIVERED=24h
STATUS_MAX_LOCAL_AGE=26h
```

`0 6-21 * * *` runs **every day, on the hour, from 06:00 through 21:00 local
time inclusive**: 16 dumps a day, none between 21:00 and 06:00. The overnight
gap is 9 hours, so status thresholds must be longer than that. `26h` raises
an alert only if a whole day's dumps are missing. Use `10h` if you want an
alert the morning after a missed evening.

The `192.0.2.10` address is a documentation placeholder; use your NFS
server's address.

For a development environment that uses the same Compose definition, use a
different namespace and project name:

```text
COMPOSE_PROJECT_NAME=myapp-backup-dev
BACKUP_NAMESPACE=myapp-dev
DELIVERY_ENABLED=false          # with compose.local-only.yaml
LOCAL_RETENTION_HOURLY_DAYS=1
LOCAL_RETENTION_DAILY_DAYS=3
LOCAL_RETENTION_WEEKLY_WEEKS=0
```

## Steps

1. **Create a least-privilege account.** Do not reuse root:

   ```sql
   CREATE USER 'backup'@'%' IDENTIFIED BY '…';
   GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON myapp.* TO 'backup'@'%';
   GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
   ```

2. **Prepare the filesystems** ([host preparation](host-preparation.md)). Use
   a **new** staging directory. Do not point `STAGING_HOST_PATH` at the old
   backup directory. A shared directory would work, because legacy files are
   never touched, but keeping them apart makes the cut-over easier to follow.
3. **Deploy alongside the old container.** Both can run at the same time. Take
   a manual dump and **test a restore** into a recovery instance
   ([recovery](recovery.md)):

   ```bash
   docker compose exec backup mysql-backup dump
   docker compose exec backup mysql-backup status
   ```

4. **Remove the old backup service** once you are satisfied. Leave its files
   where they are.
5. **Keep the legacy files** until the new tiers cover the same history
   (8 weeks with the example policy). The new tool never deletes them, even in
   a shared directory, because they do not match the namespace's file-name
   pattern. Delete or archive them by hand when you no longer need them.
6. **Monitoring.** Add `status` or the Prometheus textfile to your monitoring
   ([monitoring](monitoring.md)).

## Differences to expect

| Old | New |
|---|---|
| One container | Producer + delivery worker (same image) |
| `MAX_BACKUPS` count | Calendar tiers in `BACKUP_TZ` plus `latest:N` |
| Deletes the oldest file when over the count | Never deletes undelivered dumps; fails new dumps when staging is full |
| Often `latest.<db>.sql.gz` symlink | No symlink. Pick the newest `*.sql.gz` by name or mtime; both agree. |
| `<timestamp>.<db>.sql.gz` | `<namespace>-YYYYMMDDTHHMMSSZ.sql.gz` (UTC) |
| Root credentials common | Least-privilege account, secret file |
| May dump with `--databases` (includes `CREATE DATABASE`/`USE`) | No `CREATE DATABASE`/`USE`; you choose the target on restore |

Restore scripts written for the old layout usually only need the directory
and the newest `*.sql.gz`. If a script relies on `CREATE DATABASE`/`USE`
inside the dump, or on a `latest.*` symlink, adjust it to create or choose the
target database explicitly.
