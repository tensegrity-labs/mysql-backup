# syntax=docker/dockerfile:1.7
#
# mysql-backup: Oracle MySQL logical dumps with local staging and optional
# verified delivery.
#
# Slim client-only image. Stage 1 is the official MySQL image pinned by
# digest; only Oracle's `mysqldump` and `mysql` client binaries (plus their
# license files) are copied out of it. No MySQL server, MySQL Shell, server
# plugins or data VOLUME are carried over. Stage 2 is Oracle Linux 9 slim, the
# same distribution the official image is built on, so the binaries run
# against the system libraries they were built for (OpenSSL 3, libstdc++,
# zlib, ncurses). MYSQL_CLIENT_VERSION must match the client in MYSQL_IMAGE
# (checked at build time).

ARG MYSQL_IMAGE=docker.io/library/mysql:8.0.37@sha256:598bf8b783dddc9070e9011aeb1eb5947f0bf7c4eda8ac510906556b8a2b6d0a
ARG BASE_IMAGE=docker.io/library/oraclelinux:9-slim@sha256:38f3f1f40cd8f28d020f38d69fa30f8a9fe9f7e661dff78592f85d110ec4696d
ARG MYSQL_CLIENT_VERSION=8.0.37

FROM ${MYSQL_IMAGE} AS mysql-client

FROM ${BASE_IMAGE}

ARG MYSQL_CLIENT_VERSION
ARG VERSION=0.0.0-dev
ARG REVISION=unknown
ARG CREATED=unknown

# Runtime: bash/coreutils/gawk/gzip/findutils for the scripts, util-linux-core
# for flock/findmnt/mountpoint, tzdata for BACKUP_TZ, and the shared libraries
# the MySQL client binaries link against. Available OS security updates are
# applied at build time; released images are tested after this step and are
# never rebuilt under the same tag.
# The optional build secret "extra_ca" exists only for builds behind a TLS
# intercepting proxy; it is removed again in the same layer and is not used
# by the release workflow.
RUN --mount=type=secret,id=extra_ca,required=false \
    set -eux; \
    bundle=/etc/pki/tls/certs/ca-bundle.crt; \
    addca() { if [ -s /run/secrets/extra_ca ]; then cp "$bundle" /tmp/ca-bundle.orig; cat /run/secrets/extra_ca >> "$bundle"; fi; }; \
    addca; \
    microdnf -y --setopt=install_weak_deps=0 --nodocs update; \
    addca; \
    microdnf -y --setopt=install_weak_deps=0 --nodocs install \
        bash coreutils-single findutils gawk gzip tzdata util-linux-core \
        openssl-libs libstdc++ zlib ncurses-libs; \
    microdnf clean all; \
    if [ -f /tmp/ca-bundle.orig ]; then cp /tmp/ca-bundle.orig "$bundle"; rm -f /tmp/ca-bundle.orig; fi; \
    rm -rf /var/cache/yum /var/cache/dnf /var/lib/dnf/history* /var/log/dnf*; \
    # unprivileged runtime user; uid/gid 999 as in the official MySQL image
    echo 'mysql:x:999:999:mysql-backup:/tmp:/sbin/nologin' >> /etc/passwd; \
    echo 'mysql:x:999:' >> /etc/group

COPY --from=mysql-client /usr/bin/mysqldump /usr/bin/mysql /usr/bin/
COPY --from=mysql-client /usr/share/doc/mysql-community-server-minimal/LICENSE \
                         /usr/share/doc/mysql-community-server-minimal/README \
                         /usr/share/licenses/mysql-community-client/
COPY --chmod=0755 runtime/bin/mysql-backup /opt/mysql-backup/bin/mysql-backup
COPY --chmod=0755 runtime/lib/ /opt/mysql-backup/lib/
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/licenses/mysql-backup/

RUN set -eux; \
    echo "${VERSION}" > /opt/mysql-backup/VERSION; \
    ln -s /opt/mysql-backup/bin/mysql-backup /usr/local/bin/mysql-backup; \
    mkdir -p /staging /destination; \
    chown 999:999 /staging /destination; \
    # the copied binaries must load and report the pinned version
    mysqldump --version | grep -q "Ver ${MYSQL_CLIENT_VERSION} "; \
    mysql --version | grep -q "Ver ${MYSQL_CLIENT_VERSION} "; \
    command -v bash flock findmnt mountpoint gzip sha256sum gawk find numfmt; \
    test -f /usr/share/zoneinfo/America/Denver

LABEL org.opencontainers.image.title="mysql-backup" \
      org.opencontainers.image.description="Scheduled Oracle MySQL logical dumps with local staging, tiered retention and optional verified NFS delivery" \
      org.opencontainers.image.source="https://github.com/tensegrity-labs/mysql-backup" \
      org.opencontainers.image.url="https://github.com/tensegrity-labs/mysql-backup" \
      org.opencontainers.image.documentation="https://github.com/tensegrity-labs/mysql-backup#readme" \
      org.opencontainers.image.vendor="Tensegrity Labs" \
      org.opencontainers.image.licenses="MIT AND GPL-2.0-only WITH Universal-FOSS-exception-1.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.base.name="docker.io/library/oraclelinux:9-slim" \
      io.github.tensegrity-labs.mysql-backup.mysql-client-version="${MYSQL_CLIENT_VERSION}"

ENV MB_ROOT=/opt/mysql-backup \
    STAGING_DIR=/staging \
    DELIVERY_DIR=/destination \
    TMPDIR=/tmp

# Unprivileged by default (uid/gid 999). Override with `user:` in Compose to
# match the owner of your staging directory.
USER 999:999
WORKDIR /tmp

ENTRYPOINT ["/opt/mysql-backup/bin/mysql-backup"]
CMD ["run"]
