#!/usr/bin/env bash
# Producer behaviour with a fake mysqldump: publication, verification,
# secrets, locking, signals, disabled mode, staging validation, local pruning.
. /tests/unit/env.sh

NSD=/staging/$NS
WORK=/staging/.mysql-backup/$NS/work

only_backups() { find "$NSD" -maxdepth 1 -type f -name "$NS-*.sql.gz" | wc -l; }
no_partials() { [[ -z $(find /staging -name '*.partial') ]] || fail "partial files left: $(find /staging -name '*.partial')"; }

t_dump_publishes_valid_file_atomically() {
	reset_dirs
	mb -- dump 2>/tmp/err
	assert_eq "$(only_backups)" 1
	local f; f=$(ls "$NSD")
	[[ $f =~ ^t1-[0-9]{8}T[0-9]{6}Z\.sql\.gz$ ]] || fail "bad name $f"
	gzip -t "$NSD/$f"
	assert_contains "$(gzip -dc "$NSD/$f" | tail -n1)" "-- Dump completed"
	assert_file "/staging/.mysql-backup/$NS/meta/${f%.sql.gz}.meta"
	no_partials
	# nothing but completed dumps in the namespace directory
	assert_eq "$(ls -A "$NSD" | wc -l)" 1
}

t_secrets_not_in_argv_or_logs() {
	reset_dirs
	mb -- dump 2>/tmp/err
	assert_not_contains "$(cat /tmp/argv.log)" "s3cr3t"
	assert_contains "$(cat /tmp/argv.log)" "--defaults-file="
	assert_not_contains "$(cat /tmp/err)" "s3cr3t"
	assert_contains "$(head -n1 /tmp/argv.log)" "SELECT VERSION()"
	# the private option file is removed afterwards
	[[ -z $(find /tmp -name 'client.cnf' 2>/dev/null) ]] || fail "option file left behind"
	# a password file works the same way
	printf '%s\n' "$SECRET" >/tmp/pw; chmod 600 /tmp/pw
	mb MYSQL_PASSWORD= MYSQL_PASSWORD_FILE=/tmp/pw -- dump 2>/tmp/err
	assert_not_contains "$(cat /tmp/err)" "s3cr3t"
	# both set is a configuration error
	assert_rc 2 mb MYSQL_PASSWORD_FILE=/tmp/pw -- dump
}

t_pipeline_failure_publishes_nothing() {
	reset_dirs
	assert_rc 1 mb FAKE_DUMP_MODE=fail -- dump
	assert_eq "$(only_backups)" 0
	no_partials
	assert_contains "$(cat "/staging/.mysql-backup/$NS/status/producer.state")" "last_result=failed"
}

t_truncated_dump_fails_verification() {
	reset_dirs
	assert_rc 1 mb FAKE_DUMP_MODE=notrailer -- dump
	assert_eq "$(only_backups)" 0
	no_partials
}

t_connection_failure_is_clear() {
	reset_dirs
	assert_rc 1 mb FAKE_CONNECT=fail -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "cannot connect to MySQL"
}

t_untested_server_version_warns_or_fails() {
	reset_dirs
	mb FAKE_SERVER_VERSION=8.4.3 -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "outside the tested range"
	assert_rc 2 mb FAKE_SERVER_VERSION=8.4.3 MYSQL_VERSION_CHECK=strict -- dump
}

t_overlapping_runs_are_refused() {
	reset_dirs
	mb_bg FAKE_DUMP_MODE=slow FAKE_DUMP_SLEEP=8 -- dump 2>/dev/null
	local bg=$BG
	sleep 2
	assert_rc 5 mb -- dump
	kill -TERM "$bg"; wait "$bg" || true
}

