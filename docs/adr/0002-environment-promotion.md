# ADR 0002: Promote the manifests dev → staging → prod

- Status: accepted
- Date: 2026-09-28 (MAIR-345), amended 2026-09-30 (MAIR-346: `bootstrap/`
  promotion, staging verification in the workflow)

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

MAIR-345 left two gaps, closed by MAIR-346:

- `bootstrap/` (cert-manager, sealed-secrets, ingress-nginx / Traefik,
  ClusterIssuers) is applied by the root `platform` Application, which follows
  `main`: a version bump there reached every instance at once.
- Promoting to prod relied on a `staging_verified` checkbox, because GitHub
  runners cannot reach the instance API servers (WireGuard, from the group's
  Argo CD machine only) to run `scripts/verify.sh`.

## Decision

### 1. One branch per environment (MAIR-345)

| Environment | Revision |
|---|---|
| dev | `main` |
| staging | `staging` |
| prod | `prod` |

- The map lives in Ansible only (`deploiment_env_revisions`, group_vars
  `all.yml`). The instances AppSet renders it as a Go template
  `index (dict …) .path.basename`. An environment absent from the map follows
  `deploiment_repo_branch`.
- `staging` and `prod` only move through the manual `Promote` workflow
  (`.github/workflows/promote.yaml`): fast-forward only; a commit must already
  be in `main` to reach `staging`, and be `staging`'s head to reach `prod`;
  the full `cicd.yaml` runs again on the promoted commit; `prod` needs the
  staging verification below and the `promote-prod` GitHub environment
  approval.
- Rollback is the same workflow with `rollback: true`, which force-pushes the
  branch back to an older commit already in its history (checks and
  verification skipped).

### 2. `bootstrap/` follows each machine's revision (MAIR-346)

- **Revision source.** Ansible annotates every Argo CD cluster Secret of an
  instance with `mairie360.fr/revision: <branch>`, resolved from the same
  `deploiment_env_revisions` map (default `deploiment_repo_branch`), next to
  the `mairie360.fr/role|org|env|ingress` labels. It is the single source of
  an instance's revision on the bootstrap side: the map is not copied into
  this repo. Every instance AppSet of `bootstrap/appsets/` (goTemplate,
  clusters generator) turns it into `values.revision`, falling back to `main`
  when the annotation is absent, and uses it as `targetRevision`.
