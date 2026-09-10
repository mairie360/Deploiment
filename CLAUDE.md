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
# Lint the umbrella chart + every subchart (mirrors CI)
helm lint ./charts/mairie360-stack
find ./charts/mairie360-stack/charts -maxdepth 1 -type d -exec helm lint {} \;

# Resolve subchart deps (needed before template/install; produces Chart.lock + .tgz, both gitignored)
helm dependency build ./charts/mairie360-stack

# Render a given environment locally (this is the main "does my change work" check)
helm template test ./charts/mairie360-stack -f ./clusters/local/dev/values.yaml
helm template test ./charts/mairie360-stack -f ./clusters/local/staging/values.yaml
helm template test ./charts/mairie360-stack -f ./clusters/local/prod/values.yaml

# Local cluster from scratch: kind cluster + Argo CD only
./scripts/deploy.sh          # assumes docker/kind/kubectl already installed
./scripts/deploy-local.sh    # also installs the binaries (apt, Ubuntu)
./scripts/local-kill.sh      # delete kind cluster + prune docker volumes

# After deploy.sh, hand the cluster to GitOps by applying the root app:
kubectl apply -n argocd -f bootstrap/appsets/infra-app.yaml

# Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

CI (`.github/workflows/cicd.yaml`, on push to `main`/`develop` and all PRs) runs only
the lint + `helm dependency build` + `helm template` steps above. The functional
(minikube) job is commented out.

## Architecture

### Argo CD bootstrap chain

Physical topology: **4 machines / clusters** — the `argocd` host (bootstrap + hub
Argo CD, `in-cluster`) plus 3 remote clusters registered in Argo CD as `dev`,
`staging`, `prod`.

1. `scripts/deploy.sh` installs a bootstrap Argo CD on the `argocd` host, then you
   apply `bootstrap/appsets/infra-app.yaml` once.
2. `infra-app.yaml` is the **root Application** (app-of-apps). It syncs
   `bootstrap/appsets/` recursively and `configs/` into the `argocd` namespace,
   which pulls in every Application / ApplicationSet below.
3. `configs/` holds raw cluster manifests applied as-is: Argo CD ingress + insecure
   mode (`argocd-params.yaml`), a `letsencrypt-local` ClusterIssuer, Portainer
   values, and `ghcr-registry-secret.yaml` (GHCR pull creds for image-updater, in
   the `argocd` namespace).

### ApplicationSets / bootstrap Applications

| File | Kind | Generates | Destination |
|---|---|---|---|
| `hubs-appset.yaml` | AppSet, git dirs `clusters/*/argocd` | `hub-<client>` — multi-source: `argo/argo-cd` 10.8.4 + this repo as `$values` (1 Argo CD per client) | in-cluster, ns `argocd-<client>`, release `argocd-<client>`, `crds.install=false` |
| `cluster-issuer-appset.yaml` | AppSet, **clusters generator** | `cluster-issuers-<cluster>` — applies `bootstrap/cluster-addons/` | each cluster, retry for CRD readiness |
| `instances-appset.yaml` | AppSet, git dirs `clusters/*/instances/*` | `<cluster>-<env>` running `charts/mairie360-stack` | **remote cluster** by name (`dev`/`staging`/`prod`), ns `mairie360-<env>` |
| `local-app.yaml` | AppSet, git dirs `clusters/local/*` (staging/prod excluded) | `local-<env>` | in-cluster, ns `mairie360-<env>` |
| `cert-manager-appset.yaml` | AppSet, **clusters generator** (all 4 + in-cluster) | `cert-manager-<cluster>` — `jetstack/cert-manager` v1.16.5 | each cluster, ns `cert-manager` |
| `ingress-nginx-app.yaml` | Application | `ingress-nginx` chart | in-cluster |
| `image-updater-app.yaml` | Application | `argo/argocd-image-updater` chart | in-cluster, ns `argocd` |

`instances-appset.yaml` is `goTemplate: true` and uses **`templatePatch`** to
generate the full set of `argocd-image-updater.argoproj.io/*` annotations for the
~22 services, with per-env strategy derived from `path.basename`:
- `dev` → `newest-build`, `allow-tags: regexp:^dev-.*`
- `staging` → `newest-build`, `allow-tags: regexp:^staging-.*`
- `prod` → `semver`, `allow-tags: regexp:^v?X.Y.Z`

Write-back method is `argocd` (patches `spec.source.helm.parameters`, no git
commit). The AppSet sets `ignoreApplicationDifferences` on
`/spec/source/helm/parameters` so its controller does not revert what image-updater
writes. Image-updater runs with `--applications-api=kubernetes` (patches the
Application CRs directly) and reads GHCR via `pullsecret:argocd/ghcr-secret`.
Each service needs `helm.image-name` / `helm.image-tag` pointing at
`APIs|BFFs|Fronts.instances.<name>.image.repository|tag` — that mapping is what the
`templatePatch` builds.

### The umbrella chart: `charts/mairie360-stack`

Umbrella `type: application` chart with 6 local subcharts (`file://` deps):
`database`, `redis`, `liquibase`, `APIs`, `BFFs`, `Fronts`.

- **`APIs`, `BFFs`, `Fronts` are generic multi-instance charts.** Each iterates
  `range $name, $cfg := .Values.instances` and emits one Deployment (+ Service) per
  entry where `enabled: true`. Objects are named `<Release.Name>-<instanceName>`.
  Per-instance keys: `image.repository`, `image.tag`, `port`, `replicaCount`, `env`
  (a raw list appended to the container env), `resources`.
