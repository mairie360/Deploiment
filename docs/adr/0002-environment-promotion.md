# ADR 0002: Promote the manifests dev → staging → prod

- Status: accepted
- Date: 2026-09-28

## Context

Image tags already move through the environments one at a time
(argocd-image-updater tracks `dev-<sha>` / `staging-<sha>`, prod pins a
semver). The Kubernetes manifests did not: every Application of the
`instances` ApplicationSet used `targetRevision: main` with a single source,
so the chart (`charts/mairie360-stack`) and the three `values.yaml` were read
at the same commit of `main`. Merging a chart change updated dev, staging and
prod within the same minute, with no chance to see it run on dev first.

The single source is deliberate (MAIR-173: the multi-source layout resolved the
branch twice and jammed syncs), so the solution has to keep one revision per
Application.

## Decision

One long-lived branch per environment, each Application following its own:

| Environment | Revision |
|---|---|
| dev | `main` |
| staging | `staging` |
| prod | `prod` |

- The map lives in Ansible (`deploiment_env_revisions`, group_vars `all.yml`);
  the AppSet renders it as a Go template `index (dict …) .path.basename`. An
  environment absent from the map follows `deploiment_repo_branch`.
- `staging` and `prod` only move through the manual `Promote` workflow
  (`.github/workflows/promote.yaml`): fast-forward only; a commit must already
  be in `main` to reach `staging`, and in `staging` to reach `prod`; the full
  `cicd.yaml` runs again on the promoted commit; `prod` needs the
  `promote-prod` GitHub environment approval and the `staging_verified` input.
- Rollback is the same workflow with `rollback: true`, which force-pushes the
  branch back to an older commit already in its history (checks skipped).

## Consequences

- Chart, values and sealed secrets of an environment are promoted together;
  a `prod/values.yaml` edit or a new `secrets.yaml` is not live until promoted.
- `verify.sh` cannot run from a GitHub-hosted runner (instance API servers are
  only reachable over WireGuard from the Argo CD machine), hence the manual
  `staging_verified` box. A self-hosted runner on the Argo CD machine would let
  the workflow run it and remove the box.
- The AppSet generator still lists `clusters/<org>/instances/*` on
  `deploiment_repo_branch`: a new environment directory must be promoted
  before its Application can render.
- Out of scope: `bootstrap/` (cert-manager, ingress-nginx, sealed-secrets,
  cluster-addons). The root `platform` Application follows `main` and applies
  to every instance at once; those version bumps are not staged yet.
- Force-push protection on `staging` / `prod` must let the workflow's
  rollback through, or rollbacks are done by hand.

## Rollout

1. Merge the Deploiment and ansible changes.
2. Run `Promote` with `target=staging`, then `target=prod` (`staging_verified`
   ticked) once, to create both branches at the current `main` head. They must
   exist before the AppSet is re-rendered.
3. Create the `promote-staging` and `promote-prod` environments in the repo
   settings (required reviewers on prod).
4. Re-run the `k8s_argocd` role (through `playbooks/site.yml`) so the AppSet
   gets the per-environment `targetRevision`.

## Amendment (MAIR-444, 2026-10-02): image tags in git

argocd-image-updater used to write the tags into the Applications' Helm
parameters, outside git, and did not track `database` /
`liquibase-migrations`. It now writes back to git, for every tracked image
including those two:

- **dev**: a pull request on `main` editing
  `clusters/mairie360/instances/dev/values.yaml`, titled
  `chore(deps): update <app> images`.
  `.github/workflows/image-updater-automerge.yaml` enables auto-merge on
  `image-updater-*` branches that touch nothing else, so it squash-merges
  once the required checks pass; dev auto-syncs from `main`.
- **staging**: direct commits on the `staging` branch, into
  `clusters/mairie360/instances/staging/images.yaml`, a file the AppSet reads
  after `values.yaml` and that `main` never edits. staging auto-syncs
  (ansible `deploiment_auto_sync_envs`).

So `staging` is no longer always an ancestor of `main`. `Promote` to staging
fast-forwards when it can; otherwise it **merges** the promoted commit into
`staging`, but only when the commits that are only on staging touch nothing but
`images.yaml` files and the promoted commit leaves them untouched. Anything
else is refused, as before. Prod still only fast-forwards to a commit of
`staging`; it carries staging's `images.yaml` in its history, but the prod
Application never reads another environment's directory.

Consequences: what is deployed on dev and staging is in git; a rollback of
staging also rolls its image tags back; the checks of `cicd.yaml` run on
pushes to `staging` too, so a tag that does not exist on GHCR is reported.
The tags pinned in staging's `values.yaml` only seed a fresh instance.