- **Where versions live: wrapper charts.** A chart version written in an
  AppSet manifest is read by `platform` from `main`, whatever the target
  revision says. So each Helm-based addon becomes a git-sourced wrapper chart,
  `bootstrap/addons/<addon>/`: `Chart.yaml` with the upstream chart as its
  only dependency (the pinned version), a committed `Chart.lock` (digest,
  checked by Argo CD's `helm dependency build`), and `values.yaml` with the
  values nested under the dependency name. The AppSet source is
  `path: bootstrap/addons/<addon>` at `values.revision`, with the same
  `releaseName` as before. `bootstrap/cluster-addons/` (plain manifests) is
  read the same way. Rendering the wrappers gives the same manifests as the
  previous Helm-repo sources with inline values, only the `# Source:` comments
  differ, so switching an Application over changes no live object.
- **What stays on `main`**, and so still reaches every machine at once:
  `platform-app.yaml`, the AppSet manifests themselves (selectors, sync
  policies, the revision expression, the addon's path) and
  `image-updater-app.yaml`, which runs on the Argo CD machine rather than on
  an instance. The AppSets hold no version and no values; CI refuses an
  instance AppSet with a `chart:` source or a `targetRevision` other than
  `values.revision`.
- `cert-manager-appset.yaml` and `bootstrap/addons/cert-manager/values.yaml`
  stay free of any domain or IP (MAIR-157), also checked by CI.

Alternatives rejected:

- **Multi-source with a `$values` ref** at the cluster's revision: it
  promotes the values but not the chart version, which stays in the AppSet
  read from `main`. It also brings back two sources per Application (MAIR-173).
- **Matrix generator (clusters × git files)** reading a versions file at the
  cluster's revision: it works through templated generator fields, but the
  chart would still come from a Helm repository at a version interpolated by
  the ApplicationSet controller, a less common pattern that is harder to
  render and test locally than a chart, and Renovate cannot bump it.
- **One `platform` Application per environment** (or `platform` following
  each branch): `platform` runs on the Argo CD machine and targets every
  instance of the group, so it cannot follow several revisions; one per
  environment would need Ansible to render the env → branch map into more
  manifests.
- **Rendering the bootstrap AppSets from Ansible**, like the instances AppSet:
  moves the versions out of this repo and out of Renovate's reach.

### 3. Staging is verified by the workflow (MAIR-346)

- A **self-hosted runner** is registered by Ansible on the group's Argo CD
  machine, at the repository level of `mairie360/Deploiment`, labels
  `self-hosted`, `linux`, `mairie360-argocd-<org_id>`
  (`mairie360-argocd-mairie360` for our group; `.github/actionlint.yaml`
  declares it). It is ephemeral and runs as the unprivileged user
  `gh-runner`. Its only cluster credential is
  `/home/gh-runner/.kube/instance-staging.yaml`, bound to a ServiceAccount of
  the staging instance limited to what `scripts/verify.sh` needs (the list
  is at the top of that script): no Secret read, no `pods/exec`, nothing
  outside `mairie360-staging` but the `cilium` DaemonSet and the
  `hubble-relay` Deployment of `kube-system`. The runner reaches the staging
  API server through the tunnel the machine already has; it adds no network
  path to an instance or to another group.
- `promote.yaml` gets a `verify-staging` job for `target=prod` (not for
  rollbacks), after `validate` and before the approval-gated `promote` job,
  on that runner. It runs only under `workflow_dispatch`, checks out the
  promoted commit without persisting the token, and calls
  `KUBECONFIG=/home/gh-runner/.kube/instance-staging.yaml ./scripts/verify.sh <context> staging <domain>`,
  where `<context>` is the kubeconfig's current context and `<domain>` is
  `global.domain` of `clusters/mairie360/instances/staging/values.yaml` at
  the promoted commit (read by the `resolve` job). `promote` requires it to
  succeed for prod; `staging_verified` is gone.
- **Only `staging`'s head can be promoted to prod** (the `resolve` job
  refuses any other commit): it is the only commit the live staging instance
  can vouch for. Promoting an older staging commit is no longer possible.
- The runner never sees pull request code: `promote.yaml` has no other
  trigger, `cicd.yaml` and `k8s-e2e.yaml` run on GitHub-hosted runners, and
  the repository requires approval before running workflows from outside
  contributors' fork pull requests (a fork PR could otherwise add a job
  targeting the label).

### Not covered / follow-up

- **The workflow does not check that staging actually runs the promoted
  commit.** Staging's instance Application syncs by itself since MAIR-444
  (ansible `deploiment_auto_sync_envs`), but only on Argo CD's next refresh,
  so right after a promotion to staging `verify.sh` may vouch for the
  previous commit. Until then, check that staging is Synced at the promoted
  commit in Argo CD before promoting to prod. Checking that the live staging
  Applications are Synced and Healthy at the promoted SHA is handled in a
  later epic on verifying prod promotions.

## Consequences

- Chart, values, sealed secrets **and bootstrap versions/values** of an
  environment are promoted together; a `prod/values.yaml` edit, a new
  `secrets.yaml` or a bump in `bootstrap/addons/` is not live on prod until
  promoted. The bootstrap Applications keep automated sync, so they apply a
  promoted bump without a manual sync, unlike the staging/prod instance
  Applications.
- A new path referenced by an AppSet (a new addon) needs two PRs: add the
  path and promote it, then reference it; otherwise the staging/prod
  Applications fail with "path does not exist" until it is promoted.
- Promote to prod fails by itself when `verify.sh` fails on staging, e.g.
  today on a `secrets.yaml` sealed before the Keycloak or admin keys existed.
