# shellcheck shell=bash
# Shared helpers: logging, configuration, sizes, durations, key=value state
# files, and locking. Sourced by every command; never executed directly.

# ---------------------------------------------------------------- exit codes
readonly EX_OK=0
readonly EX_FAIL=1          # generic failure (dump/transfer error)
readonly EX_CONFIG=2        # invalid configuration or usage
readonly EX_DISABLED=3      # BACKUP_ENABLED=false: nothing was done
readonly EX_CAPACITY=4      # not enough safe staging capacity / queue full
readonly EX_BUSY=5          # another run holds the lock
readonly EX_UNAVAILABLE=6   # staging or destination failed validation
readonly EX_CONFLICT=7      # a different file already exists at the destination
readonly EX_INTERRUPTED=8   # stopped by a signal

MB_VERSION="${MB_VERSION:-$(cat "${MB_ROOT}/VERSION" 2>/dev/null || echo unknown)}"

# ------------------------------------------------------------------- logging
# Logs go to stderr, one line each, with an ISO-8601 UTC timestamp. Nothing in
# this project ever logs credentials: passwords are only written into a
# private option file (see producer.sh) and never placed in argv or messages.
_mb_log() {
	local level=$1; shift
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '%s %-5s [%s%s] %s\n' "$ts" "$level" "${MB_ROLE:-cli}" \
		"${BACKUP_NAMESPACE:+/$BACKUP_NAMESPACE}" "$*" >&2
}
log_debug() { [[ "${LOG_LEVEL:-info}" == debug ]] && _mb_log DEBUG "$@"; return 0; }
log_info()  { _mb_log INFO "$@"; }
log_warn()  { _mb_log WARN "$@"; }
log_error() { _mb_log ERROR "$@"; }

die() { # die <exit-code> <message>
	local code=$1; shift
	log_error "$*"
	exit "$code"
}

# --------------------------------------------------------------- conversions
is_true() {
	case "${1,,}" in
		1|true|yes|on) return 0 ;;
		0|false|no|off|'') return 1 ;;
		*) die "$EX_CONFIG" "invalid boolean value: '$1'" ;;
	esac
}

# parse_size 2G -> bytes. Binary units (K=1024).
parse_size() {
	local v=${1^^}
	[[ $v =~ ^([0-9]+)([KMGT]?)I?B?$ ]] || return 1
	local n=${BASH_REMATCH[1]} u=${BASH_REMATCH[2]}
	case $u in
		K) n=$((n * 1024)) ;;
		M) n=$((n * 1024 ** 2)) ;;
		G) n=$((n * 1024 ** 3)) ;;
		T) n=$((n * 1024 ** 4)) ;;
	esac
	printf '%s\n' "$n"
}

# parse_duration 90m -> seconds. Plain numbers are seconds.
parse_duration() {
	local v=${1,,}
	[[ $v =~ ^([0-9]+)([smhdw]?)$ ]] || return 1
	local n=${BASH_REMATCH[1]}
	case ${BASH_REMATCH[2]} in
		m) n=$((n * 60)) ;;
		h) n=$((n * 3600)) ;;
		d) n=$((n * 86400)) ;;
		w) n=$((n * 604800)) ;;
	esac
	printf '%s\n' "$n"
}

human_bytes() {
	numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"
}

human_age() {
	local s=${1:-}
	[[ -z $s ]] && { printf 'never'; return; }
	if ((s < 120)); then printf '%ss' "$s"
	elif ((s < 7200)); then printf '%sm' $((s / 60))
	elif ((s < 172800)); then printf '%sh%02dm' $((s / 3600)) $(((s % 3600) / 60))
	else printf '%sd%02dh' $((s / 86400)) $(((s % 86400) / 3600)); fi
}

now_epoch() { date -u +%s; }

# ------------------------------------------------------------- configuration
# Secrets may be supplied as VAR or VAR_FILE (Docker/Compose secrets). Setting
# both is a configuration error. The value is returned on stdout.
read_secret() {
	local name=$1 file_var="${1}_FILE"
	local direct=${!name:-} file=${!file_var:-}
	if [[ -n $direct && -n $file ]]; then
		die "$EX_CONFIG" "set only one of $name and $file_var"
	fi
	if [[ -n $file ]]; then
		[[ -r $file ]] || die "$EX_CONFIG" "$file_var points to an unreadable file"
		local v
		v=$(<"$file")
		v=${v%$'\n'}; v=${v%$'\r'}
		[[ $v == *$'\n'* ]] && die "$EX_CONFIG" "$file_var must contain a single line"
		printf '%s' "$v"
	else
		printf '%s' "$direct"
	fi
}