t_sigterm_interrupts_cleanly() {
	reset_dirs
	mb_bg FAKE_DUMP_MODE=slow FAKE_DUMP_SLEEP=60 FAKE_PID_FILE=/tmp/fakepid -- dump 2>/tmp/err
	local bg=$BG rc=0
	sleep 2
	assert_file /tmp/fakepid
	ls "$WORK"/*.partial >/dev/null
	kill -TERM "$bg"; wait "$bg" || rc=$?
	assert_eq "$rc" 8 "exit code"
	assert_eq "$(only_backups)" 0
	no_partials
	sleep 1
	nok kill -0 "$(cat /tmp/fakepid)" 2>/dev/null
	assert_contains "$(cat "/staging/.mysql-backup/$NS/status/producer.state")" "last_result=interrupted"
}

t_sigkill_leftovers_are_cleaned_next_run() {
	reset_dirs
	mb_bg FAKE_DUMP_MODE=slow FAKE_DUMP_SLEEP=60 FAKE_PID_FILE=/tmp/fakepid2 -- dump 2>/dev/null
	local bg=$BG
	sleep 2
	kill -KILL "$bg"; wait "$bg" || true
	# The orphaned pipeline inherits the producer lock (so no second dump can
	# start while it still writes). Killing it simulates the container restart
	# that normally follows a SIGKILL.
	kill_matching 'mysql-backup dump|fakebin/mysqldump|sleep 60|gzip -c'
	sleep 1
	[[ -n $(find "$WORK" -name '*.partial') ]] || fail "expected an orphaned partial"
	# the orphan is never a candidate for delivery/retention/restore
	assert_eq "$(only_backups)" 0
	mb -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "removed stale temporary file"
	no_partials
	assert_eq "$(only_backups)" 1
}

t_name_collision_never_overwrites() {
	reset_dirs
	mkdir -p "$NSD"
	local now i
	now=$(date -u +%s)
	for ((i = 0; i < 12; i++)); do echo "precious" >"$NSD/$(name_at $((now + i)))"; done
	assert_rc 1 mb -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "refusing to overwrite"
	for f in "$NSD"/*; do assert_eq "$(cat "$f")" precious; done
	no_partials
}

t_disabled_suppresses_everything() {
	reset_dirs
	assert_rc 3 mb BACKUP_ENABLED=false -- dump
	assert_rc 3 mb BACKUP_ENABLED=false DELIVERY_ENABLED=true -- deliver
	assert_no_file /staging/.mysql-backup
	assert_no_file "$NSD"
	assert_contains "$(mb BACKUP_ENABLED=false -- status)" "DISABLED"
	# the long-running worker idles even with BACKUP_ON_START=true
	mb_bg BACKUP_ENABLED=false BACKUP_ON_START=true -- run 2>/tmp/err
	local bg=$BG
	sleep 3
	kill -TERM "$bg"; wait "$bg" || true
	assert_no_file /staging/.mysql-backup
	assert_eq "$(ls -A /destination)" ".mysql-backup-destination"
	assert_eq "$(cat /tmp/argv.log 2>/dev/null)" ""
}

t_backup_on_start_and_clean_stop() {
	reset_dirs
	mb_bg BACKUP_ON_START=true BACKUP_SCHEDULE='0 0 1 1 *' -- run 2>/tmp/err
	local bg=$BG i
	for i in $(seq 1 20); do (($(only_backups) == 1)) && break; sleep 0.5; done
	assert_eq "$(only_backups)" 1
	kill -TERM "$bg"; wait "$bg"
	assert_contains "$(cat /tmp/err)" "producer stopping"
}

t_staging_validation() {
	reset_dirs
	rm /staging/.mysql-backup-staging
	assert_rc 6 mb -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "marker"
	assert_no_file /staging/.mysql-backup
	echo "other" >/staging/.mysql-backup-staging
	assert_rc 6 mb STAGING_MARKER_ID=expected-id -- dump
	echo "expected-id" >/staging/.mysql-backup-staging
	mb STAGING_MARKER_ID=expected-id -- dump 2>/dev/null
	# not a mount point: a plain directory in the container filesystem
	mkdir -p /tmp/notmounted && echo x >/tmp/notmounted/.mysql-backup-staging
	assert_rc 6 mb STAGING_DIR=/tmp/notmounted -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "not a mount point"
	assert_no_file /tmp/notmounted/$NS
	# wrong filesystem type
	assert_rc 6 mb STAGING_EXPECT_FSTYPE=xfs,ext4 -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "filesystem type is tmpfs"
}

t_local_prune_with_delivery_enabled() {
	reset_dirs
	load_lib DELIVERY_ENABLED=true
	ensure_state_dirs
	local now old1 old2 recent
	now=$(date -u +%s)
	old1=$(fake_backup $((now - 3 * 86400))); old2=$(fake_backup $((now - 2 * 86400)))
	recent=$(fake_backup $((now - 3600)))
	local newest; newest=$(fake_backup $((now - 60)))
	mark_delivered "$old1" "$(sha256_of "$NSD/$old1")" test
	mark_delivered "$recent" "$(sha256_of "$NSD/$recent")" test
	mark_delivered "$newest" "$(sha256_of "$NSD/$newest")" test
	local_prune
	assert_no_file "$NSD/$old1"         # delivered, older than 24h
	assert_file "$NSD/$old2"            # undelivered: never deleted
	assert_file "$NSD/$recent"          # delivered, inside 24h history
	assert_file "$NSD/$newest"
}

t_local_only_tiers_preserve_legacy_and_other_namespaces() {
	reset_dirs
	load_lib DELIVERY_ENABLED=false LOCAL_RETENTION_KEEP_LATEST=1 LOCAL_RETENTION_HOURLY_DAYS=1 \
		LOCAL_RETENTION_DAILY_DAYS=0 LOCAL_RETENTION_WEEKLY_WEEKS=0
	ensure_state_dirs
	local now a b
	now=$(date -u +%s)
	a=$(fake_backup $((now - 10 * 86400))); b=$(fake_backup $((now - 9 * 86400)))
	# legacy files from a previous backup container, and foreign namespaces
	echo legacy >"$NSD/202601010600.appdb.sql.gz"
	ln -s 202601010600.appdb.sql.gz "$NSD/latest.appdb.sql.gz"
	echo note >"$NSD/README.txt"
	mkdir -p "$NSD/old"; echo x >"$NSD/old/$a"
	fake_backup $((now - 10 * 86400)) "$NSD" t2 >/dev/null
	fake_backup $((now - 10 * 86400)) /staging/t2 t2 >/dev/null
	fake_backup $((now - 10 * 86400)) /staging/t1-dev t1-dev >/dev/null
	local_prune
	assert_no_file "$NSD/$a"
	assert_file "$NSD/$b"                       # latest:1
	assert_file "$NSD/202601010600.appdb.sql.gz"
	[[ -L $NSD/latest.appdb.sql.gz ]] || fail "symlink removed"
	assert_file "$NSD/README.txt"
	assert_file "$NSD/old/$a"
	assert_eq "$(ls /staging/t2 | wc -l)" 1
	assert_eq "$(ls /staging/t1-dev | wc -l)" 1
	assert_eq "$(find "$NSD" -maxdepth 1 -name 't2-*' | wc -l)" 1
}

t_retention_preview_deletes_nothing() {
	reset_dirs
	mkdir -p "$NSD"
	local now; now=$(date -u +%s)
	fake_backup $((now - 100 * 86400)) >/dev/null; fake_backup $((now - 90 * 86400)) >/dev/null
	fake_backup $((now - 80 * 86400)) >/dev/null; fake_backup $((now - 70 * 86400)) >/dev/null
	local out; out=$(mb RETENTION_KEEP_LATEST=1 -- retention-preview --local)
	assert_eq "$(grep -c '^delete' <<<"$out")" 3
	assert_eq "$(only_backups)" 4
}

run_tests local
