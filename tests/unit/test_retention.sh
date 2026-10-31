#!/usr/bin/env bash
. /tests/unit/env.sh
load_lib

TZD=America/Denver

# sel <now-local> <latest> <hourly> <daily> <weekly> < "epoch name" lines
sel() { retention_select "$(local_ts "$1")" "$TZD" "$2" "$3" "$4" "$5"; }
gen() { # gen <local datetime>... -> "epoch name" lines
	local d e
	for d in "$@"; do e=$(local_ts "$d"); printf '%s %s\n' "$e" "$(name_at "$e")"; done
}
kept() { awk '$1=="keep"{print $2}'; }
reason_of() { awk -v n="$1" '$2==n{print $3}'; }
n_at() { name_at "$(local_ts "$1")"; }

# Hourly backups 06:00-21:00 local for many days.
gen_schedule() { # gen_schedule <first-day> <days>
	local i h day
	for ((i = 0; i < $2; i++)); do
		day=$(date -d "$1 + $i day" +%F)
		for h in $(seq -w 6 21); do gen "$day $h:00"; done
	done
}

t_example_policy_counts() {
	# 71 days of 06-21 hourly backups ending today (Wed 2026-07-15) 10:00.
	local out
	out=$( { gen_schedule 2026-05-06 71; } | awk -v lim="$(local_ts '2026-07-15 10:00')" '$1<=lim' | sel '2026-07-15 10:00' 3 2 14 8 )
	# hourly: today 06..10 (5) + yesterday 06..21 (16) = 21
	assert_eq "$(grep -c 'hourly' <<<"$out")" 21 "hourly count"
	# daily: one per day for 14 days
	assert_eq "$(grep -c 'daily' <<<"$out")" 14 "daily count"
	# weekly: one per ISO week for 8 weeks
	assert_eq "$(grep -c 'weekly' <<<"$out")" 8 "weekly count"
	# union: 21 hourly + 12 older dailies + weekly picks older than 14 days
	# Weeks (Mon starts): 07-13,07-06,06-29,06-22,06-15,06-08,06-01,05-25.
	# Newest of weeks 07-13..07-06 are inside the daily window (dates >= 07-02);
	# weeks 06-29 (newest 07-05) also in window; the other 5 weeks add 5 files.
	assert_eq "$(kept <<<"$out" | wc -l)" $((21 + 12 + 5)) "total kept"
	# every file appears exactly once
	assert_eq "$(awk '{print $2}' <<<"$out" | sort | uniq -d | wc -l)" 0 "duplicates"
	# daily picks the newest backup of the day
	assert_eq "$(reason_of "$(n_at '2026-07-10 21:00')" <<<"$out")" "daily"
	assert_eq "$(reason_of "$(n_at '2026-07-10 20:00')" <<<"$out")" "-"
}

t_calendar_day_boundary_is_local() {
	local out
	out=$(gen '2026-07-14 00:00:00' '2026-07-13 23:59:59' '2026-07-13 18:00' | sel '2026-07-15 10:00' 1 2 14 8)
	assert_contains "$(reason_of "$(n_at '2026-07-14 00:00:00')" <<<"$out")" hourly
	# 23:59:59 local on 07-13 is 05:59:59 UTC on 07-14, but it belongs to 07-13 locally
	assert_eq "$(reason_of "$(n_at '2026-07-13 23:59:59')" <<<"$out")" daily
	assert_eq "$(reason_of "$(n_at '2026-07-13 18:00')" <<<"$out")" "-"
}

t_week_boundary_monday() {
	local out
	# Sunday 2026-07-12 23:00 and Monday 2026-07-13 00:30 are different ISO weeks
	out=$(gen '2026-07-12 23:00' '2026-07-12 08:00' '2026-07-13 00:30' | sel '2026-07-30 12:00' 1 0 0 8)
	assert_eq "$(reason_of "$(n_at '2026-07-12 23:00')" <<<"$out")" weekly
	assert_eq "$(reason_of "$(n_at '2026-07-13 00:30')" <<<"$out")" "latest,weekly"
	assert_eq "$(reason_of "$(n_at '2026-07-12 08:00')" <<<"$out")" "-"
}

