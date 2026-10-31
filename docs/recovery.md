# Recovery

Dumps are plain `mysqldump` output compressed with gzip. Restoring one needs
only `gunzip` and the `mysql` client. Neither this project nor its image is
required.

> **Restore into an isolated destination first.** Never restore over the
> production database to "undo" a mistake. Restore into a separate database or,
> better, a separate MySQL instance. Compare, then repair production
> selectively.

## 1. Pick a dump

Completed dumps are the only `*.sql.gz` files in the namespace directory.
Names carry the UTC time:

```bash
ls -1 /srv/backup-staging/myapp-prod/        # recent points (local staging)
ls -1 /mnt/mysql-backups/myapp-prod/         # long-term points (NFS)
```

For the NFS copy, verify the checksum first:

```bash
cd /mnt/mysql-backups/myapp-prod
sha256sum -c ../.mysql-backup/myapp-prod/checksums/myapp-prod-20260715T130001Z.sql.gz.sha256
gzip -t myapp-prod-20260715T130001Z.sql.gz
```

To find the dump just before an incident, convert the local time to UTC. For
example, 07:15 MDT is 13:15Z, so choose `…T130001Z`.

## 2. Start a disposable recovery instance

Use the same MySQL version as production (8.0.37). Do not publish its port,
and keep its data on a tmpfs or a throwaway volume:

```bash
docker network create recovery-net
docker run -d --name mysql-recovery --network recovery-net \
  --tmpfs /var/lib/mysql:rw,size=8g \
  -e MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" \
  mysql:8.0.37
docker exec mysql-recovery sh -c 'until mysqladmin ping -uroot -p"$MYSQL_ROOT_PASSWORD" --silent; do sleep 2; done'
```

## 3. Restore

The dump has no `CREATE DATABASE` or `USE` statements, so you choose the
target database:

```bash
docker exec mysql-recovery sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE recovered"'
gunzip -c myapp-prod-20260715T130001Z.sql.gz |
  docker exec -i mysql-recovery sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" recovered'
```

- Views, triggers and routines keep their original `DEFINER`. Restoring as
  root works. If you restore as another account and the definer user does not
  exist, create it first, or expect warnings when those objects run.
- Events are restored with their original status. If the instance runs with
  `--event-scheduler=ON`, enabled events start firing. Keep the scheduler off
  in recovery instances unless you need it.
- Restore time is roughly the original data-load time. Large dumps can take
  much longer than they took to create.

## 4. Clerical-error recovery (the usual case)

Most restores are for a mistake rather than a lost server: a record deleted or
overwritten by a person or a buggy deploy. The safe pattern is:

1. Restore the last dump from **before** the mistake into a recovery instance,
   as above.
2. Find the affected rows in both places and compare them:

   ```sql
   -- in the recovery instance
   SELECT * FROM recovered.orders WHERE customer_id = 1234;
   ```

   Comparing `CHECKSUM TABLE` or `SELECT … ORDER BY pk` output helps when the
   scope is unclear.
3. Decide what to repair. Rows changed **after** the dump was taken are only
   in production; they must not be overwritten with older values.
4. Build targeted statements, and review them with someone else. Export the
   rows with `mysqldump --no-create-info --where=…` or `SELECT … INTO` from
   the recovery instance, then run explicit `INSERT`/`UPDATE` statements in
   production inside a transaction.
5. Remove the recovery instance:

   ```bash
   docker rm -f mysql-recovery && docker network rm recovery-net
   ```

Dumps are logical snapshots at points in time. Changes made between the last
dump and the incident cannot be recovered from them; binary-log recovery is
out of scope for this project.

## Full restore of a lost database

If the database itself is lost, restore the newest good dump into a fresh
instance (or an emptied database) as above. Then point the application at it.
Recreate users and grants separately; they are not part of a single-database
dump.

## Development copies

Restoring a production dump into a development environment copies production
data. Follow your organisation's data-handling rules. The development
namespace's own dumps (`myapp-dev`) are separate files and never mix with
production files.
