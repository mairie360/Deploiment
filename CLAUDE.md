# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps deployment repo for **Mairie360**, a microservices platform (Epitech EIP project).
Argo CD watches this repo and deploys everything with Helm. There is no application
code here — only Helm charts, per-environment values, and Argo CD bootstrap manifests.

The platform is 7 backend APIs (Rust), 7 BFFs (Node), and 8 frontends (Node), plus
PostgreSQL, Redis, and a Liquibase migration job. Services: `core`, `project`,
`calendar`, `message`, `email`, `files`, `elearning` (+ `administrator` front only).
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

# Generate an instance's SealedSecrets (required before its first sync)
./scripts/seal-secrets.sh <kube-context> mairie360 dev

# Acceptance test of a deployed instance
./scripts/verify.sh <kube-context> dev dev.mairie360-eip.fr

# Argo CD admin password (on the group's Argo CD machine)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Machine provisioning is **not** done from this repo — see `mairie360/ansible`.
`scripts/bootstrap-node.sh` remains for preparing an isolated machine by hand.

CI (`.github/workflows/cicd.yaml`, on push to `main`/`develop` and all PRs):
`gitleaks` (blocking) → `helm lint` + render **and `kubeconform`** every
instance (blocking) → `helm unittest` (blocking) → `trivy config`
(non-blocking until app images declare a non-root USER).

## Architecture

### Topology: one Argo CD + one Mairie360 instance per machine

A **group** is one Argo CD machine plus its instance machines. `mairie360` has
4 machines (argocd, dev, staging, prod); a client has 2 (argocd, prod).

Each Argo CD only ever manages the instances of its own group. There is **no
shared hub**: a compromised client Argo CD has no network route to any other
group. Isolation comes from the topology, not from a naming convention — which
is why a client env named `prod` cannot collide with mairie360's `prod`.

Machine provisioning lives in the `mairie360/ansible` repo (roles `k8s_node`,
`k8s_argocd`, `k8s_instance_link`). This repo only describes desired state.

### Argo CD bootstrap chain

1. Ansible (`k8s_argocd`) installs Argo CD on the group's Argo CD machine, then
   applies `bootstrap/platform-app.yaml` **once**.
2. `platform-app` is the root Application (app-of-apps). It syncs
   `bootstrap/appsets/` recursively.
3. Ansible also renders and applies the **instances ApplicationSet** from
   `roles/k8s_argocd/templates/instances-appset.yaml.j2` — it is not in this
   repo because it depends on `org_id` (which `clusters/<org>/` to scan).

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

### The umbrella chart: `charts/mairie360-stack` (v0.3.x)

Umbrella `type: application` chart with 6 local subcharts (`file://` deps):
`database`, `redis`, `liquibase`, `APIs`, `BFFs`, `Fronts`.

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
  `message-api`, `elearning-api` — the 5 APIs with a schema; `email-api` /
  `files-api` have no repo yet, so no role). The `APIs` chart gives an
  instance in that list `DB_USER`/`DB_PASSWORD` from its own role and
  password; any other instance gets no `DB_USER`/`DB_PASSWORD` at all rather
  than falling back to the superuser. The Liquibase job additionally reads
  each `<ROLE>_PASSWORD` and passes it as a changelog parameter
  (`-D<role>_password`, role name underscored) so the `Devops/Database`
  changelog can `CREATE ROLE ... PASSWORD :role_password` and grant it
  table-level access to its module's schema, without the password ever
  appearing in the chart. **Credentials aren't the only boundary**: the
  `database` NetworkPolicy only admits `app.kubernetes.io/component: api` and
  `component: migration` pods on 5432 — BFFs and fronts have no network path
  to Postgres at all, they only ever reach it through an API.
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
  `1` migrations → `2` APIs → `3` BFFs → `4` Fronts → `5` Ingress.

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
`email-api` (SMTP) and `files-api` (S3) are declared in `egressAllowCIDRs`.

### Chart unit tests (`charts/mairie360-stack/tests/`)

`helm unittest` asserts what rendering alone cannot: that policy selectors match
the labels actually set on pods, that no secret is inlined, that the migration
Job is Argo-CD-safe, and that an image without an explicit tag fails the render.

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
- **The GHCR PAT leaked into git history.** `configs/ghcr-registry-secret.yaml`
  and every `image.pullSecretData` have been removed, but the token is still
  readable in past commits: rotate it, then purge history (`git filter-repo`).
- `helm lint` on subcharts standalone fails (they need umbrella `global.*`);
  CI lints the umbrella only and validates subcharts through the per-env render.
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
- **Rotating `POSTGRES_PASSWORD` or a `<ROLE>_PASSWORD` doesn't rotate the
  live role.** Postgres only reads `POSTGRES_PASSWORD` on first init, and the
  Liquibase changelog only reads a `<ROLE>_PASSWORD` changelog parameter on
  the `CREATE ROLE` changeset, which doesn't rerun. A `--rotate` needs a
  matching `ALTER ROLE ... PASSWORD` run by hand.
- `.env` (gitignored, not tracked) holds a real GHCR token and GitHub App creds
  used for local registry auth — never commit it.

## Known gaps (not addressed in this chart)

- No database backups. `database` is a plain StatefulSet: no PITR, no failover,
  no restore procedure. CloudNativePG is the intended replacement.
- `runAsNonRoot: false` in every `containerSecurityContext`: the app images do
  not declare a non-root `USER`. Fix the Dockerfiles, then flip the flag and
  make the `trivy config` CI job blocking.
- No `PodDisruptionBudget`, no `HorizontalPodAutoscaler`, no resource quota.
- No monitoring: `global.monitoringNamespace` opens the NetworkPolicy for
  Prometheus, but nothing is deployed yet.
