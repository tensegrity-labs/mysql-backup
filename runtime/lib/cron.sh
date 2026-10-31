# shellcheck shell=bash
# Minimal 5-field cron matcher (minute hour day-of-month month day-of-week),
# evaluated against wall-clock time in BACKUP_TZ.
#
# Supported: '*', numbers, ranges 'a-b', steps '*/n' and 'a-b/n', lists 'a,b',
# month names JAN-DEC and weekday names SUN-SAT (case-insensitive); 0 and 7 are
# both Sunday. When both day-of-month and day-of-week are restricted, a time
# matches if EITHER matches (classic cron semantics). '@' macros and seconds
# are not supported.

_cron_names() { # replace names with numbers for month (4) and dow (5) fields
	local f=${1^^} idx=$2
	if ((idx == 3)); then
		local -a m=(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
		local i; for i in "${!m[@]}"; do f=${f//${m[$i]}/$((i + 1))}; done
	elif ((idx == 4)); then
		local -a d=(SUN MON TUE WED THU FRI SAT)
		local i; for i in "${!d[@]}"; do f=${f//${d[$i]}/$i}; done
	fi
	printf '%s' "$f"
}

# _cron_field <value> <spec> <min> <max> -> 0 if matches, 1 if not, 2 invalid
_cron_field() {
	local value=$1 spec=$2 min=$3 max=$4 item base step lo hi
	local -a items
	IFS=, read -r -a items <<<"$spec"   # no unquoted expansion: '*' must not glob
	[[ $spec == *, || ${#items[@]} -eq 0 ]] && return 2
	for item in "${items[@]}"; do
		[[ -n $item ]] || return 2
		step=1
		if [[ $item == */* ]]; then
			base=${item%%/*}; step=${item#*/}
			[[ $step =~ ^[0-9]+$ ]] && ((step > 0)) || return 2
		else
			base=$item
		fi
		if [[ $base == '*' ]]; then
			lo=$min; hi=$max
		elif [[ $base =~ ^([0-9]+)-([0-9]+)$ ]]; then
			lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[2]}))
		elif [[ $base =~ ^[0-9]+$ ]]; then
			lo=$((10#$base)); hi=$lo
			[[ $item == */* ]] && hi=$max
		else
			return 2
		fi
		((lo >= min && hi <= max && lo <= hi)) || return 2
		if ((value >= lo && value <= hi && (value - lo) % step == 0)); then
			return 0
		fi
	done
	return 1
}

# cron_validate <expr>: returns 0 when the expression is well formed.
cron_validate() {
	local -a f
	read -r -a f <<<"$1"
	((${#f[@]} == 5)) || return 1
	local -a mins=(0 0 1 1 0) maxs=(59 23 31 12 7)
	local i spec rc
	for i in 0 1 2 3 4; do
		spec=$(_cron_names "${f[$i]}" "$i")
		rc=0; _cron_field "${mins[$i]}" "$spec" "${mins[$i]}" "${maxs[$i]}" || rc=$?
		((rc == 2)) && return 1
	done
	return 0
}

# cron_matches <expr> <epoch> <tz>: does the minute containing <epoch> match?
cron_matches() {
	local expr=$1 epoch=$2 tz=$3
	local -a f t
	read -r -a f <<<"$expr"
	read -r -a t <<<"$(TZ=$tz date -d "@$epoch" '+%M %H %d %m %w')"
	local min=$((10#${t[0]})) hour=$((10#${t[1]})) dom=$((10#${t[2]})) mon=$((10#${t[3]})) dow=$((10#${t[4]}))
	local s_dow
	s_dow=$(_cron_names "${f[4]}" 4)
	_cron_field "$min" "${f[0]}" 0 59 || return 1
	_cron_field "$hour" "${f[1]}" 0 23 || return 1
	_cron_field "$mon" "$(_cron_names "${f[3]}" 3)" 1 12 || return 1
	local dom_ok=1 dow_ok=1
	_cron_field "$dom" "${f[2]}" 1 31 && dom_ok=0
	if _cron_field "$dow" "$s_dow" 0 7 || { ((dow == 0)) && _cron_field 7 "$s_dow" 0 7; }; then
		dow_ok=0
	fi
	if [[ ${f[2]} != '*' && ${f[4]} != '*' ]]; then
		((dom_ok == 0 || dow_ok == 0))
	else
		((dom_ok == 0 && dow_ok == 0))
	fi
}