- `verify.sh` checks Secret keys on the SealedSecrets (ciphertext length) and
  probes Redis with an unauthenticated `PING` from a throwaway pod, instead of
  reading Secrets and exec-ing into the Redis pod. Its two checks that need a
  plaintext value (`ADMIN_PASSWORD` is an argon2id hash, MAIR-414; the Redis
  and Postgres role passwords are URL-safe, MAIR-531) only run when the
  context may read Secrets (`kubectl auth can-i get secrets`), i.e. by hand;
  on the runner they are skipped, and what they guard against still fails
  the run through the Liquibase Job (step 7) or crash-looping APIs (steps
  1-2). `tests/scripts/mair_346_verify_no_secret_read_test.sh` pins that the
  script reads no Secret with such a context.
- `pods create` still lets a caller mount any Secret of the namespace in a pod
  of its own: Ansible is expected to restrict the runner's ServiceAccount to
  the probe pods `verify.sh` creates (see the script header) with an
  admission policy.
- The AppSet generator still lists `clusters/<org>/instances/*` on
  `deploiment_repo_branch`: a new environment directory must be promoted
  before its Application can render.
- Force-push protection on `staging` / `prod` must let the workflow's
  rollback through, or rollbacks are done by hand.

## Rollout

MAIR-345:

1. Merge the Deploiment and ansible changes.
2. Run `Promote` with `target=staging`, then `target=prod` once, to create
   both branches at the current `main` head. They must exist before the
   AppSet is re-rendered.
3. Create the `promote-staging` and `promote-prod` environments in the repo
   settings (required reviewers on prod).
4. Re-run the `k8s_argocd` role (through `playbooks/site.yml`) so the AppSet
   gets the per-environment `targetRevision`.

MAIR-346 (order matters: an annotated cluster reads `bootstrap/addons/` at
its branch, which must already contain it):

1. Merge the Deploiment change. No cluster carries `mairie360.fr/revision`
   yet, so every bootstrap Application reads `main`; the rendered objects are
   unchanged.
2. Promote it to staging (staging syncs by itself), before the self-hosted runner
   exists. Promoting it to prod needs `verify-staging`, so that run waits for
   step 3; until then `prod` lacks `bootstrap/addons/`.
3. Run the ansible side: runner registration, staging kubeconfig and RBAC,
   and the `mairie360.fr/revision` annotation, **only on clusters whose
   branch already contains `bootstrap/addons/`** (dev and staging after
   step 2). Annotate prod, and every client prod, only after the promotion to
   prod of step 4.
4. Run `Promote` with `target=prod`: `verify-staging` runs on the new runner.
5. Annotate the prod clusters.
6. Repository settings: Actions → "Require approval for all external
   contributors" for fork pull requests; keep the `promote-prod` required
   reviewers.

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

## Amendment (MAIR-745, 2026-11-02): the environment branches are kept

On 2026-10-23 the `staging` and `prod` branches were deleted, both at
`3c006cc` (the MAIR-612 prod release). Ansible (`deploiment_env_revisions`),
`Promote`, this ADR and the image-updater's staging write-back all still rely
on them, so the staging and prod Applications had no revision to follow and
every promotion was refused. The decision of this ADR stands (one branch per
environment; MAIR-492 keeps "versions per environment on `main`" as a later
target, which would supersede this ADR explicitly):

- both branches were recreated at `3c006cc`, the commit Argo CD last
  deployed on staging and prod, so recreating them changed nothing on either
  environment;
- the "environment branches protection" ruleset refuses their deletion and
  any non-fast-forward push. A `rollback: true` Promote therefore needs a
  ruleset bypass for the run, as the Consequences above already warned;
- `.github/workflows/environment-branches.yaml` runs
  `scripts/check-env-branches.sh` on every branch deletion, every day and on
  demand, and fails when either branch is missing, for the cases the ruleset
  does not cover (ruleset disabled or edited).
