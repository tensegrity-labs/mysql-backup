#!/usr/bin/env bash
# Static checks: no Docker daemon or network needed (except `docker compose
# config`, which only parses files).
set -euo pipefail
cd "$(dirname -- "$0")/.."
rc=0
step() { printf '== %s\n' "$*"; }

step "bash syntax"
for f in runtime/bin/mysql-backup runtime/lib/*.sh tests/*.sh tests/unit/*.sh tests/integration/*.sh tests/fixtures/fakebin/*; do
	bash -n "$f" || rc=1
done

step "shellcheck"
shellcheck -x -s bash -S warning runtime/bin/mysql-backup runtime/lib/*.sh \
	tests/*.sh tests/unit/*.sh tests/integration/*.sh tests/fixtures/fakebin/* || rc=1

step "compose files render with the example environment"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp deploy/.env.example "$tmp/.env"; mkdir -p "$tmp/secrets"; : >"$tmp/secrets/mysql_password"
for f in deploy/compose.yaml deploy/compose.local-only.yaml; do
	docker compose --project-directory "$tmp" -f "$f" --env-file "$tmp/.env" config --quiet || rc=1
done
# the schedule must survive .env parsing intact
docker compose --project-directory "$tmp" -f deploy/compose.yaml --env-file "$tmp/.env" config |
	grep -q 'BACKUP_SCHEDULE: 0 6-21 \* \* \*' || { echo "schedule not parsed as expected"; rc=1; }

step "example configuration uses documentation addresses only"
allowed='192[.]0[.]2[.]|198[.]51[.]100[.]|203[.]0[.]113[.]|127[.]0[.]0[.]1|0[.]0[.]0[.]0'
ipv4='(^|[^0-9.])([0-9]{1,3}[.]){3}[0-9]{1,3}([^0-9.]|$)'
mapfile -t docs < <(git ls-files 'deploy/*' '*.md')
if bad=$(grep -nE -e "$ipv4" -- "${docs[@]}" | grep -vE -e "$allowed"); then
	printf '%s\n' "$bad"; echo "non-documentation IPv4 address found above"; rc=1
fi

step "no secrets or dumps tracked"
if git ls-files | grep -vx 'tests/fixtures/schema.sql' | grep -E '\.(sql|sql\.gz|gz|pem|key|p12)$|(^|/)\.env$|secrets/'; then
	echo "tracked file looks like a dump or secret"; rc=1
fi

exit $rc
