# shellcheck shell=bash
# Shared helpers for Docker-based integration tests.
#
# Isolation: every resource is created with a random run id and the label
# mbtest=<run id>, on an --internal network with no published ports, and is
# removed on exit. Connection settings are generated here and passed
# explicitly with `docker run -e`; nothing is taken from the caller's
# environment except IMAGE and MYSQL_SERVER_IMAGE, which must be image names.

set -euo pipefail
IMAGE=${IMAGE:-mysql-backup:dev}
MYSQL_SERVER_IMAGE=${MYSQL_SERVER_IMAGE:-mysql:8.0.37}
for v in IMAGE MYSQL_SERVER_IMAGE; do
	[[ ${!v} =~ ^[a-zA-Z0-9./:@_-]+$ ]] || { echo "invalid $v" >&2; exit 2; }
done

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
RUN_ID=mbtest-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
NET=$RUN_ID-net
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$RUN_ID.XXXXXX")
ROOT_PW=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
BACKUP_PW="Bk-$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)\"'\\x"
LABEL=(--label "mbtest=$RUN_ID")

cleanup() {
	local ids
	ids=$(docker ps -aq --filter "label=mbtest=$RUN_ID")
	[[ -n $ids ]] && docker rm -f $ids >/dev/null 2>&1
	ids=$(docker volume ls -q --filter "label=mbtest=$RUN_ID")
	[[ -n $ids ]] && docker volume rm $ids >/dev/null 2>&1
	docker network rm "$NET" >/dev/null 2>&1 || true
	rm -rf -- "$WORK"
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

net_create() { docker network create --internal "${LABEL[@]}" "$NET" >/dev/null; }

# start_mysql <name>: disposable server, data on tmpfs, no published ports
start_mysql() {
	docker run -d --name "$RUN_ID-$1" --network "$NET" --network-alias "$1" "${LABEL[@]}" \
		--tmpfs /var/lib/mysql:rw,size=1g \
		-e MYSQL_ROOT_PASSWORD="$ROOT_PW" \
		"$MYSQL_SERVER_IMAGE" --event-scheduler=ON >/dev/null
}

wait_mysql() {
	local i
	for i in $(seq 1 90); do
		if docker exec -e MYSQL_PWD="$ROOT_PW" "$RUN_ID-$1" mysql -uroot -h127.0.0.1 -N -e 'SELECT 1' >/dev/null 2>&1; then
			return 0
		fi
		sleep 2
	done
	docker logs "$RUN_ID-$1" | tail -20 >&2
	die "mysql $1 did not become ready"
}

# sql <server> [db] : run SQL from stdin as root inside the server container
sql() {
	docker exec -i -e MYSQL_PWD="$ROOT_PW" "$RUN_ID-$1" mysql -uroot -h127.0.0.1 --default-character-set=utf8mb4 -N -B ${2:+"$2"}
}

volume() { docker volume create "${LABEL[@]}" "$RUN_ID-$1" >/dev/null; printf '%s' "$RUN_ID-$1"; }

# mb <extra docker args...> -- <command...>: run the image under test
mb() {
	local -a dargs=()
	while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
	shift
	docker run --rm --network "$NET" "${LABEL[@]}" --init "${dargs[@]}" "$IMAGE" "$@"
}
