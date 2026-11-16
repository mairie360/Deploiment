# Release manifests (MAIR-1006)

`releases/<version>.yaml` defines a release of the platform (the global package `X.Y.Z`): the
commit of each service repo's `main` frozen when the release starts.

```yaml
version: "1.0.0"
created: "2026-11-16T17:00:00Z"
repos:
  Database:
    sha: 0123456789abcdef0123456789abcdef01234567   # full sha of main's commit
    dev_tag: dev-0123456                           # its image on dev
    semver: null                                   # "3.4.0" once the repo is released to prod
  Core_API: ...
```

- Every repo of `scripts/release-manifest.py` (`REPOS`: Database, the 6 APIs, the 7 BFFs, the 8
  fronts) appears exactly once.
- The promotions of the release run on those commits: `gh workflow run promote-staging.yml -f
  sha=<sha>` then `promote-prod.yml -f sha=<sha>`. A commit merged on `main` after the manifest
  (Renovate) is not promoted and does not block the release.
- Create one with `scripts/release-manifest.py new <version>` (needs `gh` logged in): for each repo,
  main's newest commit with a pipeline (release journal and `[skip ci]` commits left out). A manifest
  is never rewritten; only `semver` is filled in as repos reach prod.
- CI (`cicd.yaml`) runs `scripts/release-manifest.py check --remote`: format, `dev_tag` matching the
  sha, file name matching the version, and every sha existing on its repo's `main`.
