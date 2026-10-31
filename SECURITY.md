# Security policy

Please report vulnerabilities privately through GitHub's **Report a
vulnerability** button (Security → Advisories) on this repository. Do not open
a public issue.

Supported: the latest `0.x` release.

Scope notes:

- The image bundles MySQL 8.0.37 client programs, and MySQL 8.0 is past end of
  life (see [docs/compatibility.md](docs/compatibility.md)). The dump client
  only connects to the server you configure; keep that path on a private Docker
  network.
- Never attach dump files, logs containing data, or credentials to a report.
