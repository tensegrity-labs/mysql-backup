#!/usr/bin/env bash
# Delivery to a tmpfs "destination" mount. These tests exercise the delivery
# logic and failure handling; they are NOT tests against a real NFS server
# (see tests/integration/nfs.sh for that).
. /tests/unit/env.sh

NSD=/staging/$NS
RNS=/destination/$NS
dl() { mb DELIVERY_ENABLED=true "$@"; }
dl_bg() { mb_bg DELIVERY_ENABLED=true "$@"; }
remote_count() { find "$RNS" -maxdepth 1 -type f -name "$NS-*.sql.gz" 2>/dev/null | wc -l; }
pending() { dl -- status --json | sed -n 's/.*"pending_count":\([0-9]*\).*/\1/p'; }

t_deliver_verifies_and_publishes() {
	reset_dirs
	dl -- dump 2>/dev/null
	local f; f=$(ls "$NSD")
	dl -- deliver 2>/tmp/err
	assert_file "$RNS/$f"
	assert_eq "$(sha256sum <"$RNS/$f")" "$(sha256sum <"$NSD/$f")"
	assert_file "/destination/.mysql-backup/$NS/checksums/$f.sha256"
	(cd "$RNS" && sha256sum -c "/destination/.mysql-backup/$NS/checksums/$f.sha256" >/dev/null)
	assert_file "/staging/.mysql-backup/$NS/delivered/${f%.sql.gz}.delivered"
	assert_eq "$(find /destination -name '*.partial' | wc -l)" 0
	assert_eq "$(ls -A "$RNS")" "$f" "destination namespace dir holds only dumps"
	assert_eq "$(pending)" 0
}

t_missing_destination_marker_writes_nothing() {
	reset_dirs
	dl -- dump 2>/dev/null
	rm /destination/.mysql-backup-destination
	assert_rc 6 dl -- deliver 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "destination unavailable"
	assert_eq "$(ls -A /destination)" "" "nothing may be written to an unverified destination"
	assert_eq "$(pending)" 1
	# wrong identity / filesystem type / source are refused too
	echo other >/destination/.mysql-backup-destination
	assert_rc 6 dl DELIVERY_MARKER_ID=nfs-backups-1 -- deliver
	assert_rc 6 dl DELIVERY_EXPECT_FSTYPE=nfs,nfs4 -- deliver
	assert_rc 6 dl DELIVERY_EXPECT_SOURCE=192.0.2.10:/export/backups -- deliver
	assert_eq "$(ls -A /destination)" ".mysql-backup-destination"
}

t_destination_must_be_a_mount() {
	reset_dirs
	dl -- dump 2>/dev/null
	mkdir -p /tmp/fake-nfs && echo x >/tmp/fake-nfs/.mysql-backup-destination
	assert_rc 6 dl DELIVERY_DIR=/tmp/fake-nfs -- deliver 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "not a mount point"
}

t_local_dumps_continue_while_destination_unavailable() {
	reset_dirs
	rm /destination/.mysql-backup-destination
	local i
	for i in 1 2 3; do dl -- dump 2>/dev/null; sleep 1; done
	assert_rc 6 dl -- deliver 2>/dev/null
	assert_eq "$(ls "$NSD" | wc -l)" 3
	assert_eq "$(pending)" 3
	echo restored >/destination/.mysql-backup-destination
	dl -- deliver 2>/dev/null
	assert_eq "$(remote_count)" 3
	assert_eq "$(pending)" 0
}

t_retry_after_publish_before_bookkeeping_is_idempotent() {
	reset_dirs
	dl -- dump 2>/dev/null
	local f; f=$(ls "$NSD")
	dl -- deliver 2>/dev/null
	local ino; ino=$(stat -c '%i %Y' "$RNS/$f")
	# Simulate a crash after remote publication but before the local record.
	rm "/staging/.mysql-backup/$NS/delivered/${f%.sql.gz}.delivered"
	assert_eq "$(pending)" 1
	dl -- deliver 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "already present at destination and verified"
	assert_eq "$(stat -c '%i %Y' "$RNS/$f")" "$ino" "remote file must not be rewritten"
	assert_eq "$(pending)" 0
}

t_different_existing_remote_file_is_never_replaced() {
	reset_dirs
	dl -- dump 2>/dev/null
	local f; f=$(ls "$NSD")
	mkdir -p "$RNS"; echo "someone else's backup" >"$RNS/$f"
	assert_rc 7 dl -- deliver 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "CONFLICT"
	assert_eq "$(cat "$RNS/$f")" "someone else's backup"
	assert_file "$NSD/$f"
	assert_eq "$(pending)" 1
	local st; st=$(dl -- status) || true
	assert_contains "$st" "conflict"
}

