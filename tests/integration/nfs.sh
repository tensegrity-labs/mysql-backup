#!/usr/bin/env bash
# REAL NFS validation. Configures a kernel NFS server on loopback, mounts it on
# the host and runs the image under test against it, including a real server
# outage under a hard mount.
#
# It changes host NFS configuration, so it only runs on a disposable CI
# machine: it requires root, CI=true and MBTEST_ALLOW_HOST_NFS=1.
. "$(dirname -- "$0")/common.sh"

[[ ${CI:-} == true && ${MBTEST_ALLOW_HOST_NFS:-} == 1 && $(id -u) == 0 ]] || {
	echo "refusing: needs root on a disposable CI host (CI=true MBTEST_ALLOW_HOST_NFS=1)" >&2
	exit 2
}

EXPORT=/srv/$RUN_ID-export
MNT=$WORK/nfs          # host mount point (bind source for the delivery container)
STG=$WORK/staging
NS=itest-nfs

nfs_cleanup() {
	systemctl start nfs-server >/dev/null 2>&1 || true
	umount -f -l "$MNT" >/dev/null 2>&1 || true
	exportfs -u "127.0.0.1:$EXPORT" >/dev/null 2>&1 || true
	rm -rf -- "$EXPORT"
	cleanup
}
trap nfs_cleanup EXIT

step "kernel NFS server on loopback"
if ! command -v exportfs >/dev/null; then
	apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-kernel-server >/dev/null
fi
systemctl start nfs-server
mkdir -p "$EXPORT" "$MNT" "$STG"
chown 999:999 "$EXPORT" "$STG"
exportfs -o rw,sync,no_subtree_check "127.0.0.1:$EXPORT"
echo "staging" >"$STG/.mysql-backup-staging"

step "database and producer"
net_create
start_mysql db
wait_mysql db
echo "CREATE DATABASE appdb;" | sql db
{ echo "USE appdb;"; cat "$ROOT/tests/fixtures/schema.sql"; } | sql db
sql db <<'SQL'
CREATE USER 'backup'@'%' IDENTIFIED BY 'nfs-test-only';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON appdb.* TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
SQL
penv=(-e "BACKUP_NAMESPACE=$NS" -e MYSQL_HOST=db -e MYSQL_DATABASE=appdb -e MYSQL_USER=backup
	-e MYSQL_PASSWORD=nfs-test-only -e DELIVERY_ENABLED=true -e STAGING_RESERVE=16M
	-e STAGING_RESERVE_PERCENT=0 -v "$STG:/staging")
dump() { mb "${penv[@]}" -- dump; }
denv=(-e "BACKUP_NAMESPACE=$NS" -e DELIVERY_ENABLED=true -e "DELIVERY_EXPECT_FSTYPE=nfs,nfs4"
	-e "DELIVERY_EXPECT_SOURCE=127.0.0.1:$EXPORT" -e DELIVERY_MARKER_ID=nfs-itest
	-e DELIVERY_VERIFY_READ=direct -v "$STG:/staging")
remote_count() { timeout 10 find "$MNT/$NS" -maxdepth 1 -name "$NS-*.sql.gz" 2>/dev/null | wc -l; }
pending() { mb -e "BACKUP_NAMESPACE=$NS" -e DELIVERY_ENABLED=true -v "$STG:/staging:ro" -- status --json |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["delivery"]["pending_count"])' || true; }

step "export NOT mounted: the underlying directory is writable but must be refused"
dump
rc=0; mb "${denv[@]}" -v "$MNT:/destination" -- deliver || rc=$?
[[ $rc == 6 ]] || die "expected exit 6 for an unmounted destination, got $rc"
[[ -z $(ls -A "$MNT") ]] || die "something was written beneath the absent mount"
pass "delivery refused; nothing written to the underlying directory"

