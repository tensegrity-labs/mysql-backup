#!/usr/bin/env bash
# Staging size calculator. All inputs are your own measurements/choices.
# Usage: staging-size.sh <dump-size-GiB> <dumps-per-day> <outage-days> [reserve-GiB] [growth-percent]
# Example: staging-size.sh 1.2 16 3 5 150
set -euo pipefail
S=${1:?compressed dump size in GiB}; N=${2:?dumps per day}; O=${3:?outage days to tolerate}
R=${4:-5}; G=${5:-150}
awk -v S="$S" -v N="$N" -v O="$O" -v R="$R" -v G="$G" 'BEGIN {
	buffer = S * N * O; growth = S * G / 100; total = buffer + growth + R
	printf "outage buffer   %8.1f GiB  (%s GiB x %s/day x %s days)\n", buffer, S, N, O
	printf "next-dump room  %8.1f GiB  (%s GiB x %s%%)\n", growth, S, G
	printf "reserve         %8.1f GiB\n", R
	printf "minimum staging %8.1f GiB\n", total
	printf "normal use      %8.1f GiB  (about one day of delivered history)\n", S * N
}'
