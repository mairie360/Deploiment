# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps deployment repo for **Mairie360**, a microservices platform (Epitech EIP project).
Argo CD watches this repo and deploys everything with Helm. There is no application
code here — only Helm charts, per-environment values, and Argo CD bootstrap manifests.

The platform is 5 backend APIs (Rust), 7 BFFs (Node), and 8 frontends (Node), plus
PostgreSQL, Redis, a Liquibase migration job and an optional backup CronJob.
APIs: `core`, `project`, `calendar`, `message`, `elearning`. BFFs and fronts add
`dashboard` and `settings`, which have no API of their own (MAIR-134, they
replaced the never-built `email` / `files` services), plus `user`/`login` and an
`administrator` front.
Conventional ports: APIs `3000-3006`, BFFs `4000-4006`, Fronts `5000-5007`.

## Common commands

```bash
# Lint the umbrella chart (subcharts are not standalone: they need global.*)
helm lint ./charts/mairie360-stack

# Unit tests: network policies, secrets, Argo CD compatibility
helm plugin install https://github.com/helm-unittest/helm-unittest   # once
helm unittest ./charts/mairie360-stack

# Render + schema-validate every instance (this is what CI does)
for v in clusters/*/instances/*; do
  helm template r ./charts/mairie360-stack -f "$v/values.yaml" \
    | kubeconform -strict -summary -schema-location default || echo "KO: $v"
done

# Resolve subchart deps (needed before template/install; Chart.lock + .tgz gitignored)
helm dependency build ./charts/mairie360-stack

# Every rendered image exists on its registry and follows its env's tag family
# (dev-<sha> / staging-<sha> / semver). Needs skopeo; --offline = policy only.
./scripts/check-image-tags.sh

# End-to-end test of the Kubernetes layer on a throwaway Kind + Cilium cluster
# (needs docker, kind, cilium CLI, chainsaw, jq; KEEP=1 keeps the cluster)
tests/e2e/run.sh

# Generate an instance's SealedSecrets (required before its first sync).
# Normally done by ansible's playbooks/secrets.yml (phase 4 of site.yml), which
# runs this on the group's Argo CD machine — the only one reaching the instance
# API server — and prompts for RESEND_API_KEY / S3_* / AWS_* when missing.
# By hand, from /opt/Deploiment on that machine:
KUBECONFIG=/root/.kube/instance-dev.yaml ./scripts/seal-secrets.sh dev mairie360 dev

# Acceptance test of a deployed instance
./scripts/verify.sh <kube-context> dev dev.mairie360-eip.fr

# Argo CD admin password (on the group's Argo CD machine)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Machine provisioning is **not** done from this repo — see `mairie360/ansible`.
`scripts/bootstrap-node.sh` remains for preparing an isolated machine by hand.

CI (`.github/workflows/cicd.yaml`, on push to `main`/`develop` and all PRs):
`helm lint` → render **and `kubeconform`** every instance →
`scripts/check-image-tags.sh` → `helm unittest`, all blocking. `gitleaks`
and `trivy config` are not wired yet. The Kind + Cilium end-to-end suite runs
separately (`.github/workflows/k8s-e2e.yaml`).

## Architecture

### Topology: one Argo CD + one Mairie360 instance per machine

A **group** is one Argo CD machine plus its instance machines. `mairie360` has
4 machines (argocd, dev, staging, prod); a client has 2 (argocd, prod).

Each Argo CD only ever manages the instances of its own group. There is **no
shared hub**: a compromised client Argo CD has no network route to any other
group. Isolation comes from the topology, not from a naming convention — which
is why a client env named `prod` cannot collide with mairie360's `prod`.

Machine provisioning lives in the `mairie360/ansible` repo (roles `k8s_node`,
`k8s_argocd`, `k8s_instance_link`, `k8s_instance_secrets`). This repo only
describes desired state.

### Argo CD bootstrap chain

1. Ansible (`k8s_argocd`) installs Argo CD on the group's Argo CD machine, then
   applies `bootstrap/platform-app.yaml` **once**.
2. `platform-app` is the root Application (app-of-apps). It syncs
   `bootstrap/appsets/` recursively.
3. Ansible also renders and applies the **instances ApplicationSet** from
   `roles/k8s_argocd/templates/instances-appset.yaml.j2` — it is not in this
   repo because it depends on `org_id` (which `clusters/<org>/` to scan).
4. Same for **argocd-image-updater's configuration**: the chart installed by
   `image-updater-app.yaml` is v1, driven by `ImageUpdater` resources (one per
   instance, tag policy per env name), rendered by Ansible from
   `roles/k8s_argocd/templates/image-updaters.yaml.j2`. The GHCR credentials
   it reads (`argocd/ghcr-secret`) are written by the same role from
   `GHCR_USER` / `GHCR_TOKEN`; nothing in this repo creates them.

| File | Kind | Generates | Destination |
|---|---|---|---|
| `sealed-secrets-appset.yaml` | AppSet, clusters generator | `sealed-secrets-<cluster>` | instances only |
| `cert-manager-appset.yaml` | AppSet, clusters generator | `cert-manager-<cluster>` v1.16.5 | instances only |
| `cluster-issuer-appset.yaml` | AppSet, clusters generator | applies `bootstrap/cluster-addons/` | instances only |
| `ingress-nginx-appset.yaml` | AppSet, clusters generator | `ingress-nginx` 4.11.3, default IngressClass | instances only |
| `image-updater-app.yaml` | Application | `argocd-image-updater` | in-cluster (Argo CD machine) |

**The `mairie360.fr/role=instance` label** is what makes "instances only" work.
Ansible sets it during `argocd cluster add`; the clusters generator selects on
it, which excludes the Argo CD machine itself (`in-cluster`, unlabelled) — it
needs no public ingress, no cert-manager, no database.

### HTTPS chain

`ingress-nginx-appset` (nginx as **default IngressClass**, k3s installed with
Traefik disabled) → `cert-manager-appset` → `cluster-issuer-appset`
(`letsencrypt-prod` / `-staging`, HTTP-01 targeting `ingressClassName: nginx`)
→ the `cert-manager.io/cluster-issuer` annotation on the fronts Ingress.

Each instance needs public DNS for every front hostname pointing at its own IP.
**`cert-manager-appset.yaml` must stay free of any domain or IP** (MAIR-157):
it is shared by every group. The HTTP-01 self-check goes through public DNS;
it works from inside the cluster because the instance's public IP is on its
interface, so ServiceLB publishes it as the ingress-nginx LoadBalancer IP and
kube-proxy short-circuits pod traffic to it. A provider that NATs the public
IP instead would need k3s `node-external-ip` (ansible, `k8s_node`), not
`hostAliases` here.

### The umbrella chart: `charts/mairie360-stack` (v0.3.x)

Umbrella `type: application` chart with 7 local subcharts (`file://` deps):
`database`, `redis`, `liquibase`, `backup`, `APIs`, `BFFs`, `Fronts`.