step "mount appears AFTER the delivery worker started (rslave propagation)"
prop=rprivate
if findmnt -no PROPAGATION --target "$MNT" | grep -q shared; then prop=rslave; fi
docker run -d --name "$RUN_ID-delivery" "${LABEL[@]}" --init --network none \
	"${denv[@]}" -e DELIVERY_POLL_INTERVAL=2s -e DELIVERY_RETRY_INTERVAL=3s \
	-e DELIVERY_ATTEMPT_TIMEOUT=20s --mount "type=bind,src=$MNT,dst=/destination,bind-propagation=$prop" \
	"$IMAGE" deliver-loop >/dev/null
sleep 5
mount -t nfs4 -o vers=4.2,hard,timeo=50,retrans=2,proto=tcp "127.0.0.1:$EXPORT" "$MNT"
echo "nfs-itest" >"$MNT/.mysql-backup-destination"
findmnt "$MNT"
if [[ $prop == rslave ]]; then
	for i in $(seq 1 30); do (($(remote_count) >= 1)) && break; sleep 1; done
	(($(remote_count) >= 1)) || { docker logs "$RUN_ID-delivery"; die "late mount not picked up"; }
	pass "late NFS mount became visible through rslave propagation and the pending dump was delivered"
else
	echo "SKIP: $MNT is not on a shared mount on this host; restarting the worker instead"
	docker restart "$RUN_ID-delivery" >/dev/null
	for i in $(seq 1 30); do (($(remote_count) >= 1)) && break; sleep 1; done
fi

step "delivered file verified on NFS (fstype, source, marker, O_DIRECT read-back)"
f=$(ls "$STG/$NS" | tail -n1)
cmp "$STG/$NS/$f" "$MNT/$NS/$f" || die "NFS copy differs"
(cd "$MNT/$NS" && sha256sum -c "../.mysql-backup/$NS/checksums/$f.sha256")
[[ -z $(find "$MNT" -name '*.partial') ]] || die "partial left on NFS"
pass "byte-identical, checksum file valid, no partial files"

step "REAL outage: NFS server stopped while hard-mounted"
systemctl stop nfs-server
t0=$(date +%s)
for i in 1 2 3; do dump; sleep 1; done
t1=$(date +%s)
pass "3 local dumps completed in $((t1 - t0))s while the NFS server was down"
[[ $(pending) -ge 3 ]] || die "expected at least 3 pending"
# Let the worker attempt delivery, hit its deadline and report.
sleep 45
st=$(mb -e "BACKUP_NAMESPACE=$NS" -e DELIVERY_ENABLED=true -v "$STG:/staging:ro" -- status || true)
echo "$st"
n=$(docker exec "$RUN_ID-delivery" sh -c 'for p in /proc/[0-9]*; do tr "\0" " " <$p/cmdline 2>/dev/null; echo; done' | grep -c 'mysql-backup deliver $' || true)
echo "delivery pass processes inside the worker: $n"
((n <= 1)) || die "overlapping delivery passes: $n"
docker logs "$RUN_ID-delivery" 2>&1 | tail -n 15
docker logs "$RUN_ID-delivery" 2>&1 | grep -Eq 'exceeded|stalled|unavailable|failed' ||
	die "worker did not report the outage"
pass "status answered during the outage; at most one delivery pass; outage reported"

step "NFS server restored: automatic recovery"
systemctl start nfs-server
for i in $(seq 1 180); do [[ $(pending) == 0 ]] && break; sleep 2; done
[[ $(pending) == 0 ]] || { docker logs "$RUN_ID-delivery" | tail -30; die "did not recover"; }
for f in "$STG/$NS"/*.sql.gz; do cmp "$f" "$MNT/$NS/$(basename "$f")" || die "differs: $f"; done
pass "all pending dumps delivered after recovery ($(remote_count) on NFS)"

echo
echo "REAL NFS TEST PASSED (loopback kernel NFS server, NFSv4.2 hard mount)"