t_incomplete_remote_transfers_are_cleaned_and_never_listed() {
	reset_dirs
	dl -- dump 2>/dev/null
	local f; f=$(ls "$NSD")
	mkdir -p "/destination/.mysql-backup/$NS/incoming"
	head -c 100 "$NSD/$f" >"/destination/.mysql-backup/$NS/incoming/$f.partial"
	dl -- deliver 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "removed incomplete remote transfer"
	assert_eq "$(find /destination -name '*.partial' | wc -l)" 0
	assert_eq "$(sha256sum <"$RNS/$f")" "$(sha256sum <"$NSD/$f")"
}

t_remote_retention_only_after_successful_delivery() {
	reset_dirs
	mkdir -p "$RNS" /destination/t2
	local now old legacy foreign
	now=$(date -u +%s)
	old=$(fake_backup $((now - 200 * 86400)) "$RNS")
	fake_backup $((now - 199 * 86400)) "$RNS" >/dev/null
	legacy="$RNS/202501010600.appdb.sql.gz"; echo legacy >"$legacy"
	foreign=$(fake_backup $((now - 200 * 86400)) /destination/t2 t2)
	# 1) a conflicting pass must not run retention
	dl -- dump 2>/dev/null
	local f; f=$(ls "$NSD")
	echo different >"$RNS/$f"
	assert_rc 7 dl RETENTION_KEEP_LATEST=1 -- deliver 2>/dev/null
	assert_file "$RNS/$old"
	# 2) after a clean pass, the remote policy is applied
	rm "$RNS/$f"
	dl RETENTION_KEEP_LATEST=1 -- deliver 2>/tmp/err
	assert_no_file "$RNS/$old"
	assert_file "$RNS/$f"
	assert_file "$legacy"
	assert_file "/destination/t2/$foreign"
	# preview reports and deletes nothing
	fake_backup $((now - 300 * 86400)) "$RNS" >/dev/null
	local c; c=$(remote_count)
	assert_contains "$(dl RETENTION_KEEP_LATEST=1 -- retention-preview --remote)" "delete"
	assert_eq "$(remote_count)" "$c"
}

t_local_and_remote_retention_are_independent() {
	reset_dirs
	dl -- dump 2>/dev/null
	dl LOCAL_KEEP_DELIVERED=0 LOCAL_KEEP_LATEST=0 -- deliver 2>/dev/null
	# local copy pruned right away (history 0), remote copy remains
	assert_eq "$(ls "$NSD" | wc -l)" 0
	assert_eq "$(remote_count)" 1
	# status still knows the latest local and delivered backups
	local js; js=$(dl -- status --json) || true
	assert_contains "$js" '"latest_delivered_file":"t1-'
}

t_delivery_loop_retries_automatically() {
	reset_dirs
	rm /destination/.mysql-backup-destination
	dl -- dump 2>/dev/null
	dl_bg DELIVERY_POLL_INTERVAL=1 DELIVERY_RETRY_INTERVAL=2 -- deliver-loop 2>/tmp/err
	local bg=$BG i
	sleep 4
	assert_eq "$(remote_count)" 0
	echo back >/destination/.mysql-backup-destination
	for i in $(seq 1 20); do (($(remote_count) == 1)) && break; sleep 1; done
	assert_eq "$(remote_count)" 1
	kill -TERM "$bg"; wait "$bg"
	assert_contains "$(cat /tmp/err)" "destination unavailable"
}

# SIMULATED hang (fake cp sleeping), not a real NFS outage: the supervisor
# must enforce its deadline, never run overlapping passes, and recover.
t_simulated_hung_transfer_is_bounded() {
	reset_dirs
	dl -- dump 2>/dev/null
	rm -f /tmp/cp-pids
	dl_bg FAKE_CP_BLOCK=1 FAKE_PID_FILE=/tmp/cp-pids DELIVERY_POLL_INTERVAL=1 DELIVERY_RETRY_INTERVAL=1 \
		DELIVERY_ATTEMPT_TIMEOUT=3 -- deliver-loop 2>/tmp/err
	local bg=$BG i max=0 n
	for i in $(seq 1 12); do
		n=$(proc_count 'mysql-backup deliver $')
		((n > max)) && max=$n
		sleep 1
	done
	assert_eq "$max" 1 "at most one delivery pass at a time"
	assert_contains "$(cat /tmp/err)" "exceeded 3s"
	assert_contains "$(cat "/staging/.mysql-backup/$NS/status/delivery.state")" "timed out"
	# the producer is unaffected meanwhile
	dl -- dump 2>/dev/null
	kill -TERM "$bg"; wait "$bg"
	sleep 1; assert_eq "$(proc_count '^sleep 3600')" 0 "hung helpers are cleaned up"
}

run_tests delivery
