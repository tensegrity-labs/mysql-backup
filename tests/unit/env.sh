# shellcheck shell=bash
# Common environment for unit tests. Runs INSIDE the image under test, in a
# container started by tests/run-unit.sh with --network none and tmpfs mounts
# for /staging, /destination and /small. The CLI is always invoked through
# `env -i` with an explicit variable list, so nothing inherited from the
# caller can point a test at a real database, volume or path.

. /tests/lib.sh

MB=/opt/mysql-backup/bin/mysql-backup
FAKEBIN=/tests/fixtures/fakebin
NS=t1
SECRET='s3cr3t-"quote\back'"'"'tick'

# Fail fast if the expected disposable mounts are not present.
for d in /staging /destination /small; do
	mountpoint -q "$d" || { echo "refusing to run: $d is not a disposable test mount" >&2; exit 2; }
done

base_env() {
	printf '%s\n' \
		"PATH=$FAKEBIN:/usr/local/bin:/usr/bin:/bin" "HOME=/tmp" "TMPDIR=/tmp" \
		"MB_HEARTBEAT_FILE=/tmp/hb" "BACKUP_NAMESPACE=$NS" "STAGING_DIR=/staging" \
		"DELIVERY_DIR=/destination" "MYSQL_HOST=fake-db" "MYSQL_DATABASE=appdb" \
		"MYSQL_USER=backup" "MYSQL_PASSWORD=$SECRET" "STAGING_RESERVE=1M" \
		"STAGING_RESERVE_PERCENT=0" "STAGING_FIRST_DUMP_ESTIMATE=64K" \
		"FAKE_ARGV_LOG=/tmp/argv.log" "BACKUP_TZ=America/Denver"
}

# mb [VAR=value ...] -- <args>: run the CLI with a clean environment.
mb() {
	local -a extra=()
	while (($#)) && [[ $1 != -- ]]; do extra+=("$1"); shift; done
	shift
	local -a envv
	mapfile -t envv < <(base_env)
	env -i "${envv[@]}" "${extra[@]}" "$MB" "$@"
}

# mb_bg [VAR=value ...] -- <args>: like mb, in the background. Sets BG to the
# PID of the mysql-backup process itself (env execs it), so signals reach it.
mb_bg() {
	local -a extra=()
	while (($#)) && [[ $1 != -- ]]; do extra+=("$1"); shift; done
	shift
	local -a envv
	mapfile -t envv < <(base_env)
	env -i "${envv[@]}" "${extra[@]}" "$MB" "$@" &
	BG=$!
}

# proc_count <regex>: number of processes whose command line matches (no pgrep in the image)
proc_count() {
	local p n=0
	for p in /proc/[0-9]*; do
		[[ -r $p/cmdline ]] || continue
		tr '\0' ' ' <"$p/cmdline" 2>/dev/null | grep -Eq -- "$1" && n=$((n + 1))
	done
	echo "$n"
}

kill_matching() { # kill_matching <regex>: SIGKILL processes by command line
	local p
	for p in /proc/[0-9]*; do
		[[ -r $p/cmdline ]] || continue
		tr '\0' ' ' <"$p/cmdline" 2>/dev/null | grep -Eq -- "$1" && kill -KILL "${p#/proc/}" 2>/dev/null
	done
	return 0
}

reset_dirs() {
	local d
	for d in /staging /destination /small; do
		find "$d" -mindepth 1 -delete 2>/dev/null || true
	done
	echo "staging" >/staging/.mysql-backup-staging
	echo "staging" >/small/.mysql-backup-staging
	echo "destination" >/destination/.mysql-backup-destination
	rm -f /tmp/argv.log /tmp/hb
}

# Load the library into the current shell (for function-level tests).
load_lib() {
	local -a envv; mapfile -t envv < <(base_env)
	local kv; for kv in "${envv[@]}" "$@"; do export "${kv?}"; done
	MB_ROOT=/opt/mysql-backup
	set +u
	. "$MB_ROOT/lib/common.sh"; . "$MB_ROOT/lib/mounts.sh"; . "$MB_ROOT/lib/cron.sh"
	. "$MB_ROOT/lib/retention.sh"; . "$MB_ROOT/lib/localstore.sh"; . "$MB_ROOT/lib/status.sh"
	. "$MB_ROOT/lib/producer.sh"; . "$MB_ROOT/lib/delivery.sh"
	load_config
}

local_ts() { TZ=${2:-America/Denver} date -d "$1" +%s; }        # local wall time -> epoch
name_at() { printf '%s-%s.sql.gz' "${2:-$NS}" "$(date -u -d "@$1" +%Y%m%dT%H%M%SZ)"; }

# fake_backup <epoch> [dir] [ns]: create a completed-looking backup file
fake_backup() {
	local e=$1 dir=${2:-/staging/$NS} ns=${3:-$NS}
	mkdir -p "$dir"
	printf 'x%.0s' {1..100} | gzip >"$dir/$(name_at "$e" "$ns")"
	printf '%s\n' "$(name_at "$e" "$ns")"
}
