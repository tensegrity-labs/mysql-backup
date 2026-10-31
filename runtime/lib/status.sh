# shellcheck shell=bash
# Read-only status: never takes locks, never touches the destination, so it
# keeps answering while delivery is blocked on an unresponsive NFS server.
# Exit codes follow the monitoring-plugin convention:
#   0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.

json_str() {
	local s=$1
	s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\r'/ }; s=${s//$'\n'/ }
	printf '"%s"' "$s"
}
json_num() { [[ $1 =~ ^-?[0-9]+$ ]] && printf '%s' "$1" || printf 'null'; }

# collect_status [scope]: fills ST_* variables. scope = all|producer|delivery
collect_status() {
	local scope=${1:-all} now f
	now=$(now_epoch)
	ST_NOW=$now; ST_LEVEL=0; ST_PROBLEMS=()
	_lvl() { (($1 > ST_LEVEL)) && ST_LEVEL=$1; ST_PROBLEMS+=("$2"); }

	ST_ENABLED=$BACKUP_ENABLED; ST_DELIVERY=$DELIVERY_ENABLED
	if [[ $BACKUP_ENABLED != true ]]; then
		ST_STATE=DISABLED; return 0
	fi

	ST_STAGING_OK=true; ST_STAGING_MSG=""
	if ! ST_STAGING_MSG=$(validate_staging); then
		ST_STAGING_OK=false
		_lvl 2 "staging: $ST_STAGING_MSG"
	fi
	ST_AVAIL=""; ST_TOTAL=""
	if [[ -d $STAGING_DIR ]]; then
		ST_AVAIL=$(fs_avail_bytes "$STAGING_DIR" 2>/dev/null); ST_TOTAL=$(fs_total_bytes "$STAGING_DIR" 2>/dev/null)
	fi

	# Local (producer) view.
	ST_LOCAL_COUNT=0; ST_LOCAL_BYTES=0; ST_LATEST=""; ST_LATEST_EPOCH=""
	while IFS= read -r f; do
		ST_LOCAL_COUNT=$((ST_LOCAL_COUNT + 1))
		ST_LOCAL_BYTES=$((ST_LOCAL_BYTES + $(file_size "$MB_NS_DIR/$f")))
		ST_LATEST=$f
	done < <(list_backups "$MB_NS_DIR")
	[[ -n $ST_LATEST ]] && ST_LATEST_EPOCH=$(backup_epoch "$ST_LATEST")

	local psf; psf=$(PRODUCER_STATE)
	ST_P_RESULT=$(state_get "$psf" last_result); ST_P_CODE=$(state_get "$psf" last_code)
	ST_P_MSG=$(state_get "$psf" last_message); ST_P_ATTEMPT=$(state_get "$psf" last_attempt)
	ST_P_SUCCESS=$(state_get "$psf" last_success); ST_P_FAILS=$(state_get "$psf" consecutive_failures)
	ST_P_LAST_SUCCESS_FILE=$(state_get "$psf" last_success_file)
	# Newest completed dump known: on disk or recorded by the producer (the
	# local copy may already have been pruned after delivery).
	if [[ -n $ST_P_SUCCESS && ( -z $ST_LATEST_EPOCH || $ST_P_SUCCESS -gt $ST_LATEST_EPOCH ) ]]; then
		ST_LATEST_EPOCH=$ST_P_SUCCESS; ST_LATEST=${ST_P_LAST_SUCCESS_FILE:-$ST_LATEST}
	fi
	ST_CAPACITY_FAIL=false
	[[ $ST_P_RESULT == failed && $ST_P_CODE == "$EX_CAPACITY" ]] && ST_CAPACITY_FAIL=true

	if [[ $scope != delivery ]]; then
		if [[ -z $ST_LATEST_EPOCH ]]; then
			_lvl 2 "no completed backup yet"
		elif ((now - ST_LATEST_EPOCH > STATUS_MAX_LOCAL_AGE)); then
			_lvl 2 "latest local backup is $(human_age $((now - ST_LATEST_EPOCH))) old (limit $(human_age "$STATUS_MAX_LOCAL_AGE"))"
		fi
		if [[ $ST_CAPACITY_FAIL == true ]]; then
			_lvl 2 "last dump failed for capacity: $ST_P_MSG"
		elif [[ $ST_P_RESULT == failed || $ST_P_RESULT == interrupted ]]; then
			_lvl 1 "last dump attempt $ST_P_RESULT: $ST_P_MSG"
		fi
	fi

	# Delivery view.
	ST_PENDING_COUNT=0; ST_PENDING_BYTES=0; ST_PENDING_OLDEST=""; ST_DELIVERED=""; ST_DELIVERED_EPOCH=""
	if [[ $DELIVERY_ENABLED == true ]]; then
		read -r ST_PENDING_COUNT ST_PENDING_BYTES ST_PENDING_OLDEST < <(pending_summary)
		local -a all=()
		mapfile -t all < <(list_backups "$MB_NS_DIR")
		local i
		for ((i = ${#all[@]} - 1; i >= 0; i--)); do
			if is_delivered "${all[$i]}"; then ST_DELIVERED=${all[$i]}; break; fi
		done
		[[ -n $ST_DELIVERED ]] && ST_DELIVERED_EPOCH=$(backup_epoch "$ST_DELIVERED")
		local dsf; dsf=$(DELIVERY_STATE)
		ST_D_RESULT=$(state_get "$dsf" last_result); ST_D_CODE=$(state_get "$dsf" last_code)
		ST_D_MSG=$(state_get "$dsf" last_message); ST_D_ATTEMPT=$(state_get "$dsf" last_attempt)
		ST_D_SUCCESS=$(state_get "$dsf" last_success)
		local lsf="$MB_STATUS_DIR/delivery-loop.state"
		ST_D_STALLED=$(state_get "$lsf" stalled_since)
		ST_D_RUNNING=$(state_get "$lsf" attempt_started)
		# A delivered dump may have been pruned locally; fall back to records.
		if [[ -z $ST_DELIVERED_EPOCH ]]; then
			local rec newest="" e
			for rec in "$MB_DELIVERED_DIR"/*.delivered; do
				[[ -f $rec ]] || continue
				f=${rec##*/}; f=${f%.delivered}.sql.gz
				e=$(backup_epoch "$f") || continue
				[[ -z $newest || $e -gt $newest ]] && { newest=$e; ST_DELIVERED=$f; }
			done
			ST_DELIVERED_EPOCH=$newest
		fi
		# Delivered copies are pruned locally after LOCAL_KEEP_DELIVERED.
		local recorded; recorded=$(state_get "$dsf" latest_delivered)
		if [[ -n $recorded ]] && { [[ -z $ST_DELIVERED ]] || [[ $recorded > $ST_DELIVERED ]]; }; then
			ST_DELIVERED=$recorded; ST_DELIVERED_EPOCH=$(backup_epoch "$recorded")
		fi
		if [[ $scope != producer ]]; then
			if [[ -n $ST_D_STALLED ]]; then
				_lvl 2 "delivery stalled since $(date -u -d "@$ST_D_STALLED" +%FT%TZ): a transfer did not finish or could not be stopped (unresponsive destination?)"
			fi
			if [[ $ST_D_RESULT == failed && $ST_D_CODE == "$EX_CONFLICT" ]]; then
				_lvl 2 "delivery conflict: $ST_D_MSG"
			elif [[ $ST_D_RESULT == failed ]]; then
				_lvl 1 "last delivery attempt failed: $ST_D_MSG"
			fi
			if [[ -n $ST_PENDING_OLDEST ]] && ((now - ST_PENDING_OLDEST > STATUS_MAX_PENDING_AGE)); then
				_lvl 1 "$ST_PENDING_COUNT backup(s) pending delivery, oldest $(human_age $((now - ST_PENDING_OLDEST))) (limit $(human_age "$STATUS_MAX_PENDING_AGE"))"
			fi
			if [[ -n $ST_LATEST_EPOCH ]]; then
				if [[ -z $ST_DELIVERED_EPOCH ]]; then
					((now - ST_LATEST_EPOCH > STATUS_MAX_DELIVERED_AGE)) && _lvl 1 "no backup has been delivered yet"
				elif ((now - ST_DELIVERED_EPOCH > STATUS_MAX_DELIVERED_AGE)); then
					_lvl 1 "latest delivered backup is $(human_age $((now - ST_DELIVERED_EPOCH))) old (limit $(human_age "$STATUS_MAX_DELIVERED_AGE"))"
				fi
			fi
		fi
	fi
	case $ST_LEVEL in 0) ST_STATE=OK ;; 1) ST_STATE=WARNING ;; *) ST_STATE=CRITICAL ;; esac
}

