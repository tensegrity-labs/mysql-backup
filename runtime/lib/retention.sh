# shellcheck shell=bash
# Tiered, time-zone-aware retention selection. Pure function of
# (file names, "now", time zone, policy); it never deletes anything itself.
#
# Policy (each tier is a set of KEEP decisions; the result is their union, so a
# file selected by several tiers is stored once and listed with all reasons):
#   latest:N  the N newest backups, whatever their age (guards against an
#             outage of the producer emptying the store);
#   hourly:D  every backup whose local calendar date is one of the D most
#             recent calendar days, counting today as day 1;
#   daily:D   the newest backup of each of the D most recent calendar days;
#   weekly:W  the newest backup of each of the W most recent ISO weeks
#             (Monday-Sunday), counting the current week as week 1.
# Calendar days/weeks are evaluated in the configured time zone, so DST days
# of 23 or 25 hours are still one day. A period with no backup simply has no
# recovery point: older backups are NOT promoted to fill gaps. Backups dated
# in the future (clock skew) are always kept.

# retention_select <now_epoch> <tz> <keep_latest> <hourly_days> <daily_days> <weekly_weeks>
# stdin:  "<epoch> <name>" lines
# stdout: "keep <name> <reason,reason>" or "delete <name> -" lines, oldest first
retention_select() {
	local now=$1 tz=$2 latest=$3 hourly=$4 daily=$5 weekly=$6
	TZ=$tz gawk -v now="$now" -v latest="$latest" -v hourly="$hourly" \
		-v daily="$daily" -v weekly="$weekly" '
	function offset(e,   z, s) {          # local UTC offset in seconds at epoch e
		z = strftime("%z", e)
		s = (substr(z, 2, 2) * 3600) + (substr(z, 4, 2) * 60)
		return substr(z, 1, 1) == "-" ? -s : s
	}
	function dayidx(e) { return int((e + offset(e)) / 86400) }   # local calendar day number
	function weekidx(e,   d) { d = dayidx(e); return d - (strftime("%u", e) - 1) }  # local Monday
	function addr(i, r) { reason[i] = (reason[i] == "" ? r : reason[i] "," r) }
	NF >= 2 { n++; ep[n] = $1 + 0; nm[n] = $2 }
	END {
		if (n == 0) exit
		# sort indices by (epoch, name) ascending - simple insertion sort, n is small
		for (i = 1; i <= n; i++) ord[i] = i
		for (i = 2; i <= n; i++) {
			k = ord[i]; j = i - 1
			while (j >= 1 && (ep[ord[j]] > ep[k] || (ep[ord[j]] == ep[k] && nm[ord[j]] > nm[k]))) { ord[j+1] = ord[j]; j-- }
			ord[j+1] = k
		}
		today = dayidx(now); thisweek = weekidx(now)
		for (p = n; p >= 1; p--) {          # newest first
			i = ord[p]; e = ep[i]; d = dayidx(e); w = weekidx(e)
			if (e > now) { addr(i, "future"); continue }
			if (++rank <= latest) addr(i, "latest")
			dage = today - d; wage = int((thisweek - w) / 7)
			if (dage < hourly) addr(i, "hourly")
			if (dage < daily && !(d in seenday)) { seenday[d] = 1; addr(i, "daily") }
			if (wage < weekly && !(w in seenweek)) { seenweek[w] = 1; addr(i, "weekly") }
		}
		for (p = 1; p <= n; p++) {
			i = ord[p]
			if (reason[i] != "") print "keep", nm[i], reason[i]; else print "delete", nm[i], "-"
		}
	}'
}

# retention_input <dir>: "<epoch> <name>" for every recognised backup in <dir>
retention_input() {
	local dir=$1 f e
	while IFS= read -r f; do
		e=$(backup_epoch "$f") || continue
		printf '%s %s\n' "$e" "$f"
	done < <(list_backups "$dir")
}

# describe a policy for logs
retention_policy_text() {
	printf 'latest:%s hourly:%sd daily:%sd weekly:%sw tz:%s' "$1" "$2" "$3" "$4" "$BACKUP_TZ"
}
