# syntax=docker/dockerfile:1.7
#
# mysql-backup: Oracle MySQL logical dumps with local staging and optional
# verified delivery.
#
# The dump client is Oracle's own mysqldump from the official MySQL image,
# pinned by digest. The image is used only as a client: mysqld is never
# started. MYSQL_CLIENT_VERSION documents the pinned client and must match the
# image below (checked at build time).

ARG MYSQL_IMAGE=docker.io/library/mysql:8.0.37@sha256:598bf8b783dddc9070e9011aeb1eb5947f0bf7c4eda8ac510906556b8a2b6d0a
ARG MYSQL_CLIENT_VERSION=8.0.37

FROM ${MYSQL_IMAGE}

ARG MYSQL_CLIENT_VERSION
ARG VERSION=0.0.0-dev
ARG REVISION=unknown
ARG CREATED=unknown

# util-linux-core provides flock, findmnt and mountpoint. MySQL repositories
# are disabled so the pinned MySQL client is never upgraded. Available OS
# security updates are applied at build time; released images are tested after
# this step and are never rebuilt under the same tag.
# The optional build secret "extra_ca" exists only for builds behind a TLS
# intercepting proxy; it is removed again in the same layer and is not used
# by the release workflow.
RUN --mount=type=secret,id=extra_ca,required=false \
    set -eux; \
    bundle=/etc/pki/tls/certs/ca-bundle.crt; \
    if [ -s /run/secrets/extra_ca ]; then cp "$bundle" /tmp/ca-bundle.orig; cat /run/secrets/extra_ca >> "$bundle"; fi; \
    microdnf -y --disablerepo='mysql*' --setopt=install_weak_deps=0 --nodocs update; \
    if [ -s /run/secrets/extra_ca ]; then cp "$bundle" /tmp/ca-bundle.orig; cat /run/secrets/extra_ca >> "$bundle"; fi; \
    microdnf -y --disablerepo='mysql*' --setopt=install_weak_deps=0 --nodocs install util-linux-core; \
    microdnf clean all; \
    if [ -f /tmp/ca-bundle.orig ]; then cp /tmp/ca-bundle.orig "$bundle"; rm -f /tmp/ca-bundle.orig; fi; \
    rm -rf /var/cache/yum /var/cache/dnf /var/lib/dnf/history*; \
    mysqldump --version | grep -q "Ver ${MYSQL_CLIENT_VERSION} " ; \
    command -v flock findmnt mountpoint gzip sha256sum gawk

COPY --chmod=0755 runtime/bin/mysql-backup /opt/mysql-backup/bin/mysql-backup
COPY --chmod=0755 runtime/lib/ /opt/mysql-backup/lib/
COPY LICENSE THIRD_PARTY_NOTICES.md /usr/share/licenses/mysql-backup/
RUN set -eux; \
    echo "${VERSION}" > /opt/mysql-backup/VERSION; \
    ln -s /opt/mysql-backup/bin/mysql-backup /usr/local/bin/mysql-backup; \
    mkdir -p /staging /destination; \
    chown mysql:mysql /staging /destination

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
      org.opencontainers.image.base.name="docker.io/library/mysql:${MYSQL_CLIENT_VERSION}" \
      io.github.tensegrity-labs.mysql-backup.mysql-client-version="${MYSQL_CLIENT_VERSION}"

ENV MB_ROOT=/opt/mysql-backup \
    STAGING_DIR=/staging \
    DELIVERY_DIR=/destination \
    TMPDIR=/tmp

# Unprivileged by default (uid/gid 999 = "mysql" in the base image). Override
# with `user:` in Compose to match the owner of your staging directory.
USER mysql:mysql
WORKDIR /tmp

ENTRYPOINT ["/opt/mysql-backup/bin/mysql-backup"]
CMD ["run"]
