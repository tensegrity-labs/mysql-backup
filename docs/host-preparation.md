# Host preparation

This guide covers the host around the containers: dedicated filesystems,
mount safeguards, sizing, and VM backups. Nothing here is done by the
software. Plan these changes and apply them deliberately. The examples assume
a Linux VM with systemd; adapt the device names.

## Recommended layout

Keep these on separate filesystems:

| Mount | Contents | Why |
|---|---|---|
| `/` | operating system | A full Docker or staging disk cannot take the OS down |
| `/var/lib/docker` | Docker images, containers, volumes, **the MySQL data volume** | Docker growth cannot fill `/` |
| `/srv/backup-staging` | local dumps (staging) | Dumps cannot fill Docker's disk, and Docker cannot fill the dump space |
| `/mnt/mysql-backups` | NFS export for long-term dumps | Off-host copy |

If staging lives on the root filesystem, dumps compete with the OS and Docker
for space. On a root disk that is already close to full, that is a real risk.

### Moving Docker's data root

Moving Docker's data is a maintenance task, not part of this project. In
outline: stop Docker, copy `/var/lib/docker` to the new filesystem (or mount
the new filesystem at `/var/lib/docker`), start Docker and verify. Follow
Docker's documentation for `data-root` in `/etc/docker/daemon.json`, and keep
a VM snapshot from before the change.

## Staging filesystem

```bash
# example only: a new virtual disk /dev/xvdc
mkfs.ext4 -L mb-staging /dev/xvdc
mkdir -p /srv/backup-staging
chattr +i /srv/backup-staging        # empty mount point: nothing can be written into it unmounted
echo 'LABEL=mb-staging /srv/backup-staging ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2' >> /etc/fstab
systemctl daemon-reload && mount /srv/backup-staging
findmnt /srv/backup-staging          # verify: SOURCE is the new device
echo staging > /srv/backup-staging/.mysql-backup-staging
chown 999:999 /srv/backup-staging
```

### Safeguards against writing into the wrong place

| Layer | Safeguard | Enforced by |
|---|---|---|
| Host | `chattr +i` on the empty mount-point directory: when unmounted, writes fail | host |
| Host | `nofail` so a missing disk does not block boot, combined with the checks below | host |
| Host (optional) | systemd drop-in for Docker: `RequiresMountsFor=/srv/backup-staging`, so containers only start once it is mounted | host |
| Compose | `bind.create_host_path: false`, so Docker will not create a stand-in directory | Docker |
| Container | `STAGING_REQUIRE_MOUNTPOINT=true`: refuses if no volume is attached | mysql-backup |
| Container | Marker file `.mysql-backup-staging`, present only on the real filesystem | mysql-backup |
| Container (optional) | `STAGING_EXPECT_FSTYPE=ext4`, `STAGING_MARKER_ID=<unique id>` | mysql-backup |

The container cannot see which host device backs a bind mount. When the host
directory is not mounted, Docker binds the empty underlying directory and the
container sees an ordinary mount point. **The marker file is what detects
this.** It is also why `init-staging` and the marker steps tell you to verify
the mount on the host first. Never create the marker in an unmounted
directory. `chattr +i` makes that impossible.

## NFS destination

```bash
mkdir -p /mnt/mysql-backups
chattr +i /mnt/mysql-backups
# EXAMPLE server address and export (documentation range) - replace them
echo '192.0.2.10:/export/mysql-backups /mnt/mysql-backups nfs4 rw,hard,proto=tcp,vers=4.2,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30s 0 0' >> /etc/fstab
systemctl daemon-reload && mount /mnt/mysql-backups
findmnt /mnt/mysql-backups
echo nfs-backups-1 > /mnt/mysql-backups/.mysql-backup-destination
```

Then set:

```text
DELIVERY_HOST_PATH=/mnt/mysql-backups
DELIVERY_EXPECT_FSTYPE=nfs,nfs4
DELIVERY_EXPECT_SOURCE=192.0.2.10:/export/mysql-backups
DELIVERY_MARKER_ID=nfs-backups-1
```

- The container user (uid 999 by default, or `BACKUP_UID`) needs write access
  on the export. With `root_squash`, root cannot fix permissions from the
  client. Set ownership on the server instead.
- The reference Compose file binds the destination with `rslave` propagation.
  An NFS mount (or automount) that appears after the container started then
  becomes visible inside it. This requires the host path to be on a shared
  mount, which is the default on systemd hosts (`findmnt -o PROPAGATION /`).
  If it is not shared, set `DELIVERY_BIND_PROPAGATION=rprivate` and restart the
  delivery container after the mount comes back.
