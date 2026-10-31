# shellcheck shell=bash
# Local dump production. Never touches the delivery destination.

PRODUCER_STATE() { printf '%s/producer.state' "$MB_STATUS_DIR"; }

producer_record() { # producer_record result code message [file bytes duration]
	local result=$1 code=$2 msg=$3 file=${4:-} bytes=${5:-} dur=${6:-}
	local sf now prev_success prev_file prev_bytes fails
	sf=$(PRODUCER_STATE); now=$(now_epoch)
	prev_success=$(state_get "$sf" last_success)
	prev_file=$(state_get "$sf" last_success_file)
	prev_bytes=$(state_get "$sf" last_success_bytes)
	fails=$(state_get "$sf" consecutive_failures); fails=${fails:-0}
	if [[ $result == ok ]]; then
		prev_success=$now; prev_file=$file; prev_bytes=$bytes; fails=0
	elif [[ $result != skipped ]]; then
		fails=$((fails + 1))
	fi
	state_write "$sf" "last_attempt=$now" "last_result=$result" "last_code=$code" \
		"last_message=$msg" "last_duration=$dur" "last_success=$prev_success" \
		"last_success_file=$prev_file" "last_success_bytes=$prev_bytes" \
		"consecutive_failures=$fails"
	[[ -n $STATUS_TEXTFILE ]] && write_textfile 2>/dev/null
	return 0
}

producer_check_db_config() {
	MYSQL_HOST=${MYSQL_HOST:-}
	MYSQL_PORT=${MYSQL_PORT:-3306}
	MYSQL_DATABASE=${MYSQL_DATABASE:-}
	[[ -n $MYSQL_HOST ]] || die "$EX_CONFIG" "MYSQL_HOST is required"
	[[ $MYSQL_PORT =~ ^[0-9]+$ ]] || die "$EX_CONFIG" "MYSQL_PORT must be numeric"
	[[ -n $MYSQL_DATABASE ]] || die "$EX_CONFIG" "MYSQL_DATABASE is required (one database per producer)"
	[[ $MYSQL_DATABASE =~ ^[A-Za-z0-9_$][A-Za-z0-9_$-]{0,63}$ ]] ||
		die "$EX_CONFIG" "MYSQL_DATABASE contains unsupported characters"
	MYSQL_SSL_MODE=${MYSQL_SSL_MODE:-PREFERRED}
	[[ $MYSQL_SSL_MODE =~ ^(DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY)$ ]] ||
		die "$EX_CONFIG" "MYSQL_SSL_MODE must be DISABLED, PREFERRED, REQUIRED, VERIFY_CA or VERIFY_IDENTITY"
	MYSQLDUMP_SET_GTID_PURGED=${MYSQLDUMP_SET_GTID_PURGED:-OFF}
	[[ $MYSQLDUMP_SET_GTID_PURGED =~ ^(OFF|ON|AUTO|COMMENTED)$ ]] ||
		die "$EX_CONFIG" "MYSQLDUMP_SET_GTID_PURGED must be OFF, ON, AUTO or COMMENTED"
	MYSQL_VERSION_CHECK=${MYSQL_VERSION_CHECK:-warn}
	[[ $MYSQL_VERSION_CHECK =~ ^(warn|strict|off)$ ]] ||
		die "$EX_CONFIG" "MYSQL_VERSION_CHECK must be warn, strict or off"
	_cfg_int GZIP_LEVEL 6
	((GZIP_LEVEL >= 1 && GZIP_LEVEL <= 9)) || die "$EX_CONFIG" "GZIP_LEVEL must be 1-9"
	_cfg_int MYSQL_CONNECT_TIMEOUT 15
	_cfg_bool DUMP_VERIFY true
	MYSQLDUMP_EXTRA_ARGS=${MYSQLDUMP_EXTRA_ARGS:-}
	if [[ ${MYSQLDUMP_EXTRA_ARGS,,} =~ (^|[[:space:]])(-p|--password|--defaults|--no-defaults|--result-file|-r|--databases|-b|--all-databases|-a|--user|-u|--host|-h) ]]; then
		die "$EX_CONFIG" "MYSQLDUMP_EXTRA_ARGS may not set credentials, connection, database selection or output options"
	fi
}

