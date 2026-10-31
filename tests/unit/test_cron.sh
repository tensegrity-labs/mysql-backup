#!/usr/bin/env bash
. /tests/unit/env.sh
load_lib

TZD=America/Denver
m() { cron_matches "$1" "$(local_ts "$2" "${3:-$TZD}")" "${3:-$TZD}"; }

t_validate_accepts_and_rejects() {
	cron_validate '0 6-21 * * *'
	cron_validate '*/15 * * * MON-FRI'
	cron_validate '5 0 1,15 jan,jul 7'
	nok cron_validate '0 6-21 * *'
	nok cron_validate '60 * * * *'
	nok cron_validate '0 22-6 * * *'
	nok cron_validate '*/0 * * * *'
	nok cron_validate '0 * * * * *'
	nok cron_validate '@hourly'
}

t_daytime_schedule_in_denver() {
	m '0 6-21 * * *' '2026-07-15 06:00'
	m '0 6-21 * * *' '2026-07-15 21:00'
	nok m '0 6-21 * * *' '2026-07-15 05:00'
	nok m '0 6-21 * * *' '2026-07-15 22:00'
	nok m '0 6-21 * * *' '2026-07-15 06:01'
	# Same instant is 12:00 UTC; schedule is evaluated in local time.
	cron_matches '0 6 * * *' "$(date -u -d '2026-07-15 12:00' +%s)" "$TZD"
}

t_daytime_schedule_across_dst_changes() {
	m '0 6-21 * * *' '2026-03-08 06:00'   # first day of MDT
	m '0 6-21 * * *' '2026-11-01 06:00'   # first day of MST
	m '0 6-21 * * *' '2026-11-01 21:00'
	nok m '0 6-21 * * *' '2026-11-01 05:00'
}

t_steps_lists_names() {
	m '*/15 * * * *' '2026-07-15 10:45'
	nok m '*/15 * * * *' '2026-07-15 10:50'
	m '10-50/20 * * * *' '2026-07-15 10:30'
	nok m '10-50/20 * * * *' '2026-07-15 10:40'
	m '0 0 * * SUN' '2026-07-19 00:00'      # Sunday
	m '0 0 * * 7' '2026-07-19 00:00'
	m '0 0 * * 0' '2026-07-19 00:00'
	nok m '0 0 * * MON-FRI' '2026-07-19 00:00'
	m '0 0 1 JUL *' '2026-07-01 00:00'
}

t_dom_dow_or_semantics() {
	# both restricted: either matches
	m '0 0 13 * FRI' '2026-07-13 00:00'   # 13th (a Monday)
	m '0 0 13 * FRI' '2026-07-17 00:00'   # a Friday
	nok m '0 0 13 * FRI' '2026-07-14 00:00'
	# only dom restricted
	nok m '0 0 13 * *' '2026-07-17 00:00'
}

run_tests cron
