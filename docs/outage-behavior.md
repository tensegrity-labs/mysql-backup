# Outages and capacity

The design rule: **a problem with remote delivery must never stop local
dumps, and nothing is ever silently deleted to make room.** How long the
system can ride out an outage is limited by the free space on staging.

## Capacity

Before every dump the producer works through these steps:

1. **Prune** local staging according to its policy (see
   [retention](retention.md#local-staging-policy)).
2. **Check queue limits.** If `STAGING_MAX_PENDING_COUNT` or
   `STAGING_MAX_PENDING_BYTES` would be exceeded, the dump fails with exit
   code 4 (`pending queue full`).
3. **Estimate** the next dump: the largest of the last five dumps ×
   `DUMP_SIZE_GROWTH_PERCENT` (default 150 %). Before the first dump, the
   estimate is `STAGING_FIRST_DUMP_ESTIMATE`.
4. **Compute the reserve**: the larger of `STAGING_RESERVE` and
   `STAGING_RESERVE_PERCENT` of the filesystem. Dumps never use this space.
5. If available space is less than estimate + reserve, **reclaim delivered
   dumps**, oldest first, until it fits. Reclaiming ignores the 24-hour local
   history, because those dumps already exist on the destination. Undelivered
   dumps are never reclaimed. With delivery disabled, nothing is reclaimed.
6. If space is still short, the dump fails with exit code 4. Every completed
   dump stays where it is. The status becomes **CRITICAL** with a message
   like:

   ```text
   insufficient staging capacity: 1.0GiB available, need 1.8GiB estimated dump
   + 2.0GiB reserve; 37 undelivered backups (48.1GiB) are preserved - restore
   delivery, free space, or enlarge staging
   ```

During the dump, a watchdog checks free space every second. It stops the
pipeline if free space falls below the reserve, for example when the database
suddenly grew. The partial file is then deleted and the failure is recorded
as a capacity failure. Because the check polls, a very fast burst can briefly
dip into the reserve before the pipeline is stopped. Size the reserve with
that in mind.

### Outage tolerance

```text
tolerated outage ≈ (staging size − reserve − LOCAL_KEEP_DELIVERED history)
                   ÷ (compressed dump size × dumps per day)
```

For example, with a 100 GiB staging filesystem, a 5 GiB reserve, 16 dumps a
day and a 1.2 GiB compressed dump:

```text
(100 − 5) GiB ÷ (1.2 GiB × 16/day) ≈ 4.9 days
```

Once delivery stops, the delivered history is reclaimed automatically, so it
does not reduce the tolerance much. After the tolerated time, **new dumps
fail** while the existing ones are kept. Recent recovery points stop
accumulating, and status is CRITICAL well before that point. See
[host preparation](host-preparation.md#sizing-staging) for measuring real
dump sizes.

If you would rather keep making new dumps and lose old undelivered ones, that
is a manual decision. Delete files yourself after checking `status`; the
software will not do it.

## Staging filesystem missing

If the dedicated staging filesystem is not mounted, Docker can still bind the
**empty underlying directory** on the root filesystem. The producer refuses
to write there, because the marker file `.mysql-backup-staging` only exists on
the real filesystem. With `STAGING_REQUIRE_MOUNTPOINT=true`, a missing volume
in the container is refused as well. Exit code 6 is returned, and status is
CRITICAL (`staging: ... marker ... is missing`).

The reference Compose file also sets `create_host_path: false`, so Docker will
not create a stand-in directory if the path does not exist at all. Host-side
safeguards are described in [host preparation](host-preparation.md).

## Destination unavailable at start or later

| Situation | What happens |
|---|---|
| NFS not mounted when the worker starts | The marker is missing in the underlying directory, so the pass is refused and nothing is written. The worker keeps running and retries every `DELIVERY_RETRY_INTERVAL`. With `rslave` bind propagation, a mount that appears later becomes visible without a restart. |
| Export unreachable when mounting (host side) | The host's `nofail`/automount options keep the boot going (see [host preparation](host-preparation.md)), and the worker behaves as in the row above. |
| Wrong export mounted | Refused if `DELIVERY_MARKER_ID` or `DELIVERY_EXPECT_SOURCE` does not match. |
| Destination full or read-only | The copy or publication fails, the partial file is removed, the dump stays pending, and the pass is retried later. |
| Delivery container stopped or crash-looping | No effect on the producer. The queue grows and status shows the pending count and age. |

In all of these cases local dumps continue, and pending dumps are delivered
automatically, oldest first, once the destination validates again.

## Unresponsive NFS

An NFS server that disappears **after** the mount was made is the hardest
case. With a `hard` mount (the Linux default), I/O on the mount blocks until
the server returns. A blocked process sits in uninterruptible sleep (state
`D`), and **no signal, not even `SIGKILL`, and no shell `timeout` can end
it.** This project does not pretend otherwise:

- The delivery pass runs in its own process group. The supervisor never
  touches the destination itself, so it stays responsive.
- After `DELIVERY_ATTEMPT_TIMEOUT` the supervisor sends `SIGTERM`, and
  `SIGKILL` 30 seconds later. If the pass still has not exited, the
  supervisor records `stalled_since` and status becomes CRITICAL
  (`delivery stalled since …`).
- The blocked pass holds the delivery lock, so **no second pass starts**. A
  blocked process cannot accumulate copies of itself, and manual `deliver`
  runs exit with code 5.
- `status` and `healthcheck` read only local staging, so they keep answering.
- The producer runs in a different container that does not mount the
  destination, so its dumps are unaffected. This was tested with a real NFS
  server stopped under a hard mount; see [testing](testing.md).
- Observed in the real-NFS CI test (Ubuntu 24.04 runner, NFSv4.2 hard mount,
  server stopped): passes blocked in `D` state were ended at the deadline,
  because modern kernels let *fatal* signals interrupt most NFS waits
  (`TASK_KILLABLE`). A new pass started only after the previous one was gone,
  and the 3 local dumps taken during the outage completed in about 4 s. The
  `stalled` path covers operations or kernels where the wait is not killable.
- When the server returns, the blocked I/O completes or fails. The pass then
  exits, the stall clears, and pending dumps are delivered.

### Mount option trade-offs

| Option | Effect | Recommendation |
|---|---|---|
| `hard` (default) | I/O blocks until the server returns; no silent data loss | **Use.** The isolation above contains the blocking. |
| `soft` | I/O fails with `EIO` after `timeo × retrans`; can **silently truncate or corrupt writes** | Not recommended. Verification would catch a bad copy, but soft mounts risk corrupting other data on the same mount. |
| `softerr` (kernel ≥ 5.6) | Like `soft`, but returns `ETIMEDOUT` | Same caution as `soft`. |
| `timeo`, `retrans` | How quickly a hard mount logs "server not responding" | Defaults are fine. |
| `nofail`, `_netdev` | The host boots even if the export is unavailable | **Use.** |
| `x-systemd.automount` | Mounts on first access; retries later | Optional. Pairs well with `rslave` propagation. |
| `intr` | Ignored by modern kernels | No effect. |

Choosing `soft` only to shorten timeouts trades a visible stall for possible
silent corruption. The stall is contained, visible and recovers by itself;
silent corruption does not.

## Interruptions

| Event | Result |
|---|---|
| `docker stop` during a dump | Pipeline stopped, partial file deleted, nothing published, exit 8 (dump) / 0 (loop) |
| `SIGKILL` or host crash during a dump | A `.partial` file remains under `.mysql-backup/<ns>/work/`. It never matches `*.sql.gz` and is removed by the next dump. |
| Stop during delivery | Remote `.partial` removed on the next pass. The dump stays pending. |
| Crash after remote publication, before the local record | Next pass finds an identical remote file, verifies it by checksum, and records it as delivered |
| Two dumps triggered at once | The second exits with code 5 (lock busy) |
| Scheduled time arrives while a dump is still running | Skipped and logged; never run in parallel |

## Restoring the VM from a snapshot or backup

After restoring the VM, staging may be out of date or empty, depending on
whether it was included in the VM backup. See
[host preparation](host-preparation.md#after-restoring-the-vm). In every
case, delivery bookkeeping is reconciled automatically:

- Local dumps that already exist identically on NFS are re-recorded as
  delivered without copying.
- Local dumps that are missing from NFS are delivered.
- A dump with the same name but different content is a conflict and is never
  overwritten.
