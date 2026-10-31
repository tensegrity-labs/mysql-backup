# Retention

Retention decides which **completed dumps** to keep. It never touches files
that do not match the namespace's strict file-name pattern (see
[architecture](architecture.md#on-disk-layout)). Legacy backups, other
namespaces, symlinks and temporary files are always preserved.

Local staging and the remote destination have **independent** policies.

## Tiered policy (remote; also local when delivery is disabled)

Each tier selects a set of dumps. A dump is kept if **any** tier selects it.
Each dump is stored once, however many tiers select it.

| Tier | Variable | Selects |
|---|---|---|
| latest | `RETENTION_KEEP_LATEST` (default 3, minimum 1) | The N newest dumps, regardless of age |
| hourly | `RETENTION_HOURLY_DAYS` (default 2) | **Every** dump whose local calendar date is one of the D most recent calendar days, counting today |
| daily | `RETENTION_DAILY_DAYS` (default 14) | The **newest** dump of each of the D most recent calendar days |
| weekly | `RETENTION_WEEKLY_WEEKS` (default 8) | The **newest** dump of each of the W most recent ISO weeks (Monday–Sunday), counting the current week |

The example policy is: all scheduled recovery points for the latest two
calendar days, one per day for 14 days, and one per week for eight weeks.

### Rules that make selection deterministic

- **Time zone.** The dump time comes from the UTC timestamp in the file name.
  It is converted to `BACKUP_TZ` to find its local calendar day and ISO week.
  A dump made at 23:30 local time belongs to that local day, even though in
  UTC it is already the next day.
- **"Now"** is the time the policy is evaluated. "Most recent D days" means
  today and the D−1 days before it, by local calendar date. With
  `RETENTION_HOURLY_DAYS=2`, everything from yesterday 00:00 local onwards is
  kept.
- **DST.** Days are calendar days, so a 23-hour or 25-hour day is still one
  day. A time that occurs twice at fall-back belongs to the same day, and
  "newest" means the later instant.
- **Newest** means the latest timestamp; ties are broken by file name.
- **Missing periods are not filled.** A day or week with no dump simply has
  no recovery point in that tier. Older dumps are **not** promoted to fill
  the gap, so the set of kept dumps does not jump around after an outage.
- **Producer outages.** If no dumps are made for weeks, the calendar tiers
  eventually select nothing. The `latest` tier guarantees the newest N always
  survive, so a long outage cannot empty the store.
- **Clock skew.** Dumps dated in the future are always kept and reported as
  `future`.
- The result does not depend on listing order. This is tested by shuffling
  the input.

### Worked example

Schedule `0 6-21 * * *` in `America/Denver` (16 dumps a day), evaluated on
Wednesday 2026-07-15 at 10:00 local time:

| Tier | Kept |
|---|---|
| hourly (2 days) | 5 from today (06:00–10:00) + 16 from yesterday = 21 |
| daily (14 days) | the 21:00 dump of each of 07-02 … 07-14, plus today's newest (already kept) |
| weekly (8 weeks) | the newest dump of each ISO week; the 5 weeks older than the daily window add 5 dumps |
| **Total** | **38 files** (21 + 12 + 5) |

This exact case is a unit test (`tests/unit/test_retention.sh`).

### When remote retention runs

Remote retention runs only after a delivery pass that delivered at least one
dump, had no errors or conflicts, and re-validated the destination. A failing
or unverified destination is never pruned.

Preview the remote policy without deleting anything:

```bash
docker compose exec backup-delivery mysql-backup retention-preview --remote
```

## Local staging policy

When delivery is **enabled** (`DELIVERY_ENABLED=true`):

- **Undelivered** dumps are never deleted by retention or by capacity
  reclamation.
- **Delivered** dumps are kept for `LOCAL_KEEP_DELIVERED` (default `24h`,
  measured from the dump time), then deleted. This gives quick local restores
  and development copies of recent points.
- The newest `LOCAL_KEEP_LATEST` (default 1) dumps are always kept.
- Under capacity pressure, delivered dumps are reclaimed oldest first,
  **before** the reserve is used. See [outage behaviour](outage-behavior.md).

When delivery is **disabled**, staging is the only store and the
`LOCAL_RETENTION_*` tiers apply. They default to the `RETENTION_*` values.
Capacity reclamation never deletes anything in this mode: if space runs out,
new dumps fail.

Preview the local policy:

```bash
docker compose exec backup mysql-backup retention-preview --local
```

## Separate environments

Production and development must use different `BACKUP_NAMESPACE` values. Each
namespace has its own directory, file-name prefix, locks, status and
bookkeeping. Pruning in one namespace cannot select a file from another,
because both the directory and the file-name prefix must match. This holds
even if both use the same staging filesystem and NFS export. For example,
`myapp-dev` can keep a short local-only history while `myapp-prod` keeps the
full tiered policy on NFS.
