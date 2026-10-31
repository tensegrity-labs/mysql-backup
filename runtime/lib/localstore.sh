# shellcheck shell=bash
# Local staging bookkeeping: delivery markers, pending queue, local pruning and
# capacity reclamation. Only recognised completed backups of the configured
# namespace are ever deleted; legacy and foreign files are left untouched.

base_of() { printf '%s' "${1%.sql.gz}"; }
meta_file() { printf '%s/%s.meta' "$MB_META_DIR" "$(base_of "$1")"; }
delivered_file() { printf '%s/%s.delivered' "$MB_DELIVERED_DIR" "$(base_of "$1")"; }

# local_sha256 <name>: checksum from the producer's metadata, recomputed (and
# re-recorded) when metadata is missing or its size no longer matches.
local_sha256() {
	local name=$1 mf sha size
	mf=$(meta_file "$name")
	sha=$(state_get "$mf" sha256)
	size=$(state_get "$mf" bytes)
	if [[ ${#sha} -ne 64 || $size != "$(file_size "$MB_NS_DIR/$name")" ]]; then
		sha=$(sha256_of "$MB_NS_DIR/$name")
		state_write "$mf" "file=$name" "bytes=$(file_size "$MB_NS_DIR/$name")" "sha256=$sha" "recomputed=$(now_epoch)"
	fi
	printf '%s' "$sha"
}

is_delivered() {
	local name=$1 df
	df=$(delivered_file "$name")
	[[ -f $df ]] || return 1
	local dsha msha
	dsha=$(state_get "$df" sha256)
	msha=$(state_get "$(meta_file "$name")" sha256)
	[[ -z $msha || $dsha == "$msha" ]]
}

mark_delivered() { # mark_delivered <name> <sha> <how>
	state_write "$(delivered_file "$1")" "file=$1" "sha256=$2" "delivered_at=$(now_epoch)" "how=$3"
}

# pending_backups: undelivered completed backups, oldest first.
pending_backups() {
	local f
	while IFS= read -r f; do
		is_delivered "$f" || printf '%s\n' "$f"
	done < <(list_backups "$MB_NS_DIR")
}

# pending_summary -> "<count> <bytes> <oldest-epoch>"
pending_summary() {
	local f c=0 b=0 oldest=""
	while IFS= read -r f; do
		c=$((c + 1))
		b=$((b + $(file_size "$MB_NS_DIR/$f")))
		[[ -z $oldest ]] && oldest=$(backup_epoch "$f")
	done < <(pending_backups)
	printf '%s %s %s\n' "$c" "$b" "${oldest:-}"
}

remove_local_backup() { # remove_local_backup <name> <reason>
	local name=$1 reason=$2
	is_backup_name "$name" || { log_error "refusing to delete unrecognised file $name"; return 1; }
	rm -f -- "$MB_NS_DIR/$name" || return 1
	rm -f -- "$(meta_file "$name")" "$(delivered_file "$name")"
	log_info "local: deleted $name ($reason)"
}

# local_prune [preview]: apply the local staging policy.
#   delivery enabled : delete delivered backups older than LOCAL_KEEP_DELIVERED,
#                      keeping the LOCAL_KEEP_LATEST newest; never undelivered.
#   delivery disabled: staging is the only store; apply LOCAL_RETENTION_* tiers.
local_prune() {
	local preview=${1:-} now f e age
	now=$(now_epoch)
	exec {_prune_fd}>>"$MB_LOCK_DIR/local-prune.lock"
	if ! flock -w 120 "$_prune_fd"; then
		log_warn "local prune skipped: lock busy"
		exec {_prune_fd}>&-
		return 0
	fi
	if [[ $DELIVERY_ENABLED == true ]]; then
		local -a all=()
		mapfile -t all < <(list_backups "$MB_NS_DIR")
		local n=${#all[@]} i
		for ((i = 0; i < n; i++)); do
			f=${all[$i]}
			e=$(backup_epoch "$f"); age=$((now - e))
			if ((n - i <= LOCAL_KEEP_LATEST)); then
				[[ -n $preview ]] && echo "keep   $f latest"
				continue
			fi
			if ! is_delivered "$f"; then
				[[ -n $preview ]] && echo "keep   $f undelivered"
				continue
			fi
			if ((age >= LOCAL_KEEP_DELIVERED)); then
				if [[ -n $preview ]]; then echo "delete $f delivered,older-than-$((LOCAL_KEEP_DELIVERED / 3600))h"
				else remove_local_backup "$f" "delivered, older than local history window"; fi
			else
				[[ -n $preview ]] && echo "keep   $f delivered-history"
			fi
		done
	else
		local action name reason
		while read -r action name reason; do
			if [[ $action == delete ]]; then
				if [[ -n $preview ]]; then echo "delete $name -"
				else remove_local_backup "$name" "local-only tiered retention"; fi
			else
				[[ -n $preview ]] && echo "keep   $name $reason"
			fi
		done < <(retention_input "$MB_NS_DIR" | retention_select "$now" "$BACKUP_TZ" \
			"$LOCAL_RETENTION_KEEP_LATEST" "$LOCAL_RETENTION_HOURLY_DAYS" \
			"$LOCAL_RETENTION_DAILY_DAYS" "$LOCAL_RETENTION_WEEKLY_WEEKS")
	fi
	[[ -z $preview ]] && cleanup_orphan_records "$now"
	exec {_prune_fd}>&-
}

# Bookkeeping for dumps that no longer exist. Records younger than a day are
# kept because the producer writes metadata just before publishing.
cleanup_orphan_records() {
	local now=$1 rec base
	for rec in "$MB_META_DIR"/*.meta "$MB_DELIVERED_DIR"/*.delivered; do
		[[ -f $rec ]] || continue
		base=${rec##*/}; base=${base%.*}
		[[ -e "$MB_NS_DIR/$base.sql.gz" ]] && continue
		(( now - $(stat -c %Y -- "$rec") > 86400 )) && rm -f -- "$rec"
	done
	return 0
}

# reclaim_delivered <needed-avail-bytes>: delete DELIVERED local backups,
# oldest first, until the staging filesystem has <needed> bytes available.
# Undelivered backups are never touched. Returns 0 if the target was reached.
reclaim_delivered() {
	local need=$1 f
	[[ $DELIVERY_ENABLED == true ]] || return 1
	(($(fs_avail_bytes "$STAGING_DIR") >= need)) && return 0
	while IFS= read -r f; do
		is_delivered "$f" || continue
		remove_local_backup "$f" "capacity reclamation (already delivered)"
		(($(fs_avail_bytes "$STAGING_DIR") >= need)) && return 0
	done < <(list_backups "$MB_NS_DIR")
	return 1
}
