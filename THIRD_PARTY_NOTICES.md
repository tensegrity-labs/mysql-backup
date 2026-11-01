# Third-party notices

The **source code in this repository** (scripts, Compose files, tests,
documentation) is licensed under the MIT License. See [LICENSE](LICENSE).

The **container images** published from this repository are derived works that
bundle third-party software under its own licenses. The MIT License does not
apply to those components, and nothing here changes their terms.

| Component | Where it comes from | License |
|---|---|---|
| MySQL Community 8.0.37 client programs `mysqldump` and `mysql` (unmodified binaries) | Copied from the official Docker image `docker.io/library/mysql:8.0.37`, pinned by digest in the [Dockerfile](Dockerfile) | GPL-2.0 with the Universal FOSS Exception, v1.0. The upstream `LICENSE` and `README` ship in the image at `/usr/share/licenses/mysql-community-client/`. |
| Oracle Linux 9 slim userland (bash, coreutils, gzip, gawk, findutils, tzdata, util-linux-core, OpenSSL, libstdc++, zlib, ncurses, glibc and others) | Base image `docker.io/library/oraclelinux:9-slim` pinned by digest, plus packages from the Oracle Linux 9 repositories added at build time | Various open-source licenses (GPL, LGPL, BSD, MIT, Apache and others), listed per package under `/usr/share/licenses/` in the image |

## Source availability

- MySQL Community Server source: <https://dev.mysql.com/downloads/mysql/> (select
  version 8.0.37, "Source Code"), and <https://github.com/mysql/mysql-server/tree/mysql-8.0.37>.
- Oracle Linux 9 source RPMs: <https://yum.oracle.com/oracle-linux-9.html> and
  <https://oss.oracle.com/ol9/SRPMS-updates/>.
- Each release lists the exact package set in its SBOM, which is attached to
  the GHCR image as an attestation (see [docs/releasing.md](docs/releasing.md)).

If you redistribute the image, keep these notices and the license files inside
the image.
