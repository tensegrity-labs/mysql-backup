#!/usr/bin/env bash
# Static checks are separate (tests/static.sh). This runs the unit/component
# tests INSIDE the image under test, with no network and disposable tmpfs
# mounts. Only the variables listed here reach the container.
set -euo pipefail
IMAGE=${IMAGE:-mysql-backup:dev}
here=$(cd -- "$(dirname -- "$0")" && pwd)
suites=("$@")
((${#suites[@]})) || suites=(cron retention local capacity delivery status)

rc=0
for s in "${suites[@]}"; do
	echo "== unit/$s ($IMAGE)"
	docker run --rm --network none --init \
		--tmpfs /staging:rw,size=64m,uid=999,gid=999,mode=0755 \
		--tmpfs /destination:rw,size=64m,uid=999,gid=999,mode=0755 \
		--tmpfs /small:rw,size=8m,uid=999,gid=999,mode=0755 \
		--tmpfs /tmp:rw,exec,size=64m,mode=1777 \
		-v "$here:/tests:ro" \
		--entrypoint bash "$IMAGE" "/tests/unit/test_$s.sh" || rc=1
done
exit $rc