- **`APIs`, `BFFs`, `Fronts` are generic multi-instance charts.** Each iterates
  `range $name, $cfg := .Values.instances` and emits one Deployment + Service per
  entry where `enabled: true`. Objects are named `<Release.Name>-<instanceName>`.
  Per-instance keys: `image.repository`, `image.tag` (**required**, no `latest`
  default), `port`, `replicaCount`, `resources`, `env`.
- **`env` goes through `tpl`**, so instance values can reference the release:
  `value: "http://{{ .Release.Name }}-calendar-api:3002/api"`. Never hardcode a
  release prefix such as `local-dev-` — it breaks as soon as `releaseName` differs.
- **Ports have a single source of truth**: `global.apis.instances.<n>.port` and
  `global.bffs.instances.<n>.port`. They drive both the Services and the
  `<NAME>_URL` env vars injected into BFFs and Fronts.
- **Labels**: every pod carries `app.kubernetes.io/component` (`api` / `bff` /
  `frontend` / `database` / `cache` / `migration`) — that is what NetworkPolicies
  select on. The legacy `app: <instance>` label is kept because
  `spec.selector` is immutable on existing Deployments/StatefulSets.
- **No secret value lives in the chart.** `JWT_SECRET`, `POSTGRES_*` and the
  Redis ACL passwords always come from Secrets. `*.secret.create` /
  `secrets.create` default to `false` (SealedSecret expected) and are only set
  to `true` for the throwaway local cluster.
