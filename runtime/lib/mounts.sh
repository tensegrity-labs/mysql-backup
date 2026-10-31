# shellcheck shell=bash
# Filesystem identity checks for the staging and destination directories.
#
# What the container CAN verify:
#   * the path is a mount point inside the container (a volume/bind is attached);
#   * the filesystem type and source of the mount that contains the path;
#   * a marker file written by the operator on the intended filesystem.
# What it CANNOT verify on its own: which host block device or export backs a
# bind mount when the host directory was not mounted (Docker then binds the
# empty underlying directory). The marker file closes that gap: it lives on the
# real filesystem, so it is absent from the underlying directory. See
# docs/host-preparation.md for the host-side safeguards.

readonly STAGING_MARKER_NAME=.mysql-backup-staging
readonly DELIVERY_MARKER_NAME=.mysql-backup-destination

# validate_fs <label> <dir> <require_mountpoint> <marker_name> <marker_id> \
#             <expect_fstypes> <expect_source>
# Prints a one-line reason and returns non-zero on failure.
validate_fs() {
	local label=$1 dir=$2 need_mp=$3 marker=$4 marker_id=$5 fstypes=$6 source=$7

	if [[ ! -d $dir ]]; then
		printf '%s directory %s does not exist\n' "$label" "$dir"; return 1
	fi
	if [[ $need_mp == true ]] && ! mountpoint -q -- "$dir"; then
		printf '%s directory %s is not a mount point (volume not attached?)\n' "$label" "$dir"; return 1
	fi
	if [[ -n $fstypes || -n $source ]]; then
		local info fstype src
		info=$(findmnt -n -o FSTYPE,SOURCE --target "$dir" 2>/dev/null | tail -n 1) || true
		fstype=${info%% *}
		src=${info#* }; src=${src#"${src%%[! ]*}"}
		if [[ -n $fstypes && ",$fstypes," != *",$fstype,"* ]]; then
			printf '%s filesystem type is %s, expected one of %s\n' "$label" "${fstype:-unknown}" "$fstypes"; return 1
		fi
		if [[ -n $source && $src != "$source" ]]; then
			printf '%s filesystem source is %s, expected %s\n' "$label" "${src:-unknown}" "$source"; return 1
		fi
	fi
	local mf="$dir/$marker"
	if [[ ! -f $mf ]]; then
		printf '%s marker %s is missing; the intended filesystem may not be mounted\n' "$label" "$mf"; return 1
	fi
	if [[ -n $marker_id ]]; then
		local got
		IFS= read -r got <"$mf" || true
		got=${got%$'\r'}
		if [[ $got != "$marker_id" ]]; then
			printf '%s marker %s does not contain the expected identifier\n' "$label" "$mf"; return 1
		fi
	fi
	if [[ ! -w $dir ]]; then
		printf '%s directory %s is not writable by uid %s\n' "$label" "$dir" "$(id -u)"; return 1
	fi
	return 0
}

validate_staging() {
	validate_fs staging "$STAGING_DIR" "$STAGING_REQUIRE_MOUNTPOINT" "$STAGING_MARKER_NAME" \
		"$STAGING_MARKER_ID" "$STAGING_EXPECT_FSTYPE" ""
}

validate_destination() {
	validate_fs destination "$DELIVERY_DIR" "$DELIVERY_REQUIRE_MOUNTPOINT" "$DELIVERY_MARKER_NAME" \
		"$DELIVERY_MARKER_ID" "$DELIVERY_EXPECT_FSTYPE" "$DELIVERY_EXPECT_SOURCE"
}