t_dst_fall_back_day_is_one_day() {
	# 2026-11-01 has 25 hours in Denver; 01:30 occurs twice.
	local e1 e2 out
	e1=$(TZ=$TZD date -d '2026-11-01 01:30 MDT' +%s); e2=$(TZ=$TZD date -d '2026-11-01 01:30 MST' +%s)
	out=$( { printf '%s %s\n' "$e1" "$(name_at "$e1")" "$e2" "$(name_at "$e2")"; gen '2026-10-31 23:00'; } |
		sel '2026-11-20 12:00' 1 0 30 0)
	assert_eq "$(reason_of "$(name_at "$e2")" <<<"$out")" "latest,daily"
	assert_eq "$(reason_of "$(name_at "$e1")" <<<"$out")" "-"
	assert_eq "$(reason_of "$(n_at '2026-10-31 23:00')" <<<"$out")" daily
}

t_dst_spring_forward_day() {
	local out
	out=$(gen '2026-03-08 01:30' '2026-03-08 03:30' '2026-03-07 23:30' | sel '2026-03-09 12:00' 1 2 0 0)
	assert_eq "$(kept <<<"$out" | wc -l)" 2 "only 03-08 (yesterday) and 03-09 count as the latest two days"
	assert_eq "$(reason_of "$(n_at '2026-03-07 23:30')" <<<"$out")" "-"
}

t_missing_periods_are_not_backfilled() {
	# Backups exist only on 07-01 and 07-14; window of 7 daily points from 07-15.
	local out
	out=$(gen '2026-07-01 12:00' '2026-07-01 13:00' '2026-07-14 12:00' | sel '2026-07-15 10:00' 1 0 7 0)
	assert_eq "$(kept <<<"$out" | wc -l)" 1 "07-01 is outside the 7-day window and is not promoted"
	assert_eq "$(reason_of "$(n_at '2026-07-14 12:00')" <<<"$out")" "latest,daily"
}

t_keep_latest_survives_long_outage() {
	# Producer down for 100 days: tiers select nothing, latest:3 still keeps 3.
	local out
	out=$(gen '2026-01-01 06:00' '2026-01-01 07:00' '2026-01-01 08:00' '2026-01-01 09:00' | sel '2026-04-15 10:00' 3 2 14 8)
	assert_eq "$(kept <<<"$out" | wc -l)" 3
	assert_eq "$(reason_of "$(n_at '2026-01-01 06:00')" <<<"$out")" "-"
}

t_overlapping_tiers_listed_once() {
	local out
	out=$(gen '2026-07-15 09:00' | sel '2026-07-15 10:00' 3 2 14 8)
	assert_eq "$(wc -l <<<"$out")" 1
	assert_eq "$(reason_of "$(n_at '2026-07-15 09:00')" <<<"$out")" "latest,hourly,daily,weekly"
}

t_future_backups_are_kept() {
	local out
	out=$(gen '2026-07-16 09:00' '2026-07-01 09:00' | sel '2026-07-15 10:00' 1 0 0 0)
	assert_eq "$(reason_of "$(n_at '2026-07-16 09:00')" <<<"$out")" future
	assert_eq "$(reason_of "$(n_at '2026-07-01 09:00')" <<<"$out")" latest
}

t_deterministic() {
	local a b
	a=$(gen_schedule 2026-06-01 20 | sel '2026-06-20 12:00' 3 2 14 8)
	b=$(gen_schedule 2026-06-01 20 | sort -R | sel '2026-06-20 12:00' 3 2 14 8)
	assert_eq "$a" "$b" "input order must not matter"
}

t_strict_name_recognition() {
	mkdir -p /tmp/rt && cd /tmp/rt && rm -f ./*
	touch "t1-20260101T000000Z.sql.gz" "t1-20260101T000000Z.sql.gz.partial" "t10-20260101T000000Z.sql.gz" \
		"t1-20260101T0000Z.sql.gz" "202601010000.appdb.sql.gz" "latest.appdb.sql.gz" "t1-20260101T000000Z.sql"
	ln -s t1-20260101T000000Z.sql.gz t1-20260102T000000Z.sql.gz
	assert_eq "$(list_backups /tmp/rt)" "t1-20260101T000000Z.sql.gz"
}

run_tests retention