# Write a private client option file. Credentials never appear in argv, logs
# or the environment of mysqldump.
write_client_cnf() { # write_client_cnf <path>
	local cnf=$1 user pass
	user=$(read_secret MYSQL_USER)
	pass=$(read_secret MYSQL_PASSWORD)
	[[ -n $user ]] || die "$EX_CONFIG" "MYSQL_USER (or MYSQL_USER_FILE) is required"
	[[ -n $pass ]] || die "$EX_CONFIG" "MYSQL_PASSWORD (or MYSQL_PASSWORD_FILE) is required"
	_cnf_quote() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
	(
		umask 077
		{
			printf '[client]\n'
			printf 'host=%s\n' "$(_cnf_quote "$MYSQL_HOST")"
			printf 'port=%s\n' "$MYSQL_PORT"
			printf 'user=%s\n' "$(_cnf_quote "$user")"
			printf 'password=%s\n' "$(_cnf_quote "$pass")"
			printf 'ssl-mode=%s\n' "$MYSQL_SSL_MODE"
			[[ -n ${MYSQL_SSL_CA:-} ]] && printf 'ssl-ca=%s\n' "$(_cnf_quote "$MYSQL_SSL_CA")"
			# connect-timeout is understood by the mysql client (preflight) only
			printf '[mysql]\nconnect-timeout=%s\n' "$MYSQL_CONNECT_TIMEOUT"
		} >"$cnf"
	)
}

# Estimate the space the next dump needs: the largest of the recent dumps
# (or STAGING_FIRST_DUMP_ESTIMATE) scaled by DUMP_SIZE_GROWTH_PERCENT.
dump_size_estimate() {
	local max=0 f s last
	while IFS= read -r f; do
		s=$(file_size "$MB_NS_DIR/$f"); ((s > max)) && max=$s
	done < <(list_backups "$MB_NS_DIR" | tail -n 5)
	last=$(state_get "$(PRODUCER_STATE)" last_success_bytes)
	[[ $last =~ ^[0-9]+$ ]] && ((last > max)) && max=$last
	((max == 0)) && max=$STAGING_FIRST_DUMP_ESTIMATE
	printf '%s\n' $((max * DUMP_SIZE_GROWTH_PERCENT / 100))
}

staging_reserve_bytes() {
	local total pct
	total=$(fs_total_bytes "$STAGING_DIR")
	pct=$((total / 100 * STAGING_RESERVE_PERCENT))
	((pct > STAGING_RESERVE)) && printf '%s\n' "$pct" || printf '%s\n' "$STAGING_RESERVE"
}

# capacity_check: prune, then reclaim delivered files, then decide.
# Sets CAPACITY_MESSAGE; returns 0 if the dump may proceed.
capacity_check() {
	local est reserve need avail count bytes oldest
	local_prune
	read -r count bytes oldest < <(pending_summary)
	if ((STAGING_MAX_PENDING_COUNT > 0 && count >= STAGING_MAX_PENDING_COUNT)); then
		CAPACITY_MESSAGE="pending queue full: $count undelivered backups (limit $STAGING_MAX_PENDING_COUNT); restore delivery or raise STAGING_MAX_PENDING_COUNT"
		return 1
	fi
	est=$(dump_size_estimate)
	if ((STAGING_MAX_PENDING_BYTES > 0 && bytes + est > STAGING_MAX_PENDING_BYTES)); then
		CAPACITY_MESSAGE="pending queue full: $(human_bytes "$bytes") undelivered + $(human_bytes "$est") estimated exceeds STAGING_MAX_PENDING_BYTES=$(human_bytes "$STAGING_MAX_PENDING_BYTES"); restore delivery or raise the limit"
		return 1
	fi
	reserve=$(staging_reserve_bytes)
	need=$((est + reserve))
	avail=$(fs_avail_bytes "$STAGING_DIR")
	if ((avail < need)); then
		log_info "capacity: $(human_bytes "$avail") available, $(human_bytes "$need") needed; reclaiming delivered local copies"
		reclaim_delivered "$need" || true
		avail=$(fs_avail_bytes "$STAGING_DIR")
	fi
	if ((avail < need)); then
		CAPACITY_MESSAGE="insufficient staging capacity: $(human_bytes "$avail") available, need $(human_bytes "$est") estimated dump + $(human_bytes "$reserve") reserve; $count undelivered backups ($(human_bytes "$bytes")) are preserved - restore delivery, free space, or enlarge staging"
		return 1
	fi
	log_debug "capacity ok: avail=$avail est=$est reserve=$reserve"
	MB_RESERVE=$reserve
	return 0
}

_producer_cleanup() {
	[[ -n ${_watch_pid:-} ]] && kill "$_watch_pid" 2>/dev/null
	[[ -n ${_dump_pgid:-} ]] && kill -TERM -- "-$_dump_pgid" 2>/dev/null
	[[ -n ${_tmp_file:-} ]] && rm -f -- "$_tmp_file"
	[[ -n ${_priv_dir:-} ]] && rm -rf -- "$_priv_dir"
	return 0
}

_producer_on_signal() {
	_interrupted=1
	[[ -n ${_dump_pgid:-} ]] && kill -TERM -- "-$_dump_pgid" 2>/dev/null
	return 0
}