- **`extraObjects`** renders raw manifests through `tpl`; this is how each
  environment's `secrets.yaml` (SealedSecrets) is injected.
- `templates/ingress.yaml` creates **one Ingress for all enabled fronts**:
  host = `<frontName minus "-front">.<global.domain>`, `ingressClassName`,
  `cert-manager.io/cluster-issuer` and annotations all read from
  `.Values.ingress.*`. APIs/BFFs are never exposed.
- `database` is a StatefulSet with a **headless** governing Service
  (`<release>-database-hl`) plus a client Service (`<release>-database`).
  Credentials come from `<release>-database-secret`.
- **Postgres access is per-role (MAIR-114).** `<release>-database-secret`
  carries `POSTGRES_USER`/`POSTGRES_PASSWORD` (the `postgres` superuser,
  used only by the `wait-for-db` init container and the Liquibase job to run
  migrations) plus one `<ROLE>_PASSWORD` key per entry of
  `global.database.roles` (`core-api`, `project-api`, `calendar-api`,
  `message-api`, `elearning-api` — the 5 APIs with a schema). The `APIs` chart gives an
  instance in that list `DB_USER`/`DB_PASSWORD` from its own role and
  password; any other instance gets no `DB_USER`/`DB_PASSWORD` at all rather
  than falling back to the superuser. The Liquibase job additionally reads
  each `<ROLE>_PASSWORD` and passes it as a changelog parameter
  (`-D<role>_password`, role name underscored) so the `Devops/Database`
  changelog can `CREATE ROLE ... PASSWORD :role_password` and grant it
  table-level access to its module's schema, without the password ever
  appearing in the chart. **Credentials aren't the only boundary**: the
  `database` NetworkPolicy only admits `app.kubernetes.io/component: api`,
  `component: migration` and `component: backup` pods on 5432 — BFFs and
  fronts have no network path to Postgres at all, they only ever reach it
  through an API.
- **`backup` (MAIR-119), off by default.** A CronJob that streams
  `pg_dump -Fc` straight into `restic backup --stdin` against an
  S3-compatible bucket — restic brings encryption at rest, dedup and
  retention (`restic forget --prune`), so the dump itself never touches a
  disk on either side. Authenticates to Postgres as the same superuser as
  Liquibase (`<release>-database-secret`), because no single per-API role
  can read every module's schema. `<release>-backup-secret`
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`RESTIC_PASSWORD`) is sealed
  the same way as the other per-instance secrets, but those AWS keys can't
  be generated — `scripts/seal-secrets.sh` only writes that Secret when
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are exported before calling
  it. `templates/restore-job.yaml` (disabled by default, `restore.enabled`)
  is the disaster-recovery counterpart: no Argo CD hook annotation, run by
  hand via `helm template … | kubectl apply -f -` (see
  `charts/backup/README.md`) rather than left enabled in a tracked values
  file, or Argo CD would recreate it every sync.
- `redis` uses ACL, not `requirepass`: an entrypoint script (in the ConfigMap)
  writes `/acl/users.acl` at container start from per-role env vars
  (`<ROLE>_REDIS_PASSWORD`, one per entry of `global.apis.instances` /
  `global.bffs.instances`) and starts `redis-server --aclfile`. The `default`
  account is disabled; `admin` (Secret key `redis-password`) is for probes and
  `helm test`. Fronts have no Redis account — they never used it. `helm test`
  asserts that an unauthenticated `PING` is refused and that `admin` works.
- `liquibase` is a Job with a **stable name**, declared as an Argo CD
  `Sync` hook at wave 1 with `hook-delete-policy: BeforeHookCreation`.
- **Sync waves**: `-2` NetworkPolicies → `-1` Secrets/ConfigMaps → `0` data →
  `1` migrations and the backup CronJob → `2` APIs → `3` BFFs → `4` Fronts →
  `5` Ingress.

### Network model

