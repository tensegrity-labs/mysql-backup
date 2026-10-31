#!/usr/bin/env bash
# Evidence test (not part of the release gate): shows why this project uses
# Oracle's mysqldump. The same synthetic schema is dumped from MySQL 8.0.37
# with the MariaDB dump client and restored into a fresh MySQL 8.0.37 server.
# Expected outcome: the restore fails with ERROR 3105 on a generated column.
. "$(dirname -- "$0")/common.sh"
MARIADB_IMAGE=${MARIADB_IMAGE:-mariadb:11.4}
[[ $MARIADB_IMAGE =~ ^[a-zA-Z0-9./:@_-]+$ ]] || die "invalid MARIADB_IMAGE"

step "servers"
net_create
start_mysql source
start_mysql recovery
wait_mysql source
wait_mysql recovery
{ echo "CREATE DATABASE appdb; USE appdb;"; cat "$ROOT/tests/fixtures/schema.sql"; } | sql source

step "dump with the MariaDB client ($MARIADB_IMAGE); --skip-ssl only because the test server uses a self-signed certificate"
docker run --rm --network "$NET" "${LABEL[@]}" -e MYSQL_PWD="$ROOT_PW" --entrypoint sh "$MARIADB_IMAGE" -c \
	'mariadb-dump --skip-ssl -h source -uroot --single-transaction --routines --triggers --events appdb' | gzip >"$WORK/mariadb.sql.gz"
ls -l "$WORK/mariadb.sql.gz"

step "restore into MySQL 8.0.37"
echo "CREATE DATABASE appdb_restore;" | sql recovery
if out=$(gzip -dc "$WORK/mariadb.sql.gz" | sql recovery appdb_restore 2>&1); then
	echo "$out"; echo "RESULT: restore of the MariaDB-client dump SUCCEEDED (regression not reproduced)"
	exit 1
fi
echo "$out" | tail -n 3
grep -q 'ERROR 3105' <<<"$out" || die "failed, but not with ERROR 3105"
echo "RESULT: MariaDB-client dump fails to restore into MySQL 8.0.37 with ERROR 3105 (reproduced)."