- Shared env (DB creds, Redis, cross-service `*_URL`) is injected via
  `apis.commonEnv` / `bffs.commonEnv` / `fronts.commonEnv` helpers. `bffs.commonEnv`
  builds `<API>_URL` vars from `global.apis.instances`.
- `charts/mairie360-stack/templates/ingress.yaml` (umbrella level) creates **one
  Ingress for all enabled fronts**: host = `<frontName minus "-front">.<global.domain>`,
  `ingressClassName` / `cert-manager.io/cluster-issuer` / annotations from
  `.Values.ingress.{className,clusterIssuer,annotations}`, one multi-SAN TLS secret
  `<fullname>-fronts-tls` issued by cert-manager. APIs/BFFs are **not** exposed
  (ClusterIP only; fronts reach BFFs in-cluster via `fronts.commonEnv`).
- **HTTPS chain**: `cert-manager-appset` (cert-manager on every cluster) →
  `cluster-issuer-appset` (`bootstrap/cluster-addons/cluster-issuers.yaml` —
  `letsencrypt-prod` / `-staging` / `-local`, HTTP-01, **default IngressClass**) →
  the fronts Ingress annotation. Each target cluster needs an ingress controller
  marked default IngressClass and public DNS for `*.<domain>` → the ingress LB.
- `database` is a StatefulSet; its Secret is `<Release.Name>-database-secret`.
  `redis` Secret is `<Release.Name>-redis` (key `redis-password`).
- `liquibase` is a `batch/v1` Job re-created every sync (name suffixed with a
  timestamp), waits for the DB, runs `changelog.xml update` from `/migrations`.
- `templates/registry-secret.yaml` creates the `ghcr-secret` dockerconfigjson Secret
  only when `image.pullSecretData` is set (it is, per-env, as a base64 blob).
  All Deployments reference `imagePullSecrets: [name: ghcr-secret]` (hardcoded).

### Environment values layout

- `clusters/local/{dev,staging,prod}/` — full standalone value files, consumed by
  `instances-appset` / `local-app` and by CI `helm template`. `dev` pins images to
  `dev-<gitsha>` tags; `staging` uses `staging-latest`; `prod` uses `latest` / semver.
- `clusters/mairie360/instances/{dev,staging,prod}/` — consumed by
  `instances-appset`, deployed to the remote `dev`/`staging`/`prod` clusters.
  **`dev` and `prod` values files are empty** → `helm template` / sync fails for
  them (missing `global.database`, `global.apis`, …); only `staging` is populated
  and renders. Fill them (copy `staging/values.yaml` and adjust) before those
  environments can sync.
- `clusters/mairie360/argocd/values.yaml` — top-level values for the `argo/argo-cd`
  chart (consumed by `hubs-appset` as `$values`).
- Each env dir also has a `Chart.yaml` declaring a `file://` dependency on
  `mairie360-stack` (used if deploying that dir directly rather than via the umbrella).

## Gotchas

- **Subchart directory names are capitalized** (`APIs`, `BFFs`, `Fronts`) and must
  match the top-level values keys exactly.
- **`targetRevision` / `revision` is inconsistent**: `hubs-appset`,
  `instances-appset`, `cert-manager-appset` point at branch `mair-33-clean-helm-config`;
  `infra-app` and `local-app` point at `main`. Nothing on this branch takes effect
  until it is merged to `main` (or `infra-app.yaml` is repointed) — `infra-app`
  reads `main` and serves the old versions of the appsets from there.
- **Multi-tenant model**: one Argo CD per client (`clusters/<client>/argocd/` →
  `hub-<client>` in ns `argocd-<client>`), managed by the bootstrap/management
  Argo CD in ns `argocd`. `instances-appset` still runs in the **management**
  Argo CD (scans `clusters/*/instances/*`); moving each client's instances under
  its own hub is not done yet.
- `helm lint` on the subcharts standalone fails (they need umbrella `global.*`);
  CI lints the umbrella only. `helm template` for every `clusters/local/*` env now
  passes. `clusters/mairie360/instances/{dev,prod}/values.yaml` are still empty →
  those envs won't render until filled.
- `clusters/mairie360/instances/staging/values.yaml` inter-service URLs are stale
  (`local-staging-latestf:4000` …). With `instances-appset` setting
  `releaseName: <env>`, services are `<env>-<name>` (e.g. `staging-user-bff`).
- Front image name mismatch: the values key is `project-front` but the image is
  `ghcr.io/mairie360/projects-front` (plural). The image-updater alias in
  `instances-appset.yaml` follows the key (`project-front`), the `image-list` entry
  follows the image (`projects-front`).
- Secrets are committed in plaintext (`POSTGRES_PASSWORD`, `JWT_SECRET: 'b"secret"'`,
  and the **same base64 GHCR auth** in `clusters/local/*/values.yaml`
  `image.pullSecretData` and `configs/ghcr-registry-secret.yaml`). The GHCR PAT has
  leaked into git history — it should be rotated and moved to a SealedSecret /
  ExternalSecret. Until then, don't add more copies.
- `.env` (gitignored, not tracked) holds a real GHCR token and GitHub App creds used
  for local registry auth — never commit it.
