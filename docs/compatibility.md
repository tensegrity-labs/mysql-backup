# Compatibility

The project's release version (`0.1.0`, semantic versioning) is independent of
the MySQL client version inside the image (`8.0.37`). Every release states
both. The image tag `X.Y.Z-mysqlA.B.C` makes the client version explicit.

## Tested matrix

| mysql-backup | mysqldump client | Server | Result | Platforms tested |
|---|---|---|---|---|
| 0.1.0 | Oracle 8.0.37 (official image `mysql:8.0.37@sha256:598bf8b7…6b8a2b6d0a`) | MySQL 8.0.37 | dump + full restore + object/data comparison pass | linux/amd64, linux/arm64 |

"Tested" means CI ran `tests/integration/restore.sh` on that platform against
that server. That test dumps a schema with stored and virtual generated
columns, JSON, BLOBs, utf8mb4, foreign keys, a view, triggers, a procedure, a
function and an event. It restores the dump into a separate server and
compares objects and data.

Not tested, and therefore **not supported** in this release:

- Other MySQL 8.0.x servers. They are likely to work, because mysqldump 8.0 is
  designed for 8.0 servers. The producer warns, and
  `MYSQL_VERSION_CHECK=strict` refuses them.
- MySQL 8.4 LTS or 9.x servers with this client. A newer server with an
  older client is not a supported combination.
- MariaDB, Percona Server, Aurora and other forks or managed services.

## Platform support

The official `mysql:8.0.37` image index provides `linux/amd64` and
`linux/arm64/v8`. Both were checked with `docker buildx imagetools inspect`.
Releases are built for both, and **each architecture is tested on native
runners before tagging**. Other architectures are not published.

## Age and maintenance of the client

- MySQL 8.0.37 was released in April 2024. The `mysql:8.0.37` image layers
  date from June 2024. The image build applies current Oracle Linux 9 security
  updates to OS packages, but not to MySQL itself.
- **The MySQL 8.0 series reached end of life in April 2026.** 8.0.46 was the
  final release, and Oracle no longer ships fixes for 8.0. Oracle recommends
  8.4 LTS, supported until 2032.

8.0.37 is pinned because it matches the server it protects: a dump client
from the same release as the server is the safest choice for restorability.
It is not pinned because 8.0.37 is current.

## Upgrade path

The client version only changes deliberately, and always in a new release:

1. **Server upgraded within 8.0** (for example to 8.0.46): release
   `0.x.y` with `MYSQL_IMAGE=mysql:8.0.46@sha256:…`, extend the matrix, run
   the restore test against 8.0.46, and publish as `…-mysql8.0.46`.
2. **Server upgraded to 8.4 LTS** (recommended, since 8.0 is end of life):
   release a new **minor** version with an 8.4 client. Its matrix will list
   8.4 servers. Keep using the 8.0.37 release for 8.0 servers until they are
   migrated. Before upgrading production, take a final dump with the 8.0.37
   client and test-restore it into an 8.4 instance.
3. To try a different client locally:

   ```bash
   docker build --build-arg MYSQL_IMAGE=mysql:8.0.46@sha256:<digest> \
                --build-arg MYSQL_CLIENT_VERSION=8.0.46 -t mysql-backup:test .
   IMAGE=mysql-backup:test MYSQL_SERVER_IMAGE=mysql:8.0.46 tests/integration/restore.sh
   ```

The build fails if `MYSQL_CLIENT_VERSION` does not match the client in
`MYSQL_IMAGE`, so a base-image change cannot silently change the client.