_age_or_empty() { [[ -n $1 ]] && printf '%s' $((ST_NOW - $1)); }

print_status_text() {
	printf 'mysql-backup %s  namespace=%s  state=%s\n' "$MB_VERSION" "$BACKUP_NAMESPACE" "$ST_STATE"
	if [[ $ST_STATE == DISABLED ]]; then
		printf '  BACKUP_ENABLED=false: no dumps, deliveries or pruning are performed\n'; return
	fi
	local p
	for p in "${ST_PROBLEMS[@]}"; do printf '  ! %s\n' "$p"; done
	printf 'local:\n'
	printf '  latest backup      %s (%s ago)\n' "${ST_LATEST:-none}" "$(human_age "$(_age_or_empty "$ST_LATEST_EPOCH")")"
	printf '  last dump attempt  %s %s\n' "${ST_P_RESULT:-never}" "${ST_P_MSG:+- $ST_P_MSG}"
	printf '  staged backups     %s (%s)\n' "$ST_LOCAL_COUNT" "$(human_bytes "$ST_LOCAL_BYTES")"
	printf '  staging free       %s of %s\n' "$(human_bytes "${ST_AVAIL:-0}")" "$(human_bytes "${ST_TOTAL:-0}")"
	if [[ $ST_DELIVERY == true ]]; then
		printf 'delivery:\n'
		printf '  latest delivered   %s (%s ago)\n' "${ST_DELIVERED:-none}" "$(human_age "$(_age_or_empty "$ST_DELIVERED_EPOCH")")"
		printf '  pending            %s backup(s), %s, oldest %s\n' "$ST_PENDING_COUNT" "$(human_bytes "$ST_PENDING_BYTES")" "$(human_age "$(_age_or_empty "$ST_PENDING_OLDEST")")"
		printf '  last attempt       %s %s\n' "${ST_D_RESULT:-never}" "${ST_D_MSG:+- $ST_D_MSG}"
		[[ -n $ST_D_STALLED ]] && printf '  STALLED since      %s\n' "$(date -u -d "@$ST_D_STALLED" +%FT%TZ)"
	else
		printf 'delivery: disabled (local-only retention applies)\n'
	fi
}