# do_dump: one complete backup. Exit code per common.sh.
do_dump() {
	if [[ $BACKUP_ENABLED != true ]]; then
		log_info "BACKUP_ENABLED=false: dump skipped, nothing was touched"
		return "$EX_DISABLED"
	fi
	producer_check_db_config
	local why
	if ! why=$(validate_staging); then
		log_error "staging check failed: $why"
		# The status file lives on staging; only record if the tree is usable.
		[[ -d $MB_STATUS_DIR && -w $MB_STATUS_DIR ]] && producer_record failed "$EX_UNAVAILABLE" "staging unavailable: $why"
		return "$EX_UNAVAILABLE"
	fi
	ensure_state_dirs
	if ! take_lock producer 8; then
		log_warn "another dump is already running for namespace $BACKUP_NAMESPACE; not starting a second one"
		return "$EX_BUSY"
	fi

	_interrupted=0; _dump_pgid=""; _watch_pid=""; _tmp_file=""; _priv_dir=""
	trap _producer_cleanup EXIT
	trap _producer_on_signal TERM INT HUP

	# Leftovers from a dump killed with SIGKILL or a crashed host. Safe: we hold
	# the producer lock, so nobody else is writing here.
	find "$MB_WORK_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.partial' -print -delete 2>/dev/null |
		while IFS= read -r p; do log_warn "removed stale temporary file ${p##*/}"; done

	if ! capacity_check; then
		log_error "$CAPACITY_MESSAGE"
		producer_record failed "$EX_CAPACITY" "$CAPACITY_MESSAGE"
		return "$EX_CAPACITY"
	fi

	local started name final stamp i
	for i in 1 2 3 4 5; do
		started=$(now_epoch)
		stamp=$(date -u -d "@$started" +%Y%m%dT%H%M%SZ)
		name="$BACKUP_NAMESPACE-$stamp.sql.gz"
		final="$MB_NS_DIR/$name"
		[[ -e $final ]] || break
		sleep 1
	done
	if [[ -e $final ]]; then
		producer_record failed "$EX_FAIL" "file name collision for $name"
		die "$EX_FAIL" "refusing to overwrite existing $name"
	fi
	_tmp_file="$MB_WORK_DIR/$name.$$.partial"

	_priv_dir=$(mktemp -d "${TMPDIR:-/tmp}/mysql-backup.XXXXXX")
	chmod 700 "$_priv_dir"
	local cnf="$_priv_dir/client.cnf" errf="$_priv_dir/mysqldump.err" psf="$_priv_dir/pipestatus"
	local lowf="$_priv_dir/lowspace"
	write_client_cnf "$cnf"

	# Preflight: connectivity and server version (clearer errors than mysqldump).
	local server_version client_version
	client_version=$(mysqldump --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="Ver"){print $(i+1); exit}}')
	if ! server_version=$(mysql --defaults-file="$cnf" -N -B -e 'SELECT VERSION()' 2>"$errf"); then
		local err; err=$(head -c 400 "$errf" | tr '\n' ' ')
		log_error "cannot connect to MySQL at $MYSQL_HOST:$MYSQL_PORT: $err"
		producer_record failed "$EX_FAIL" "cannot connect to MySQL: $err"
		return "$EX_FAIL"
	fi
	if [[ $MYSQL_VERSION_CHECK != off && ! $server_version =~ ^8\.0\. ]]; then
		local msg="server version $server_version is outside the tested range for mysqldump $client_version (see docs/compatibility.md)"
		if [[ $MYSQL_VERSION_CHECK == strict ]]; then
			log_error "$msg"; producer_record failed "$EX_CONFIG" "$msg"; return "$EX_CONFIG"
		fi
		log_warn "$msg"
	fi

	log_info "dump started: database=$MYSQL_DATABASE host=$MYSQL_HOST server=$server_version client=$client_version -> $name"

	local -a args=(
		--defaults-file="$cnf"
		--single-transaction --quick --skip-lock-tables
		--routines --triggers --events
		--hex-blob --no-tablespaces
		--default-character-set=utf8mb4
		--set-gtid-purged="$MYSQLDUMP_SET_GTID_PURGED"
	)
	if [[ -n $MYSQLDUMP_EXTRA_ARGS ]]; then
		local -a extra; read -r -a extra <<<"$MYSQLDUMP_EXTRA_ARGS"; args+=("${extra[@]}")
	fi
	args+=("$MYSQL_DATABASE") # validated above: cannot start with '-'

	# Run the pipeline in its own process group so it can be stopped as a unit.
	set -m
	(
		trap - TERM INT HUP
		mysqldump "${args[@]}" 2>"$errf" | gzip -c "-$GZIP_LEVEL" >"$_tmp_file"
		echo "${PIPESTATUS[*]}" >"$psf"
	) &
	_dump_pgid=$!
	set +m

	# Capacity watchdog: never let the dump consume the staging reserve.
	(
		trap - TERM INT HUP
		exec 8>&- # do not keep the producer lock alive after the dump ends
		while kill -0 "$_dump_pgid" 2>/dev/null; do
			if (($(fs_avail_bytes "$STAGING_DIR") < MB_RESERVE)); then
				: >"$lowf"
				kill -TERM -- "-$_dump_pgid" 2>/dev/null
				break
			fi
			sleep 1
		done
	) &
	_watch_pid=$!

	while kill -0 "$_dump_pgid" 2>/dev/null; do
		wait "$_dump_pgid" 2>/dev/null
	done
	kill "$_watch_pid" 2>/dev/null; wait "$_watch_pid" 2>/dev/null; _watch_pid=""
	_dump_pgid=""
	local duration=$(( $(now_epoch) - started ))

	if [[ -s $errf ]]; then
		while IFS= read -r line; do log_warn "mysqldump: $line"; done < <(head -n 20 "$errf")
	fi

	if ((_interrupted)); then
		rm -f -- "$_tmp_file"
		log_warn "dump interrupted by signal; temporary output removed, no backup published"
		producer_record interrupted "$EX_INTERRUPTED" "interrupted by signal"
		return "$EX_INTERRUPTED"
	fi
	if [[ -e $lowf ]]; then
		rm -f -- "$_tmp_file"
		local msg="dump aborted: staging free space fell below the reserve ($(human_bytes "$MB_RESERVE")); dump larger than estimated. Existing backups preserved."
		log_error "$msg"; producer_record failed "$EX_CAPACITY" "$msg"
		return "$EX_CAPACITY"
	fi
	local ps; ps=$(cat "$psf" 2>/dev/null || echo "missing")
	# A burst can fill the disk between watchdog polls: classify as capacity.
	if [[ $ps != "0 0" ]] && (($(fs_avail_bytes "$STAGING_DIR") < MB_RESERVE)); then
		rm -f -- "$_tmp_file"
		local msg="dump aborted: staging ran out of space (free space fell below the $(human_bytes "$MB_RESERVE") reserve); dump larger than estimated. Existing backups preserved."
		log_error "$msg"; producer_record failed "$EX_CAPACITY" "$msg"
		return "$EX_CAPACITY"
	fi
	if [[ $ps != "0 0" ]]; then
		rm -f -- "$_tmp_file"
		local msg="dump pipeline failed (mysqldump/gzip exit status: $ps)"
		log_error "$msg"; producer_record failed "$EX_FAIL" "$msg"
		return "$EX_FAIL"
	fi

	# Verify: valid gzip stream that ends with mysqldump's completion trailer.
	if [[ $DUMP_VERIFY == true ]]; then
		local last
		last=$(gzip -dc -- "$_tmp_file" | tail -n 1; exit "${PIPESTATUS[0]}") || last="__gzip_error__"
		if [[ $last != "-- Dump completed"* ]]; then
			rm -f -- "$_tmp_file"
			local msg="dump verification failed: output is not a complete mysqldump stream"
			log_error "$msg"; producer_record failed "$EX_FAIL" "$msg"
			return "$EX_FAIL"
		fi
	fi
	fsync_path "$_tmp_file"
	local bytes sha
	bytes=$(file_size "$_tmp_file")
	sha=$(sha256_of "$_tmp_file")
	state_write "$(meta_file "$name")" "file=$name" "bytes=$bytes" "sha256=$sha" \
		"created=$started" "duration=$duration" "database=$MYSQL_DATABASE" \
		"server_version=$server_version" "client_version=$client_version" "tool_version=$MB_VERSION"

	# Atomic, no-clobber publication within the staging filesystem.
	if ln -- "$_tmp_file" "$final" 2>/dev/null; then
		rm -f -- "$_tmp_file"
	elif [[ -e $final ]]; then
		rm -f -- "$_tmp_file"
		producer_record failed "$EX_FAIL" "file name collision for $name"
		die "$EX_FAIL" "refusing to overwrite existing $name"
	else
		mv -n -T -- "$_tmp_file" "$final" || { producer_record failed "$EX_FAIL" "publish failed"; return "$EX_FAIL"; }
	fi
	_tmp_file=""
	fsync_path "$MB_NS_DIR"

	log_info "dump completed: $name $(human_bytes "$bytes") in ${duration}s sha256=$sha"
	producer_record ok 0 "dump completed" "$name" "$bytes" "$duration"
	return "$EX_OK"
}
