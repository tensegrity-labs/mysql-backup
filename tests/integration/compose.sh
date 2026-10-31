#!/usr/bin/env bash
# Deploys deploy/compose.yaml UNCHANGED against a disposable MySQL 8.0.37 on
# a disposable "existing" network, with host directories standing in for the
# staging filesystem and the NFS mount (bind mounts; this is not an NFS test).
# Verifies: startup dump, automatic delivery, local dumping while the
# destination is unavailable and while the delivery worker is stopped,
# automatic catch-up, status/healthcheck, and that the producer never mounts
# the destination.
. "$(dirname -- "$0")/common.sh"

DC=(docker compose --project-directory "$WORK/project" -f "$ROOT/deploy/compose.yaml" --env-file "$WORK/project/.env")
cleanup_compose() { "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; cleanup; }
trap cleanup_compose EXIT

step "disposable database on an existing network"
net_create
start_mysql db
wait_mysql db
echo "CREATE DATABASE appdb;" | sql db
{ echo "USE appdb;"; cat "$ROOT/tests/fixtures/schema.sql"; } | sql db
sql db <<'SQL'
CREATE USER 'backup'@'%' IDENTIFIED BY 'compose-test-only';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON appdb.* TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
SQL

step "host directories for staging and destination, with markers"
mkdir -p "$WORK/project/secrets" "$WORK/staging" "$WORK/nfs"
printf 'compose-test-only\n' >"$WORK/project/secrets/mysql_password"
chmod 644 "$WORK/project/secrets/mysql_password"
echo "staging" >"$WORK/staging/.mysql-backup-staging"
echo "itest-destination" >"$WORK/nfs/.mysql-backup-destination"
chown -R 999:999 "$WORK/staging" "$WORK/nfs"

sed -e "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=$RUN_ID|" \
	-e "s|^MYSQL_BACKUP_IMAGE=.*|MYSQL_BACKUP_IMAGE=$IMAGE|" \
	-e "s|^BACKUP_NAMESPACE=.*|BACKUP_NAMESPACE=itest-compose|" \
	-e "s|^BACKUP_ON_START=.*|BACKUP_ON_START=true|" \
	-e "s|^MYSQL_NETWORK=.*|MYSQL_NETWORK=$NET|" \
	-e "s|^MYSQL_DATABASE=.*|MYSQL_DATABASE=appdb|" \
	-e "s|^STAGING_HOST_PATH=.*|STAGING_HOST_PATH=$WORK/staging|" \
	-e "s|^STAGING_RESERVE=.*|STAGING_RESERVE=16M|" \
	-e "s|^STAGING_RESERVE_PERCENT=.*|STAGING_RESERVE_PERCENT=0|" \
	-e "s|^DELIVERY_HOST_PATH=.*|DELIVERY_HOST_PATH=$WORK/nfs|" \
	-e "s|^DELIVERY_EXPECT_FSTYPE=.*|DELIVERY_EXPECT_FSTYPE=|" \
	-e "s|^DELIVERY_EXPECT_SOURCE=.*|DELIVERY_EXPECT_SOURCE=|" \
	-e "s|^DELIVERY_MARKER_ID=.*|DELIVERY_MARKER_ID=itest-destination|" \
	-e "s|^DELIVERY_RETRY_INTERVAL=.*|DELIVERY_RETRY_INTERVAL=5s|" \
	"$ROOT/deploy/.env.example" >"$WORK/project/.env"
echo "DELIVERY_POLL_INTERVAL=3s" >>"$WORK/project/.env"
# This sandbox's root mount may not be shared; propagation is a host concern.
if ! findmnt -no PROPAGATION --target "$WORK" | grep -q shared; then
	echo "DELIVERY_BIND_PROPAGATION=rprivate" >>"$WORK/project/.env"
	echo "note: $WORK is not on a shared mount here; using rprivate propagation for this test"
fi

nfs_count() { find "$WORK/nfs/itest-compose" -maxdepth 1 -name 'itest-compose-*.sql.gz' 2>/dev/null | wc -l; }
local_count() { find "$WORK/staging/itest-compose" -maxdepth 1 -name 'itest-compose-*.sql.gz' 2>/dev/null | wc -l; }
nfs_at_least() { (($(nfs_count) >= $1)); }
all_delivered() { (($(nfs_count) == $(local_count))); }
wait_for() { # wait_for <seconds> <command...> (re-evaluated every second)
	local t=$1 i; shift
	for ((i = 0; i < t; i++)); do "$@" && return 0; sleep 1; done
	return 1
}

step "compose up (reference compose.yaml)"
"${DC[@]}" config --quiet
"${DC[@]}" up -d
wait_for 90 nfs_at_least 1 || { "${DC[@]}" logs; die "startup dump was not delivered"; }
pass "startup dump produced and delivered automatically"
"${DC[@]}" exec -T backup mysql-backup status
"${DC[@]}" exec -T backup mysql-backup healthcheck producer
"${DC[@]}" exec -T backup-delivery mysql-backup healthcheck delivery
mounts=$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$("${DC[@]}" ps -q backup)")
[[ $mounts != *"/destination"* ]] || die "producer must not mount the destination"
pass "producer mounts only staging ($mounts)"

step "destination unavailable (marker removed): local dumps continue"
mv "$WORK/nfs/.mysql-backup-destination" "$WORK/nfs/.away"
before=$(nfs_count)
"${DC[@]}" exec -T backup mysql-backup dump
sleep 1
"${DC[@]}" exec -T backup mysql-backup dump
sleep 8
[[ $(nfs_count) == "$before" ]] || die "wrote to an unverified destination"
st=$("${DC[@]}" exec -T backup mysql-backup status --json || true)
echo "$st"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["delivery"]["pending_count"]==2, d' "$st"
pass "two local dumps while destination unavailable; nothing written there; status shows 2 pending"

step "delivery worker stopped entirely: local dumps continue"
"${DC[@]}" stop backup-delivery
"${DC[@]}" exec -T backup mysql-backup dump
pass "dump succeeded with the delivery worker stopped"

step "destination restored and worker started: automatic catch-up"
mv "$WORK/nfs/.away" "$WORK/nfs/.mysql-backup-destination"
"${DC[@]}" start backup-delivery
wait_for 60 all_delivered || { "${DC[@]}" logs backup-delivery; die "catch-up failed"; }
st=$("${DC[@]}" exec -T backup mysql-backup status --json)
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"]=="OK" and d["delivery"]["pending_count"]==0, d' "$st"
for f in "$WORK"/nfs/itest-compose/*.sql.gz; do
	cmp -s "$f" "$WORK/staging/itest-compose/$(basename "$f")" || die "remote copy differs: $f"
done
pass "all $(nfs_count) dumps delivered byte-identical; status OK"

step "manual retry and retention preview commands"
"${DC[@]}" exec -T backup-delivery mysql-backup deliver
"${DC[@]}" exec -T backup-delivery mysql-backup retention-preview --remote
"${DC[@]}" exec -T backup mysql-backup retention-preview --local

step "logs contain no secrets"
"${DC[@]}" logs --no-color >"$WORK/logs.txt" 2>&1
grep -q 'compose-test-only' "$WORK/logs.txt" && die "password found in logs"
pass "no password in container logs"

step "stop: containers exit cleanly on SIGTERM"
"${DC[@]}" stop -t 30
mapfile -t cids < <("${DC[@]}" ps -aq)
codes=$(docker inspect -f "{{.State.ExitCode}}" "${cids[@]}" | sort -u | tr "\n" " ")
[[ $codes == "0 " ]] || die "unexpected exit codes: $codes"
pass "both containers stopped with exit code 0"

echo
echo "COMPOSE TEST PASSED"