One `default-deny` policy on the whole namespace, then one allow rule per hop.
NetworkPolicies are **purely additive** — a single permissive policy
(`podSelector: {}` + `namespaceSelector: {}`) would cancel everything, so never
add one.

```
ingress-controller ─► fronts ─► bffs ─► apis ─► postgres
                                 │  └──────────► redis
                                 └─────────────► redis
              liquibase job ──────────────────► postgres
```

Toggle with `global.networkPolicy.enabled` (false on Kind — its default CNI
ignores NetworkPolicies; true on k3s). `global.networkPolicy.egressDefaultDeny`
also locks outbound traffic, but stays off until the external destinations of
`core-api` (Resend, `smtp.resend.com:587`), `elearning-api` (Scaleway Object
Storage) and the backup CronJob (S3 bucket) are declared in `egressAllowCIDRs`.

### Outbound e-mail (Resend, MAIR-94)

`core-api` sends its transactional e-mails (password reset) with `lettre` over
SMTP. Every instance's `values.yaml` sets `SMTP_HOST=smtp.resend.com`,
`SMTP_PORT=587`, `SMTP_USERNAME=resend` and `EMAIL_FROM` on `core-api`, and
reads `SMTP_PASSWORD` from the `SMTP_PASSWORD` key of `<release>-app-secrets`.
That key is the Resend API key: `scripts/seal-secrets.sh` takes it from the
`RESEND_API_KEY` env var (otherwise keeps the value already on the cluster,
otherwise seals it empty and warns). `--rotate` never clears it. The
`EMAIL_FROM` domain must be verified in the Resend dashboard, and Core API
only enables STARTTLS + auth when `SMTP_USERNAME` is non-empty.

### Admin account bootstrap (MAIR-170)

No instance ships with the `Database` template admin account
(`template.email@gmail.com` / `password_template`) reachable by default.
`<release>-database-secret` carries `ADMIN_EMAIL`/`ADMIN_PASSWORD` alongside
`POSTGRES_*` and the per-API roles; `scripts/seal-secrets.sh` takes
`ADMIN_EMAIL` from the env var of the same name (otherwise keeps the value
already on the cluster, otherwise seals it empty and warns) and generates
`ADMIN_PASSWORD` once, the first time it is sealed. The Liquibase Job passes
both as changelog parameters (`-Dadmin_email` / `-Dadmin_password`), reading
them through an **optional** `secretKeyRef` — an instance with neither key
(e2e, local `helm install` with `database.secret.create=true`) leaves the
changelog on its template admin credentials, same as no parameter at all.
Unlike every other value in that Secret, **neither key is ever touched by
`--rotate` or `--rotate-roles`**: the changelog only overwrites the admin
account while it still carries the template credentials, so once the town
hall administrator has changed their password, the sealed value would just
go stale — see the comment above `--rotate` in `scripts/seal-secrets.sh`.

### Network observability (Cilium / Hubble)

The `k3s` machines run Cilium as CNI instead of flannel (installed by the
`ansible` repo's `k8s_node` role, not by Argo CD — without a CNI no pod
starts). Cilium enforces the NetworkPolicies above and Hubble records every
flow, with its verdict, on the hops of the diagram. `scripts/hubble-flows.sh
<context> <env>` prints them hop by hop from the workstation, through a
port-forward to `hubble-relay`.

`templates/cilium-l7-visibility.yaml` adds two `CiliumNetworkPolicy` (fronts →
bffs, bffs → apis) with an L7 HTTP rule, gated by
`global.networkPolicy.ciliumL7Visibility` (off by default — a cluster without
the Cilium CRDs cannot sync it; `dev` turns it on). It only adds visibility:
it allows nothing the Kubernetes NetworkPolicies do not already allow.
`scripts/verify.sh` step 10 checks the Cilium agent and `hubble-relay` are up
(step 11 checks the latest backup Job).
`kubeconform`'s default schema store has no schema for `CiliumNetworkPolicy`:
render+validate commands need `-skip CiliumNetworkPolicy` (see **Common
commands** above), or `dev` (the only instance with `ciliumL7Visibility: true`)
reports it as an error.

### Chart unit tests (`charts/mairie360-stack/tests/`)