_cfg_size() { # _cfg_size VAR default
	local n=$1 d=$2 v
	v=${!n:-$d}
	parse_size "$v" >/dev/null || die "$EX_CONFIG" "$n: invalid size '$v' (use e.g. 512M, 2G)"
	printf -v "$n" '%s' "$(parse_size "$v")"
}
_cfg_duration() {
	local n=$1 d=$2 v
	v=${!n:-$d}
	parse_duration "$v" >/dev/null || die "$EX_CONFIG" "$n: invalid duration '$v' (use e.g. 90s, 30m, 26h, 2d)"
	printf -v "$n" '%s' "$(parse_duration "$v")"
}
_cfg_int() {
	local n=$1 d=$2 v
	v=${!n:-$d}
	[[ $v =~ ^[0-9]+$ ]] || die "$EX_CONFIG" "$n: expected a non-negative integer, got '$v'"
	printf -v "$n" '%s' "$v"
}
_cfg_bool() {
	local n=$1 d=$2 v
	v=${!n:-$d}
	if is_true "$v"; then printf -v "$n" true; else printf -v "$n" false; fi
}

# load_config: validate and normalise every setting once, so later code can
# rely on plain values. Required database settings are checked lazily by the
# producer only, because the delivery worker never connects to MySQL.
load_config() {
	_cfg_bool BACKUP_ENABLED true
	BACKUP_NAMESPACE=${BACKUP_NAMESPACE:-}
	[[ -n $BACKUP_NAMESPACE ]] || die "$EX_CONFIG" "BACKUP_NAMESPACE is required (e.g. myapp-prod)"
	[[ $BACKUP_NAMESPACE =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] ||
		die "$EX_CONFIG" "BACKUP_NAMESPACE must match ^[a-z0-9][a-z0-9._-]{0,62}$"

	BACKUP_TZ=${BACKUP_TZ:-${TZ:-UTC}}
	[[ -f /usr/share/zoneinfo/$BACKUP_TZ || $BACKUP_TZ == UTC ]] ||
		die "$EX_CONFIG" "BACKUP_TZ: unknown time zone '$BACKUP_TZ'"
	BACKUP_SCHEDULE=${BACKUP_SCHEDULE:-0 * * * *}
	_cfg_bool BACKUP_ON_START false

	STAGING_DIR=${STAGING_DIR:-/staging}
	STAGING_DIR=${STAGING_DIR%/}
	_cfg_bool STAGING_REQUIRE_MOUNTPOINT true
	STAGING_MARKER_ID=${STAGING_MARKER_ID:-}
	STAGING_EXPECT_FSTYPE=${STAGING_EXPECT_FSTYPE:-}
	_cfg_size STAGING_RESERVE 2G
	_cfg_int STAGING_RESERVE_PERCENT 5
	_cfg_size STAGING_FIRST_DUMP_ESTIMATE 1G
	_cfg_int DUMP_SIZE_GROWTH_PERCENT 150
	_cfg_int STAGING_MAX_PENDING_COUNT 0
	_cfg_size STAGING_MAX_PENDING_BYTES 0
	_cfg_duration LOCAL_KEEP_DELIVERED 24h
	_cfg_int LOCAL_KEEP_LATEST 1

	_cfg_int RETENTION_HOURLY_DAYS 2
	_cfg_int RETENTION_DAILY_DAYS 14
	_cfg_int RETENTION_WEEKLY_WEEKS 8
	_cfg_int RETENTION_KEEP_LATEST 3
	_cfg_int LOCAL_RETENTION_HOURLY_DAYS "$RETENTION_HOURLY_DAYS"
	_cfg_int LOCAL_RETENTION_DAILY_DAYS "$RETENTION_DAILY_DAYS"
	_cfg_int LOCAL_RETENTION_WEEKLY_WEEKS "$RETENTION_WEEKLY_WEEKS"
	_cfg_int LOCAL_RETENTION_KEEP_LATEST "$RETENTION_KEEP_LATEST"
	((RETENTION_KEEP_LATEST >= 1)) || die "$EX_CONFIG" "RETENTION_KEEP_LATEST must be at least 1"
	((LOCAL_RETENTION_KEEP_LATEST >= 1)) || die "$EX_CONFIG" "LOCAL_RETENTION_KEEP_LATEST must be at least 1"

	_cfg_bool DELIVERY_ENABLED false
	DELIVERY_DIR=${DELIVERY_DIR:-/destination}
	DELIVERY_DIR=${DELIVERY_DIR%/}
	_cfg_bool DELIVERY_REQUIRE_MOUNTPOINT true
	DELIVERY_MARKER_ID=${DELIVERY_MARKER_ID:-}
	DELIVERY_EXPECT_FSTYPE=${DELIVERY_EXPECT_FSTYPE:-}
	DELIVERY_EXPECT_SOURCE=${DELIVERY_EXPECT_SOURCE:-}
	_cfg_duration DELIVERY_POLL_INTERVAL 60s
	_cfg_duration DELIVERY_RETRY_INTERVAL 5m
	_cfg_duration DELIVERY_ATTEMPT_TIMEOUT 2h
	DELIVERY_VERIFY_READ=${DELIVERY_VERIFY_READ:-auto}
	[[ $DELIVERY_VERIFY_READ =~ ^(auto|direct|cached)$ ]] ||
		die "$EX_CONFIG" "DELIVERY_VERIFY_READ must be auto, direct or cached"
	_cfg_bool REMOTE_RETENTION_ENABLED true

	_cfg_duration STATUS_MAX_LOCAL_AGE 26h
	_cfg_duration STATUS_MAX_DELIVERED_AGE 26h
	_cfg_duration STATUS_MAX_PENDING_AGE 6h
	STATUS_TEXTFILE=${STATUS_TEXTFILE:-}

	LOG_LEVEL=${LOG_LEVEL:-info}

	# Derived layout (see docs/architecture.md#on-disk-layout).
	MB_NS_DIR="$STAGING_DIR/$BACKUP_NAMESPACE"
	MB_STATE_ROOT="$STAGING_DIR/.mysql-backup/$BACKUP_NAMESPACE"
	MB_WORK_DIR="$MB_STATE_ROOT/work"
	MB_META_DIR="$MB_STATE_ROOT/meta"
	MB_DELIVERED_DIR="$MB_STATE_ROOT/delivered"
	MB_STATUS_DIR="$MB_STATE_ROOT/status"
	MB_LOCK_DIR="$MB_STATE_ROOT/locks"
	MB_REMOTE_NS_DIR="$DELIVERY_DIR/$BACKUP_NAMESPACE"
	MB_REMOTE_STATE="$DELIVERY_DIR/.mysql-backup/$BACKUP_NAMESPACE"

	export TZ=UTC # internal timestamps are UTC; BACKUP_TZ is applied explicitly
}

# ------------------------------------------------------------ backup naming
# Completed dumps are the ONLY files named <namespace>-YYYYMMDDTHHMMSSZ.sql.gz.
# Temporary files end in .partial and bookkeeping files end in .meta,
# .delivered, .state or .sha256, so no glob for *.sql.gz can match them.
backup_regex() { printf '^%s-([0-9]{8})T([0-9]{6})Z\\.sql\\.gz$' "${BACKUP_NAMESPACE//./\\.}"; }

is_backup_name() { [[ $1 =~ $(backup_regex) ]]; }

# backup_epoch <name> -> UTC epoch seconds encoded in the file name.
backup_epoch() {
	[[ $1 =~ $(backup_regex) ]] || return 1
	local d=${BASH_REMATCH[1]} t=${BASH_REMATCH[2]}
	date -u -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s
}

# list_backups <dir> -> completed backup names, oldest first. Only regular
# files (not symlinks, not directories) that match the strict name are listed;
# everything else in the directory, including legacy files, is ignored.
list_backups() {
	local dir=$1 re f
	re=$(backup_regex)
	[[ -d $dir ]] || return 0
	while IFS= read -r -d '' f; do
		f=${f##*/}
		[[ $f =~ $re ]] && printf '%s\n' "$f"
	done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name "${BACKUP_NAMESPACE}-*.sql.gz" -print0) |
		LC_ALL=C sort   # the UTC timestamp in the name sorts chronologically
}

# -------------------------------------------------------------- state files
# Simple KEY=VALUE files, written atomically (temp + rename in the same dir).
# Values are single-line; they are parsed, never sourced or eval'd.
state_write() { # state_write <file> KEY=VALUE...
	local file=$1; shift
	local tmp="${file}.tmp.$$"
	local kv
	{
		for kv in "$@"; do
			kv=${kv//$'\n'/ }
			printf '%s\n' "$kv"
		done
	} >"$tmp" && mv -f "$tmp" "$file"
}

state_get() { # state_get <file> KEY -> value (empty if missing)
	local file=$1 key=$2 k v
	[[ -f $file ]] || return 0
	while IFS='=' read -r k v; do
		[[ $k == "$key" ]] && { printf '%s' "$v"; return 0; }
	done <"$file"
}

ensure_state_dirs() {
	mkdir -p "$MB_NS_DIR" "$MB_WORK_DIR" "$MB_META_DIR" "$MB_DELIVERED_DIR" \
		"$MB_STATUS_DIR" "$MB_LOCK_DIR"
}

# ------------------------------------------------------------------ locking
# take_lock <name> <fd>: non-blocking exclusive flock on a file in the local
# staging state directory. The kernel releases it when the holder exits, even
# after SIGKILL, so there is no stale-lock cleanup. Locks live on local
# staging, never on NFS.
take_lock() {
	local name=$1 fd=$2
	local f="$MB_LOCK_DIR/$name.lock"
	eval "exec $fd>>\"\$f\""
	flock -n "$fd"
}

# ---------------------------------------------------------- misc utilities
file_size() { stat -c %s -- "$1"; }

fs_avail_bytes() { df -P -B1 -- "$1" | awk 'NR==2 {print $4}'; }
fs_total_bytes() { df -P -B1 -- "$1" | awk 'NR==2 {print $2}'; }

fsync_path() { sync -- "$@" 2>/dev/null || sync; }

sha256_of() { sha256sum -- "$1" | awk '{print $1}'; }

# Heartbeat for the container healthcheck (container-local, not staging).
heartbeat() { date -u +%s >"${MB_HEARTBEAT_FILE:-/tmp/mysql-backup.heartbeat}" 2>/dev/null || true; }
