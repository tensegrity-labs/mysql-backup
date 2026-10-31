# Releasing

Releases are cut from the default branch by pushing a tag `vX.Y.Z`. The tag must equal
`runtime/VERSION`.

```bash
# on the default branch, after CI is green
echo 0.1.1 > runtime/VERSION && $EDITOR CHANGELOG.md
git commit -am "Release 0.1.1" && git push
git tag -a v0.1.1 -m "v0.1.1" && git push origin v0.1.1
```

`.github/workflows/release.yml` then runs these jobs:

1. **prepare**: checks that the tag matches `runtime/VERSION`, that the
   commit is on the default branch, and that `ghcr.io/…:X.Y.Z` does not already exist.
2. **build**: one multi-platform build (`linux/amd64`, `linux/arm64`) with
   BuildKit SBOM and max-mode provenance. It is pushed to GHCR **by digest
   only**, with no tag.
3. **test**: on native amd64 and arm64 runners, pulls that digest and runs
   the unit/component tests, the MySQL 8.0.37 restore test and the Compose
   test. On amd64 it also runs the real loopback-NFS test.
4. **publish**, only if every test job passed:
   - tags the tested digest (`X.Y.Z`, `X.Y.Z-mysqlA.B.C`, `X.Y`, `latest`;
     `X` from 1.0 onwards) with `imagetools create`, so there is no rebuild;
   - adds a GitHub build-provenance attestation;
   - optionally mirrors the same digest to Docker Hub ([registries](registries.md));
   - creates the GitHub release with the digest.

Security properties:

- Workflows default to `contents: read`. Each job requests only what it needs:
  `packages: write` for build and publish, `id-token` and `attestations` for
  attestation, and `contents: write` only for creating the release.
- Pull requests run `ci.yml` only. It has a read-only token, no secrets and
  no registry login. `pull_request_target` is not used. Publishing requires
  pushing a tag, which only maintainers can do. Optionally protect `v*` tags
  with a tag ruleset.
- Third-party actions are referenced by major version. Pin them to commit
  SHAs if your policy requires it.

If a release turns out to be broken, publish a new patch release. Never
re-tag.
