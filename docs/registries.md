# Registries: GHCR and Docker Hub

**GHCR (`ghcr.io/tensegrity-labs/mysql-backup`) is the canonical registry.**
Docker Hub is an optional mirror of the *same* tested digests.

## Comparison

| | GHCR | Docker Hub |
|---|---|---|
| Discoverability | Linked from the GitHub repository and its releases | Docker Hub search is where many users look first |
| Anonymous pulls of public images | Supported; no published pull-rate limit for public packages | 100 pulls per 6 hours per IPv4 address or IPv6 /64 for unauthenticated users. Authenticated free (Personal) accounts have a higher 6-hour limit. Paid plans: no pull limit, subject to fair use. |
| Namespace | `tensegrity-labs` org exists; packages follow the repository | Needs a Docker Hub organisation or user named for Tensegrity Labs. **None was found or configured for this project.** |
| Credentials in CI | Built-in `GITHUB_TOKEN` with `packages: write`; no stored secret | Needs a Docker Hub access token stored as a repository secret |
| Provenance and SBOM | Attestations stored next to the image; verifiable with `gh attestation verify` | The same OCI attestations are copied with the mirror |
| Maintenance | None beyond the release workflow | Token rotation, a second namespace, description sync, and Docker Hub's inactive-image policies |

Docker Hub figures come from Docker's "usage and limits" documentation, as
summarised by search results on 2026-10-31. Fetching
`docs.docker.com/docker-hub/usage/` directly was not possible from the build
environment. Re-check the current numbers before relying on them.

## Recommendation

Publish to GHCR only until there is a concrete need, such as users who cannot
reach `ghcr.io` or a wish to be listed in Docker Hub search. Then enable the
mirror. Do not create a paid Docker Hub subscription for this project:
anonymous pulls of a small infrastructure image do not need one.

## Enabling the Docker Hub mirror

The release workflow mirrors only when all three settings exist. It copies
the tested multi-architecture index and its attestations by digest with
`docker buildx imagetools create`. **It does not rebuild**, so both registries
serve byte-identical images.

1. On Docker Hub, use (or have an owner create) the organisation and an
   **existing** repository, for example `tensegritylabs/mysql-backup`.
2. Create an access token with Read & Write scope for that repository.
3. In GitHub → Settings → Secrets and variables → Actions, add:
   - variable `DOCKERHUB_REPOSITORY` = `tensegritylabs/mysql-backup`
   - secret `DOCKERHUB_USERNAME`
   - secret `DOCKERHUB_TOKEN`
4. The next release is mirrored. To mirror an existing release without a new
   release, copy its digest by hand:

   ```bash
   docker buildx imagetools create -t docker.io/tensegritylabs/mysql-backup:0.1.0 \
     ghcr.io/tensegrity-labs/mysql-backup@sha256:<digest-from-the-release-page>
   ```

## GHCR visibility

A new GHCR package can start out **private** even when the repository is
public. After the first release, an organisation owner checks:

1. github.com/orgs/tensegrity-labs/packages → `mysql-backup` → Package
   settings → Change visibility → **Public**
2. "Manage Actions access": the `mysql-backup` repository has **Write**
3. Anonymous pull works:

   ```bash
   docker logout ghcr.io; docker pull ghcr.io/tensegrity-labs/mysql-backup:0.1.0
   ```
