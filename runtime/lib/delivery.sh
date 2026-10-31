# shellcheck shell=bash
# Remote delivery: copy completed local dumps to the destination filesystem
# (normally an NFS export mounted by the host), verify, publish atomically,
# then record delivery locally. Runs in its own container; the producer never
# waits for it.

DELIVERY_STATE() { printf '%s/delivery.state' "$MB_STATUS_DIR"; }

delivery_record() { # delivery_record result code message [delivered_count]
	local result=$1 code=$2 msg=$3 count=${4:-0}
	local sf now last_success fails last_fail
	sf=$(DELIVERY_STATE); now=$(now_epoch)
	last_success=$(state_get "$sf" last_success)
	fails=$(state_get "$sf" consecutive_failures); fails=${fails:-0}
	last_fail=$(state_get "$sf" last_failure)
	local latest; latest=$(state_get "$sf" latest_delivered)
	[[ -n ${_newest_delivered:-} && ${_newest_delivered} > $latest ]] && latest=$_newest_delivered
	case $result in
		ok) last_success=$now; fails=0 ;;
		skipped) ;;
		*) fails=$((fails + 1)); last_fail=$now ;;
	esac
	state_write "$sf" "last_attempt=$now" "last_result=$result" "last_code=$code" \
		"last_message=$msg" "last_delivered_count=$count" "last_success=$last_success" \
		"last_failure=$last_fail" "consecutive_failures=$fails" "latest_delivered=$latest"
	[[ -n $STATUS_TEXTFILE ]] && write_textfile 2>/dev/null
	return 0
}

# remote_sha256 <path>: checksum read back from the destination. With
# DELIVERY_VERIFY_READ=direct|auto, O_DIRECT reads bypass the client page
# cache so the data is re-read from the server where the filesystem allows.
remote_sha256() {
	local p=$1 out
	if [[ $DELIVERY_VERIFY_READ != cached ]]; then
		if out=$(set -o pipefail; dd if="$p" iflag=direct bs=1M status=none 2>/dev/null | sha256sum); then
			printf '%s' "${out%% *}"; return 0
		fi
		[[ $DELIVERY_VERIFY_READ == direct ]] && return 1
		log_debug "O_DIRECT read not supported for $p; verifying through the page cache"
	fi
	out=$(sha256sum -- "$p") || return 1
	printf '%s' "${out%% *}"
}

write_remote_checksum() { # write_remote_checksum <name> <sha>
	local f="$MB_REMOTE_STATE/checksums/$1.sha256"
	printf '%s  %s\n' "$2" "$1" >"$f.tmp.$$" && mv -f -- "$f.tmp.$$" "$f"
}

# deliver_one <name>: returns 0 delivered/already present, EX_CONFLICT, or 1.
deliver_one() {
	local name=$1 src="$MB_NS_DIR/$1" dst="$MB_REMOTE_NS_DIR/$1"
	local tmp="$MB_REMOTE_STATE/incoming/$1.partial"
	local sha size rsha
	[[ -f $src ]] || return 0   # pruned meanwhile (cannot happen for undelivered, defensive)
	sha=$(local_sha256 "$name"); size=$(file_size "$src")

	if [[ -e $dst ]]; then
		# Already published (e.g. interrupted after publication, before the local
		# record was written). Accept only if it is byte-identical.
		rsha=$(remote_sha256 "$dst") || { log_error "cannot read existing remote $name"; return 1; }
		if [[ $rsha == "$sha" ]]; then
			[[ -f "$MB_REMOTE_STATE/checksums/$name.sha256" ]] || write_remote_checksum "$name" "$sha"
			mark_delivered "$name" "$sha" already-present
			log_info "delivery: $name already present at destination and verified; recorded"
			return 0
		fi
		log_error "delivery: CONFLICT - a different file named $name already exists at the destination; it was NOT replaced and the local copy is kept"
		return "$EX_CONFLICT"
	fi

	rm -f -- "$tmp"
	if ! cp -- "$src" "$tmp"; then
		rm -f -- "$tmp"; log_error "delivery: copy of $name failed"; return 1
	fi
	fsync_path "$tmp"
	if [[ $(file_size "$tmp") != "$size" ]]; then
		rm -f -- "$tmp"; log_error "delivery: size mismatch after copying $name"; return 1
	fi
	rsha=$(remote_sha256 "$tmp") || { rm -f -- "$tmp"; log_error "delivery: cannot read back $name"; return 1; }
	if [[ $rsha != "$sha" ]]; then
		rm -f -- "$tmp"; log_error "delivery: checksum mismatch after copying $name"; return 1
	fi

	# Atomic, no-clobber publication on the destination filesystem.
	if ln -- "$tmp" "$dst" 2>/dev/null; then
		rm -f -- "$tmp"
	elif [[ -e $dst ]]; then
		rm -f -- "$tmp"
		log_error "delivery: CONFLICT - $name appeared at the destination during publication"
		return "$EX_CONFLICT"
	else
		mv -n -T -- "$tmp" "$dst" 2>/dev/null
		if [[ -e $tmp ]]; then
			rm -f -- "$tmp"; log_error "delivery: could not publish $name"; return 1
		fi
	fi
	fsync_path "$MB_REMOTE_NS_DIR"
	if [[ $(file_size "$dst") != "$size" ]]; then
		log_error "delivery: published $name has unexpected size"; return 1
	fi
	write_remote_checksum "$name" "$sha"
	mark_delivered "$name" "$sha" copied
	log_info "delivery: $name delivered ($(human_bytes "$size"), sha256 verified)"
	return 0
}