print_status_json() {
	local p first=1
	printf '{"version":%s,"namespace":%s,"state":%s,"time":%s,' "$(json_str "$MB_VERSION")" \
		"$(json_str "$BACKUP_NAMESPACE")" "$(json_str "$ST_STATE")" "$ST_NOW"
	printf '"enabled":%s,"delivery_enabled":%s,"problems":[' "$ST_ENABLED" "$ST_DELIVERY"
	for p in "${ST_PROBLEMS[@]}"; do ((first)) || printf ','; first=0; json_str "$p"; done
	printf ']'
	if [[ $ST_STATE != DISABLED ]]; then
		printf ',"local":{"latest_file":%s,"latest_age_seconds":%s,"count":%s,"bytes":%s,' \
			"$(json_str "$ST_LATEST")" "$(json_num "$(_age_or_empty "$ST_LATEST_EPOCH")")" "$ST_LOCAL_COUNT" "$ST_LOCAL_BYTES"
		printf '"last_result":%s,"last_message":%s,"consecutive_failures":%s,"capacity_failure":%s,' \
			"$(json_str "$ST_P_RESULT")" "$(json_str "$ST_P_MSG")" "$(json_num "${ST_P_FAILS:-0}")" "$ST_CAPACITY_FAIL"
		printf '"staging_ok":%s,"staging_available_bytes":%s,"staging_total_bytes":%s}' \
			"$ST_STAGING_OK" "$(json_num "$ST_AVAIL")" "$(json_num "$ST_TOTAL")"
		if [[ $ST_DELIVERY == true ]]; then
			printf ',"delivery":{"latest_delivered_file":%s,"latest_delivered_age_seconds":%s,' \
				"$(json_str "$ST_DELIVERED")" "$(json_num "$(_age_or_empty "$ST_DELIVERED_EPOCH")")"
			printf '"pending_count":%s,"pending_bytes":%s,"pending_oldest_age_seconds":%s,' \
				"$ST_PENDING_COUNT" "$ST_PENDING_BYTES" "$(json_num "$(_age_or_empty "$ST_PENDING_OLDEST")")"
			printf '"last_result":%s,"last_message":%s,"stalled":%s}' "$(json_str "$ST_D_RESULT")" \
				"$(json_str "$ST_D_MSG")" "$([[ -n $ST_D_STALLED ]] && echo true || echo false)"
		fi
	fi
	printf '}\n'
}