`helm unittest` asserts what rendering alone cannot: that policy selectors match
the labels actually set on pods, that no secret is inlined, that the migration
Job is Argo-CD-safe, and that an image without an explicit tag fails the render.

### End-to-end tests (`tests/e2e/`)

`run.sh` (also `.github/workflows/k8s-e2e.yaml`) creates a Kind cluster with
**Cilium**, the CNI of the real machines, installs the umbrella chart with
`tests/e2e/values.yaml`, then runs `helm test` and the Chainsaw tests. It
tests the Kubernetes layer, not the apps: every API/BFF/front runs
`traefik/whoami` (answers on `/health`, port from `WHOAMI_PORT_NUMBER`),
while Postgres, Redis and Liquibase keep their real public GHCR images.

- `chainsaw/stack`: migration Job done, every Service has ready endpoints,
  no pod stuck or restarted.
- `chainsaw/network-policies`: probe pods carrying each
  `app.kubernetes.io/component` try every hop (`check-flows.sh`). A denied
  flow must *time out* (Cilium drops silently); a fast failure is reported
  as an error, so a broken Service can't pass as "deny".
- `chainsaw/data-access`: Redis ACL (prefix and command restrictions) and
  the per-API Postgres role logging in with its Secret password. The latter
  depends on the `Devops/Database` images actually creating those roles.

### Values layout

```
clusters/<org>/instances/<env>/
  values.yaml     # what differs per instance: domain, image tags, sizes
  secrets.yaml    # GENERATED by scripts/seal-secrets.sh — never hand-edited
```

`values.yaml` overrides only what changes; defaults live in
`charts/mairie360-stack/values.yaml` and each subchart's `values.yaml`.
`secrets.yaml` is consumed through the chart's `extraObjects`.

There is **no local/Kind values set**: the four machines include a real `dev`,
and maintaining a parallel Kind topology is what produced the earlier
"three incompatible ways to deploy" problem. Local validation is
`helm template` + `helm unittest`.

## Gotchas

- **Subchart directory names are capitalized** (`APIs`, `BFFs`, `Fronts`) and must
  match the top-level values keys exactly.
- **`targetRevision` is `main` everywhere.** When working on a branch, Ansible's
  `repo_branch` variable repoints both `platform-app.yaml` and the rendered
  instances AppSet — do not let the two diverge, or Argo CD silently serves the
  old appsets from `main` while you edit the branch.
- **SealedSecrets are per-machine.** The sealing key belongs to one cluster's
  controller; `clusters/<org>/instances/<env>/secrets.yaml` must be generated on
  that machine with `scripts/seal-secrets.sh`. Back up every key — losing one
  makes that instance's committed secrets permanently undecryptable.
- **First sync of a new environment will fail until its secrets.yaml exists**:
  pods stay in `CreateContainerConfigError` with no Secret to mount. Expected.
  `elearning-api` stays there too when `secrets.yaml` was sealed before the
  `S3_*` keys existed: re-run `seal-secrets.sh` with `S3_ACCESS_KEY` /
  `S3_SECRET_KEY` set (`scripts/verify.sh` step 4 reports empty keys).
- **The GHCR PAT leaked into git history.** `configs/ghcr-registry-secret.yaml`
  and every `image.pullSecretData` have been removed, but the token is still
  readable in past commits: rotate it, then purge history (`git filter-repo`).
- `helm lint` on subcharts standalone fails (they need umbrella `global.*`);
  CI lints the umbrella only and validates subcharts through the per-env render.
- **Instance image tags must exist without the image-updater (MAIR-172).**
  The CICD `docker-release` action pushes `dev-<sha>` + `dev`, then
  `staging-<sha>` + `staging`, then `<version>` + `latest`; `dev-latest` /
  `staging-latest` are no longer pushed and point at stale images (on
  2026-09-22 `core-api:dev-latest` crashed on glibc, three fronts had no
  `staging-latest` at all). The mobile `dev` / `staging` tags are not an
  option either: the BFFs, `database` and `liquibase-migrations` do not push
  them yet. So dev/staging values pin an explicit `<env>-<sha>` (the family
  `image_updater_policies` tracks, `newest-build` then moves it forward) and
  prod/client values a published semver. `database` / `liquibase` are not
  handled by the image-updater: bump their `<env>-<sha>` by hand. On GHCR
  several `<env>-<sha>` of one image can share the same `Created` date
  (build cache): pick by commit date, not by `Created`.
