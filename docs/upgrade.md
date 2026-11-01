# Upgrading

## Image tags

| Tag | Moves? | Use |
|---|---|---|
| `0.2.0` | never | Normal pinning |
| `0.2.0-mysql8.0.37` | never | Same image; client version visible in the tag |
| `@sha256:<digest>` | never | **Production pinning**: immune to registry-side changes |
| `0.2` | yes, to the newest `0.2.z` | Patch updates |
| `latest` | yes | Experiments only |

A versioned tag is never moved to different content. The release workflow
refuses to publish if the tag already exists.

Find a release's digest on its GitHub release page, or with:

```bash
docker buildx imagetools inspect ghcr.io/tensegrity-labs/mysql-backup:0.2.0
```

Then pin both the tag and the digest:

```text
MYSQL_BACKUP_IMAGE=ghcr.io/tensegrity-labs/mysql-backup:0.2.0@sha256:<digest>
```

## Verifying provenance

```bash
gh attestation verify oci://ghcr.io/tensegrity-labs/mysql-backup:0.2.0 --owner tensegrity-labs
docker buildx imagetools inspect ghcr.io/tensegrity-labs/mysql-backup:0.2.0 --format '{{json .SBOM}}'
```

## Procedure

1. Read `CHANGELOG.md` and [compatibility](compatibility.md). A change of
   MySQL client is always called out.
2. Change `MYSQL_BACKUP_IMAGE` in `.env`.
3. `docker compose pull && docker compose up -d`. The producer finishes or
   aborts its current dump cleanly on stop; partial files are never
   published.
4. Run `docker compose exec backup mysql-backup dump` and `status`.
5. Test-restore one new dump ([recovery](recovery.md)). Do this especially
   when the MySQL client version changed.

The on-disk format (file names, `.mysql-backup` bookkeeping) is versioned with
the project. Incompatible changes require a new major version and come with
migration notes. To roll back, set the previous tag or digest and redeploy.

## Upgrading the database server

See [compatibility](compatibility.md#upgrade-path). Take and test-restore a
dump **before** the server upgrade, then use a release whose tested matrix
includes the new server version.
