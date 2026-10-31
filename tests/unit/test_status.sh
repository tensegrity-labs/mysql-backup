#!/usr/bin/env bash
. /tests/unit/env.sh

NSD=/staging/$NS

t_fresh_install_is_critical_until_first_backup() {
	reset_dirs
	assert_rc 2 mb -- status
	mb -- dump 2>/dev/null
	assert_rc 0 mb -- status
}

t_status_reports_local_and_delivery_separately() {
	reset_dirs
	mb DELIVERY_ENABLED=true -- dump 2>/dev/null
	local out; out=$(mb DELIVERY_ENABLED=true -- status) || true
	assert_contains "$out" "latest backup"
	assert_contains "$out" "latest delivered   none"
	assert_contains "$out" "pending            1 backup(s)"
	mb DELIVERY_ENABLED=true -- deliver 2>/dev/null
	out=$(mb DELIVERY_ENABLED=true -- status)
	assert_contains "$out" "state=OK"
	assert_contains "$out" "pending            0 backup(s)"
}

t_pending_age_warns() {
	reset_dirs
	mkdir -p "$NSD"
	local now; now=$(date -u +%s)
	fake_backup $((now - 8 * 3600)) >/dev/null
	fake_backup $((now - 60)) >/dev/null
	local out rc=0
	out=$(mb DELIVERY_ENABLED=true STATUS_MAX_PENDING_AGE=6h -- status) || rc=$?
	assert_eq "$rc" 1
	assert_contains "$out" "pending delivery, oldest 8h"
}

t_stale_local_backup_is_critical() {
	reset_dirs
	mkdir -p "$NSD"
	fake_backup $(($(date -u +%s) - 30 * 3600)) >/dev/null
	assert_rc 2 mb STATUS_MAX_LOCAL_AGE=26h -- status
}

t_json_and_prometheus_formats() {
	reset_dirs
	mb DELIVERY_ENABLED=true -- dump 2>/dev/null
	local js prom
	js=$(mb DELIVERY_ENABLED=true -- status --json) || true
	[[ $js == \{*\} ]] || fail "not a JSON object"
	assert_contains "$js" '"state":"OK"'
	assert_contains "$js" '"pending_count":1'
	assert_not_contains "$js" "s3cr3t"
	echo "$js" >/tmp/status.json
	prom=$(mb DELIVERY_ENABLED=true -- status --prometheus) || true
	assert_contains "$prom" 'mysql_backup_pending_count{namespace="t1"} 1'
	assert_contains "$prom" 'mysql_backup_latest_local_timestamp_seconds{namespace="t1"}'
	mb DELIVERY_ENABLED=true STATUS_TEXTFILE=/tmp/mb.prom -- dump 2>/dev/null
	assert_contains "$(cat /tmp/mb.prom)" "mysql_backup_status"
}

t_healthcheck_uses_heartbeat() {
	reset_dirs
	mb -- dump 2>/dev/null
	assert_rc 1 mb -- healthcheck
	date -u +%s >/tmp/hb
	assert_rc 0 mb -- healthcheck producer
	echo $(($(date -u +%s) - 600)) >/tmp/hb
	assert_rc 1 mb -- healthcheck producer
}

t_status_never_touches_destination() {
	reset_dirs
	mb DELIVERY_ENABLED=true -- dump 2>/dev/null
	# make the destination unreadable: status must still answer from staging only
	chmod 000 /destination
	mb DELIVERY_ENABLED=true -- status >/dev/null || true
	local rc=0; mb DELIVERY_ENABLED=true -- status --json >/dev/null || rc=$?
	chmod 755 /destination
	((rc <= 2)) || fail "status failed with $rc"
}

run_tests status