print_status_prometheus() {
	local l="namespace=\"$BACKUP_NAMESPACE\""
	local code=$ST_LEVEL; [[ $ST_STATE == DISABLED ]] && code=0
	printf '# HELP mysql_backup_status 0=OK 1=WARNING 2=CRITICAL (disabled reports 0)\n# TYPE mysql_backup_status gauge\n'
	printf 'mysql_backup_status{%s} %s\n' "$l" "$code"
	printf 'mysql_backup_enabled{%s} %s\n' "$l" "$([[ $ST_ENABLED == true ]] && echo 1 || echo 0)"
	[[ $ST_STATE == DISABLED ]] && return
	[[ -n $ST_LATEST_EPOCH ]] && printf 'mysql_backup_latest_local_timestamp_seconds{%s} %s\n' "$l" "$ST_LATEST_EPOCH"
	printf 'mysql_backup_local_count{%s} %s\n' "$l" "$ST_LOCAL_COUNT"
	printf 'mysql_backup_local_bytes{%s} %s\n' "$l" "$ST_LOCAL_BYTES"
	printf 'mysql_backup_producer_consecutive_failures{%s} %s\n' "$l" "${ST_P_FAILS:-0}"
	printf 'mysql_backup_capacity_failure{%s} %s\n' "$l" "$([[ $ST_CAPACITY_FAIL == true ]] && echo 1 || echo 0)"
	[[ -n $ST_AVAIL ]] && printf 'mysql_backup_staging_available_bytes{%s} %s\n' "$l" "$ST_AVAIL"
	if [[ $ST_DELIVERY == true ]]; then
		[[ -n $ST_DELIVERED_EPOCH ]] && printf 'mysql_backup_latest_delivered_timestamp_seconds{%s} %s\n' "$l" "$ST_DELIVERED_EPOCH"
		printf 'mysql_backup_pending_count{%s} %s\n' "$l" "$ST_PENDING_COUNT"
		printf 'mysql_backup_pending_bytes{%s} %s\n' "$l" "$ST_PENDING_BYTES"
		[[ -n $ST_PENDING_OLDEST ]] && printf 'mysql_backup_pending_oldest_timestamp_seconds{%s} %s\n' "$l" "$ST_PENDING_OLDEST"
		printf 'mysql_backup_delivery_stalled{%s} %s\n' "$l" "$([[ -n $ST_D_STALLED ]] && echo 1 || echo 0)"
	fi
}

# write_textfile: refresh STATUS_TEXTFILE (node_exporter textfile collector).
write_textfile() {
	[[ -n $STATUS_TEXTFILE ]] || return 0
	( collect_status all; print_status_prometheus ) >"$STATUS_TEXTFILE.tmp.$$" 2>/dev/null &&
		mv -f -- "$STATUS_TEXTFILE.tmp.$$" "$STATUS_TEXTFILE"
}
