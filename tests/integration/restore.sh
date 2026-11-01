#!/usr/bin/env bash
# Container + restore test against real, disposable MySQL 8.0.37 servers:
#   1. load the synthetic schema into a source server;
#   2. take a dump with the image under test, using a least-privilege account
#      and a password FILE;
#   3. restore the dump with a plain `gunzip | mysql` (no project tooling)
#      into a separate, fresh recovery server under a different database name;
#   4. compare objects and data, and exercise generated columns, triggers,
#      routines and the event in the restored copy.
. "$(dirname -- "$0")/common.sh"

step "start disposable source and recovery servers ($MYSQL_SERVER_IMAGE)"
net_create
start_mysql source
start_mysql recovery
wait_mysql source
wait_mysql recovery

step "load synthetic schema and create least-privilege backup account"
{ echo "CREATE DATABASE appdb; USE appdb;"; cat "$ROOT/tests/fixtures/schema.sql"; } | sql source
esc_pw=${BACKUP_PW//\\/\\\\}; esc_pw=${esc_pw//\'/\\\'}
sql source <<SQL
CREATE USER 'backup'@'%' IDENTIFIED BY '$esc_pw';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON appdb.* TO 'backup'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup'@'%';
SQL
printf '%s\n' "$BACKUP_PW" >"$WORK/mysql_password"
chmod 644 "$WORK/mysql_password"

STG=$(volume staging)
common_env=(-e BACKUP_NAMESPACE=itest-prod -e MYSQL_HOST=source -e MYSQL_DATABASE=appdb
	-e MYSQL_USER=backup -e MYSQL_PASSWORD_FILE=/run/secrets/mysql_password
	-e STAGING_RESERVE=16M -e STAGING_RESERVE_PERCENT=0
	-v "$STG:/staging" -v "$WORK/mysql_password:/run/secrets/mysql_password:ro")

step "refuse to dump before the staging marker exists"
rc=0; mb "${common_env[@]}" -- dump >/dev/null 2>&1 || rc=$?
[[ $rc == 6 ]] || die "expected exit 6 without staging marker, got $rc"
pass "missing staging marker refused (exit 6)"
mb "${common_env[@]}" -- init-staging 2>/dev/null

step "dump with the image under test"
mb "${common_env[@]}" -- dump 2>"$WORK/dump.log" || { cat "$WORK/dump.log"; die "dump failed"; }
cat "$WORK/dump.log"
grep -q "$BACKUP_PW" "$WORK/dump.log" && die "password appeared in logs"
pass "dump succeeded; password not in logs"

# copy the dump out of the volume
mb -v "$STG:/staging:ro" -v "$WORK:/out" --user 0 --entrypoint sh -- \
	-c 'cp /staging/itest-prod/*.sql.gz /out/ && chmod 644 /out/*.sql.gz'
DUMP=$(ls "$WORK"/itest-prod-*.sql.gz)
echo "dump file: $(basename "$DUMP") ($(stat -c %s "$DUMP") bytes)"
gzip -t "$DUMP"
head_lines=$(gzip -dc "$DUMP" | head -n 5 || true)  # head closes the pipe early
grep -q 'MySQL dump 10.13  Distrib 8.0.37' <<<"$head_lines" || die "unexpected dump header"
gzip -dc "$DUMP" | tail -n 1 | grep -q '^-- Dump completed' || die "no completion trailer"
gzip -dc "$DUMP" >"$WORK/dump.sql"
grep -q 'SET @@GLOBAL.GTID_PURGED' "$WORK/dump.sql" && die "dump sets GTID_PURGED"
grep -q 'GENERATED ALWAYS AS' "$WORK/dump.sql" || die "generated column definitions missing"
grep -E -q "INSERT INTO \`widget\` \(\`id\`" "$WORK/dump.sql" ||
	die "widget INSERTs should name columns (generated columns excluded)"
pass "generated columns: definitions kept, values omitted from INSERT column lists"
pass "standard gzip'd mysqldump file with header and completion trailer"

step "restore with plain mysql client into a separate recovery server (database appdb_restore)"
echo "CREATE DATABASE appdb_restore;" | sql recovery
gzip -dc "$DUMP" | sql recovery appdb_restore
pass "restore completed without errors (no ERROR 3105 on generated columns)"

step "compare objects"
q_objects() { # normalised object inventory for a schema
	sql "$1" <<SQL
SELECT 'table', table_name, table_type, engine FROM information_schema.tables WHERE table_schema='$2'
UNION ALL SELECT 'column', CONCAT(table_name,'.',column_name), column_type, CONCAT(extra,'|',IFNULL(generation_expression,'')) FROM information_schema.columns WHERE table_schema='$2'
UNION ALL SELECT 'index', CONCAT(table_name,'.',index_name), GROUP_CONCAT(column_name ORDER BY seq_in_index), non_unique FROM information_schema.statistics WHERE table_schema='$2' GROUP BY table_name, index_name, non_unique
UNION ALL SELECT 'fk', constraint_name, referenced_table_name, delete_rule FROM information_schema.referential_constraints WHERE constraint_schema='$2'
UNION ALL SELECT 'trigger', trigger_name, event_manipulation, action_timing FROM information_schema.triggers WHERE trigger_schema='$2'
UNION ALL SELECT 'routine', routine_name, routine_type, MD5(routine_definition) FROM information_schema.routines WHERE routine_schema='$2'
UNION ALL SELECT 'event', event_name, status, interval_value FROM information_schema.events WHERE event_schema='$2'
UNION ALL SELECT 'view', table_name, MD5(REPLACE(view_definition, '\`$2\`.', '')), is_updatable FROM information_schema.views WHERE table_schema='$2'
ORDER BY 1, 2;
SQL
}
q_objects source appdb >"$WORK/objects.src"
q_objects recovery appdb_restore >"$WORK/objects.dst"
diff -u "$WORK/objects.src" "$WORK/objects.dst" || die "object inventory differs"
for k in table column index fk trigger routine event view; do
	printf '  %-8s %s\n' "$k" "$(grep -c "^$k" "$WORK/objects.src")"
done
[[ $(grep -c '^trigger' "$WORK/objects.src") == 2 && $(grep -c '^routine' "$WORK/objects.src") == 2 &&
	$(grep -c '^event' "$WORK/objects.src") == 1 && $(grep -c '^view' "$WORK/objects.src") == 1 ]] ||
	die "fixture objects missing from inventory"
pass "tables, columns (incl. generated expressions), indexes, FKs, triggers, routines, events and views match"

step "compare data"
q_data() {
	sql "$1" "$2" <<'SQL'
SELECT 'widget', COUNT(*), SUM(is_active), MD5(GROUP_CONCAT(CONCAT_WS('|', id, sku, label, price, is_active, IFNULL(sku_slot,'N'), label_upper, attrs, attr_color, HEX(blob_data), created_at) ORDER BY id SEPARATOR '\n')) FROM widget
UNION ALL SELECT 'widget_event', COUNT(*), SUM(kind='archived'), MD5(GROUP_CONCAT(CONCAT_WS('|', id, widget_id, kind, at) ORDER BY id SEPARATOR '\n')) FROM widget_event
UNION ALL SELECT 'audit_counter', COUNT(*), SUM(value), MD5(GROUP_CONCAT(CONCAT_WS('|', name, value) ORDER BY name)) FROM audit_counter
UNION ALL SELECT 'active_widget', COUNT(*), NULL, MD5(GROUP_CONCAT(CONCAT_WS('|', id, sku, label, price, attr_color) ORDER BY id SEPARATOR '\n')) FROM active_widget;
SQL
}
sql source appdb <<<"SET GLOBAL group_concat_max_len = 1073741824;" >/dev/null
sql recovery appdb_restore <<<"SET GLOBAL group_concat_max_len = 1073741824;" >/dev/null
q_data source appdb >"$WORK/data.src"
q_data recovery appdb_restore >"$WORK/data.dst"
cat "$WORK/data.src"
diff -u "$WORK/data.src" "$WORK/data.dst" || die "data differs"
grep -q '^widget	5000	' "$WORK/data.src" || die "unexpected widget row count"
pass "row counts and full-content digests match (incl. utf8mb4, JSON, BLOB, DATETIME(6))"

step "exercise restored objects"
out=$(sql recovery appdb_restore <<'SQL'
SELECT price_with_tax(10, 0.0825);
INSERT INTO widget (sku, label, price, attrs) VALUES ('SKU-NEW', 'restored ✓', 1, '{"color":"teal"}');
SELECT sku_slot, label_upper, attr_color FROM widget WHERE sku='SKU-NEW';
SELECT COUNT(*) FROM widget_event WHERE widget_id = LAST_INSERT_ID() AND kind='created';
CALL archive_sku('SKU-NEW');
SELECT is_active, IFNULL(sku_slot,'NULL') FROM widget WHERE sku='SKU-NEW';
SQL
)
echo "$out"
expected=$'10.8250\n1\tRESTORED ✓\tteal\n1\n0\tNULL'
[[ $out == "$expected" ]] || die "restored objects did not behave as expected"
# unique (sku, sku_slot): a second active row for an active SKU must fail
if echo "INSERT INTO widget (sku,label) VALUES ('SKU-00001','dup');" | sql recovery appdb_restore 2>/dev/null; then
	die "unique key on stored generated column not enforced after restore"
fi
pass "function, trigger, procedure, stored/virtual generated columns and unique key work after restore"

step "selection: newest *.sql.gz in the namespace directory is the newest completed dump"
mb "${common_env[@]}" -- dump 2>/dev/null
mb -v "$STG:/staging" --user 0 --entrypoint sh -- -c '
	echo legacy > /staging/itest-prod/202001010000.appdb.sql.gz
	touch -d 2020-01-01 /staging/itest-prod/202001010000.appdb.sql.gz
	echo junk > /staging/.mysql-backup/itest-prod/work/itest-prod-20990101T000000Z.sql.gz.123.partial
	newest_name=$(cd /staging/itest-prod && ls -1 *.sql.gz | sort | tail -n1)
	newest_mtime=$(cd /staging/itest-prod && ls -1t *.sql.gz | head -n1)
	echo "by name: $newest_name  by mtime: $newest_mtime"
	[ "$newest_name" = "$newest_mtime" ] && case $newest_name in itest-prod-*) exit 0;; esac; exit 1' ||
	die "newest-file selection is ambiguous"
pass "temporary files live outside the namespace directory and never match *.sql.gz"

echo
echo "RESTORE TEST PASSED (server image: $MYSQL_SERVER_IMAGE, backup image: $IMAGE)"
