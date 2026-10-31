#!/usr/bin/env bash
# Capacity safeguards against a real, small (8 MiB) tmpfs at /small.
. /tests/unit/env.sh

NSD=/small/$NS
cap() { mb STAGING_DIR=/small STAGING_RESERVE=2M "$@"; }
count() { find "$NSD" -maxdepth 1 -type f -name "$NS-*.sql.gz" | wc -l; }
fill_undelivered() { # create N undelivered 1 MiB backups
	local i now; now=$(date -u +%s); mkdir -p "$NSD"
	for ((i = $1; i > 0; i--)); do head -c 1M /dev/urandom >"$NSD/$(name_at $((now - i * 3600)))"; done
}

t_refuses_when_reserve_would_be_consumed_and_preserves_undelivered() {
	reset_dirs
	fill_undelivered 5
	local before; before=$(sha256sum "$NSD"/* | sort)
	assert_rc 4 cap DELIVERY_ENABLED=true STAGING_FIRST_DUMP_ESTIMATE=1M -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "insufficient staging capacity"
	assert_eq "$(sha256sum "$NSD"/* | sort)" "$before" "undelivered backups must be untouched"
	local st; st=$(cap DELIVERY_ENABLED=true -- status) || true
	assert_contains "$st" "CRITICAL"
	assert_contains "$st" "capacity"
	assert_rc 2 cap DELIVERY_ENABLED=true -- status
}

t_reclaims_delivered_before_failing() {
	reset_dirs
	fill_undelivered 5
	load_lib STAGING_DIR=/small DELIVERY_ENABLED=true
	ensure_state_dirs
	local f oldest; oldest=$(ls "$NSD" | head -n1)
	for f in $(ls "$NSD" | head -n 3); do mark_delivered "$f" "$(sha256_of "$NSD/$f")" test; done
	cap DELIVERY_ENABLED=true STAGING_FIRST_DUMP_ESTIMATE=1M FAKE_DUMP_BYTES=100000 -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "capacity reclamation"
	assert_no_file "$NSD/$oldest"
	# the two undelivered remain
	assert_eq "$(for f in "$NSD"/*; do [[ -f /small/.mysql-backup/$NS/delivered/$(basename "${f%.sql.gz}").delivered ]] || echo u; done | wc -l)" 3 "2 old undelivered + new dump"
}

t_local_only_mode_never_deletes_to_make_room() {
	reset_dirs
	fill_undelivered 5
	assert_rc 4 cap DELIVERY_ENABLED=false STAGING_FIRST_DUMP_ESTIMATE=1M -- dump
	assert_eq "$(count)" 5
}

t_watchdog_aborts_dump_larger_than_estimate() {
	reset_dirs
	# estimate 64K, actual output ~8 MiB of incompressible-ish base64 > free space - reserve
	assert_rc 4 cap STAGING_FIRST_DUMP_ESTIMATE=64K FAKE_DUMP_BYTES=9000000 -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "reserve"
	assert_eq "$(count)" 0
	[[ -z $(find /small -name '*.partial') ]] || fail "partial left"
	# room again for a normal dump afterwards
	cap STAGING_FIRST_DUMP_ESTIMATE=64K -- dump 2>/dev/null
	assert_eq "$(count)" 1
}

t_pending_queue_limits() {
	reset_dirs
	mkdir -p "$NSD"
	local now; now=$(date -u +%s)
	fake_backup $((now - 7200)) "$NSD" >/dev/null; fake_backup $((now - 3600)) "$NSD" >/dev/null
	assert_rc 4 cap DELIVERY_ENABLED=true STAGING_MAX_PENDING_COUNT=2 -- dump 2>/tmp/err
	assert_contains "$(cat /tmp/err)" "pending queue full"
	assert_rc 4 cap DELIVERY_ENABLED=true STAGING_MAX_PENDING_BYTES=50 -- dump
	cap DELIVERY_ENABLED=true STAGING_MAX_PENDING_COUNT=3 -- dump 2>/dev/null
	assert_eq "$(count)" 3
}

run_tests capacity