- **Front image name mismatch**: the values key is `project-front` but the image
  is `ghcr.io/mairie360/projects-front` (plural). The image-updater alias follows
  the key, the `image-list` entry follows the image.
- **HTTP-01 means one ACME challenge per host** — 8 per environment here. All 8
  hostnames must resolve publicly to the ingress before the certificate is
  issued, and the Let's Encrypt production quota (50 certs/domain/week) burns
  fast while debugging. Start on `letsencrypt-staging`.
- **`maxSurge: 0` with `replicaCount: 1` means downtime on every deploy** (old
  pod killed before the new one is ready). Deliberate on a small VM; it is not a
  rolling update.
- **`replicaCount: 2` on Redis would give two independent caches**, not a
  replicated one. Leave it at 1.
- Redis uses `emptyDir` by default (`redis.persistence.enabled: false`): fine
  for a cache, data-losing for sessions.
- **`scripts/seal-secrets.sh`'s `REDIS_ROLES` and `DB_ROLES` lists are
  hand-maintained**, not read from the chart. `REDIS_ROLES` must be kept in
  sync with `global.apis.instances` / `global.bffs.instances`; `DB_ROLES`
  must be kept in sync with the shorter `global.database.roles` (both in
  `charts/mairie360-stack/values.yaml`) — add a role there and forget the
  script, and that API/BFF's pod comes up with no `<ROLE>-password` (Redis)
  or `<ROLE>_PASSWORD` (Postgres) key to read, `CreateContainerConfigError`.
- **Rotating `POSTGRES_PASSWORD` doesn't rotate the live superuser**: Postgres
  only reads it on first init, so a `--rotate` needs a matching
  `ALTER ROLE postgres PASSWORD` run by hand. The API `<ROLE>_PASSWORD`s are
  different: `security/api_roles.sql` is `runAlways` and does
  `ALTER ROLE ... PASSWORD` on every run, and the Liquibase Job is an Argo CD
  Sync hook, so `seal-secrets.sh --rotate-roles` + push + sync rotates them;
  then restart the API pods (env from `secretKeyRef` is read at start only).
- **Generated passwords are hex, never base64**: the APIs build
  `postgres://user:password@host:port/db` without percent-encoding, so a `/`
  in the password breaks the URL (`invalid port number`). Seen on the first
  clean deployment: 2 to 4 APIs per instance could not reach Postgres.
- `.env` (gitignored, not tracked) holds a real GHCR token and GitHub App creds
  used for local registry auth — never commit it.
- **`--rotate` on `scripts/seal-secrets.sh` regenerates `RESTIC_PASSWORD`
  too**, same as `JWT_SECRET`/`POSTGRES_PASSWORD`/ACL passwords — but restic
  derives its master key from that one password, and nothing here runs the
  equivalent of `restic key passwd` against the existing repository. Rotate
  it naively and the *whole* bucket (every past snapshot, not just future
  ones) becomes permanently unreadable. Run `restic key passwd` with the old
  and new password first, or don't rotate it at all.

## Known gaps (not addressed in this chart)

- **No PITR, no failover.** `database` is still a plain single-replica
  StatefulSet — the `backup` subchart (MAIR-119) covers point-in-time
  snapshots to off-machine S3 storage with a documented restore procedure,
  but a lost volume means restoring from the last backup, not zero data
  loss, and there is no automatic failover. CloudNativePG is the intended
  replacement for both.
- `runAsNonRoot: false` in every `containerSecurityContext`: the app images do
  not declare a non-root `USER`. Fix the Dockerfiles, then flip the flag and
  make the `trivy config` CI job blocking.
- No `PodDisruptionBudget`, no `HorizontalPodAutoscaler`, no resource quota.
- No monitoring: `global.monitoringNamespace` opens the NetworkPolicy for
  Prometheus, but nothing is deployed yet.
