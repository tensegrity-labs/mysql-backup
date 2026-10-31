# shellcheck shell=bash
# Tiny test harness. Each test is a function named t_<name>, run in its own
# subshell so state and traps cannot leak between tests.

T_PASS=0; T_FAIL=0; T_FAILED=()

fail() { echo "    assertion failed: $*" >&2; return 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "${3:-} expected [$2] got [$1]"; }
assert_ne() { [[ $1 != "$2" ]] || fail "${3:-} did not expect [$2]"; }
assert_file() { [[ -f $1 ]] || fail "expected file $1"; }
assert_no_file() { [[ ! -e $1 ]] || fail "unexpected file $1"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "${3:-} expected to contain [$2] in [$1]"; }
assert_not_contains() { [[ $1 != *"$2"* ]] || fail "${3:-} expected NOT to contain [$2]"; }
assert_rc() { # assert_rc <expected> <cmd...>
	local exp=$1; shift
	local rc=0
	"$@" || rc=$?
	[[ $rc == "$exp" ]] || fail "exit code of '$*': expected $exp got $rc"
}

run_tests() {
	local suite=$1 t
	for t in $(declare -F | awk '{print $3}' | grep '^t_' ); do
		# Not inside `if`: errexit would be ignored in the subshell.
		( set -e -o pipefail; "$t" ) >"/tmp/test-$t.log" 2>&1
		if (($? == 0)); then
			T_PASS=$((T_PASS + 1)); printf '  ok    %s\n' "$t"
		else
			T_FAIL=$((T_FAIL + 1)); T_FAILED+=("$suite:$t"); printf '  FAIL  %s\n' "$t"
			sed 's/^/        | /' "/tmp/test-$t.log" | tail -n 40
		fi
	done
	printf '%s: %d passed, %d failed\n' "$suite" "$T_PASS" "$T_FAIL"
	((T_FAIL == 0))
}

# nok <cmd...>: assert that a command fails. (`! cmd` does not trip errexit.)
nok() { if "$@"; then fail "expected failure: $*"; fi; }