- Mount option trade-offs (`hard` versus `soft`, timeouts) are explained in
  [outage behaviour](outage-behavior.md#mount-option-trade-offs).
- **Protect the NFS storage itself.** Snapshots or replication on the NAS,
  and a copy elsewhere, are its job. This project only writes to it. A single
  NAS is a single point of failure.

## Sizing staging

The numbers below are an **unverified example**, based on a reported
compressed dump size of 1–2 GB. Measure your own size before sizing a disk.

Measure the compressed size of a real dump:

```bash
docker compose exec backup mysql-backup dump
ls -l --block-size=M /srv/backup-staging/myapp-prod/ | tail -n 3
# or the logged size:
docker compose logs backup | grep 'dump completed' | tail -n 5
```

Without the tool, estimate it with a one-off pipe that writes nothing to disk:

```bash
docker run --rm --network myapp_default -v "$PWD/secrets/mysql_password:/pw:ro" mysql:8.0.37 \
  sh -c 'mysqldump -h db -u backup -p"$(cat /pw)" --single-transaction --routines --triggers --events --hex-blob --no-tablespaces myapp | gzip -6 | wc -c'
```

(This one-off command puts the password on a command line inside a throwaway
container. Use it only for measurement.) `ops/staging-size.sh` performs the
calculation below.

```text
S  = compressed dump size (measured; example: 1.5 GiB)
N  = dumps per day (0 6-21 * * * → 16)
H  = local delivered history (LOCAL_KEEP_DELIVERED=24h → about one day of dumps)
O  = outage you want to survive without losing new recovery points (example: 3 days)
R  = reserve (STAGING_RESERVE / STAGING_RESERVE_PERCENT)
G  = growth headroom for the next dump (S × DUMP_SIZE_GROWTH_PERCENT/100)

staging ≥ S × N × O  +  G  +  R
example:  1.5 × 16 × 3  +  2.25  +  5   ≈ 80 GiB
```

During normal operation, staging holds about H's worth of dumps
(1.5 × 16 ≈ 24 GiB in the example). The rest is the outage buffer. When the
outage exceeds the buffer, new dumps fail and existing ones are kept. Dump
sizes grow with the database, so check them periodically.

## VM backups and staging

- **Docker data belongs in the VM backups.** The MySQL data volume, the
  Compose files and `.env` are what you restore after losing the VM. The
  existing twice-daily VM backups cover them.
- **Staging can be excluded from VM backups.** Most of its contents are
  already on NFS, and it changes hourly, which makes backups larger. The cost:
  **undelivered dumps are lost with the VM**. Usually that only means dumps
  made since the last successful delivery.
- **The NFS export** is outside the VM and needs its own protection, as
  above.

### Xen Orchestra

In Xen Orchestra / XCP-ng, a virtual disk is excluded by putting a tag in the
**VDI name**:

- `[NOBAK]` excludes the disk from backup jobs, together with the snapshots
  those backups take.
- `[NOSNAP]` excludes the disk from ordinary (manual or scheduled) snapshots.

These are different: `[NOBAK]` alone does not keep the disk out of a manual
snapshot. Native disk exclusion in snapshots depends on the XAPI version;
XCP-ng 8.3 is referenced as providing it. Older versions have been reported to
still include `[NOBAK]` disks in manual snapshots. **Verify the behaviour on
your XO and XCP-ng versions before relying on it.**

Sources, checked 2026-10-31: [XO glossary](https://docs.xen-orchestra.com/project/glossary),
[XCP-ng snapshots](https://docs.xcp-ng.org/vms/snapshots/),
[XO 5.96 release notes ([NOSNAP])](https://xen-orchestra.com/blog/xen-orchestra-5-96/),
[XO 5.78 release notes ([NOBAK] in snapshots)](https://xen-orchestra.com/blog/xen-orchestra-5-78/).

Excluding a disk only works if staging is a **separate virtual disk**, which
is another reason for the layout above.

### After restoring the VM

1. Before starting the stack, check the mounts (`findmnt /srv/backup-staging
   /mnt/mysql-backups`). A staging disk excluded from the VM backup comes back
   **missing or empty**. Recreate it as above, including the marker, and the
   producer starts from an empty staging area.
2. If staging was restored from an older backup, it may contain dumps that
   were already delivered, plus stale bookkeeping. This is safe: delivery
   compares checksums and records identical remote files without copying.
3. Start the stack and run `mysql-backup status`. Expect pending dumps to
   deliver and the next scheduled dump to run.
4. If the MySQL data itself was restored to an older point, recover newer
   data from the NFS dumps as described in [recovery](recovery.md).