# remote_retention [preview]: tiered retention on the destination namespace.
remote_retention() {
	local preview=${1:-} action name reason now
	now=$(now_epoch)
	while read -r action name reason; do
		if [[ $action == delete ]]; then
			if [[ -n $preview ]]; then echo "delete $name -"; continue; fi
			is_backup_name "$name" || continue
			rm -f -- "$MB_REMOTE_NS_DIR/$name" "$MB_REMOTE_STATE/checksums/$name.sha256" &&
				log_info "remote: deleted $name (outside retention policy)"
		else
			[[ -n $preview ]] && echo "keep   $name $reason"
		fi
	done < <(retention_input "$MB_REMOTE_NS_DIR" | retention_select "$now" "$BACKUP_TZ" \
		"$RETENTION_KEEP_LATEST" "$RETENTION_HOURLY_DAYS" "$RETENTION_DAILY_DAYS" "$RETENTION_WEEKLY_WEEKS")
}

_delivery_on_signal() { _interrupted=1; }

# do_deliver: one delivery pass for every pending backup.
do_deliver() {
	if [[ $BACKUP_ENABLED != true ]]; then
		log_info "BACKUP_ENABLED=false: delivery skipped, nothing was touched"; return "$EX_DISABLED"
	fi
	if [[ $DELIVERY_ENABLED != true ]]; then
		log_info "DELIVERY_ENABLED=false: nothing to do"; return "$EX_DISABLED"
	fi
	local why
	if ! why=$(validate_staging); then
		log_error "staging check failed: $why"; return "$EX_UNAVAILABLE"
	fi
	ensure_state_dirs
	if ! take_lock delivery 9; then
		log_warn "another delivery pass is still running (possibly blocked on the destination); not starting another"
		return "$EX_BUSY"
	fi
	_interrupted=0
	trap _delivery_on_signal TERM INT HUP

	local -a pending=()
	mapfile -t pending < <(pending_backups)
	if ((${#pending[@]} == 0)); then
		log_debug "delivery: nothing pending"
		local_prune
		delivery_record ok 0 "nothing pending" 0
		return 0
	fi
	log_info "delivery: ${#pending[@]} pending backup(s); checking destination"

	if ! why=$(validate_destination); then
		if ((_interrupted)); then
			log_warn "delivery pass interrupted while checking the destination (unresponsive?)"
			delivery_record interrupted "$EX_INTERRUPTED" "interrupted while checking the destination"
			return "$EX_INTERRUPTED"
		fi
		log_error "destination unavailable: $why; ${#pending[@]} backup(s) remain queued locally"
		delivery_record failed "$EX_UNAVAILABLE" "destination unavailable: $why"
		return "$EX_UNAVAILABLE"
	fi
	if ! mkdir -p -- "$MB_REMOTE_NS_DIR" "$MB_REMOTE_STATE/incoming" "$MB_REMOTE_STATE/checksums"; then
		delivery_record failed "$EX_UNAVAILABLE" "cannot create destination directories"
		return "$EX_UNAVAILABLE"
	fi
	# Incomplete transfers from an interrupted pass. We hold the delivery lock,
	# so no live transfer of this namespace can own them.
	find "$MB_REMOTE_STATE/incoming" -mindepth 1 -maxdepth 1 -type f -name '*.partial' -print -delete 2>/dev/null |
		while IFS= read -r p; do log_warn "removed incomplete remote transfer ${p##*/}"; done

	local f rc ok=0 conflicts=0 failed=0
	for f in "${pending[@]}"; do
		((_interrupted)) && break
		deliver_one "$f"; rc=$?
		case $rc in
			0) ok=$((ok + 1)); [[ $f > ${_newest_delivered:-} ]] && _newest_delivered=$f ;;
			"$EX_CONFLICT") conflicts=$((conflicts + 1)) ;;
			*) failed=$((failed + 1)); break ;;  # likely a destination problem: stop this pass
		esac
	done

	local_prune

	if ((_interrupted)); then
		delivery_record interrupted "$EX_INTERRUPTED" "interrupted after $ok delivered" "$ok"
		return "$EX_INTERRUPTED"
	fi
	if ((conflicts > 0)); then
		delivery_record failed "$EX_CONFLICT" "$conflicts conflicting file(s) at destination need manual review; $ok delivered" "$ok"
		return "$EX_CONFLICT"
	fi
	if ((failed > 0)); then
		delivery_record failed "$EX_FAIL" "delivery failed after $ok delivered; will retry" "$ok"
		return "$EX_FAIL"
	fi
	# Remote retention only after a fully successful pass and a fresh
	# destination identity check.
	if [[ $REMOTE_RETENTION_ENABLED == true ]] && ((ok > 0)); then
		if why=$(validate_destination); then
			remote_retention
		else
			log_warn "remote retention skipped: $why"
		fi
	fi
	delivery_record ok 0 "$ok delivered" "$ok"
	return 0
}
