# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps deployment repo for **Mairie360**, a microservices platform (Epitech EIP project).
Argo CD watches this repo and deploys everything with Helm. There is no application
code here — only Helm charts, per-environment values, and Argo CD bootstrap manifests.

The platform is 5 backend APIs (Rust), 7 BFFs (Node), and 8 frontends (Node), plus
PostgreSQL, Redis, a Liquibase migration job, a backup CronJob (MAIR-119/MAIR-231, on
for every tracked instance), and an optional OpenTelemetry Collector (MAIR-131 POC). There is no
identity provider besides core-api (Keycloak was removed, MAIR-804).
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
# once, as CI does: the release archive (it holds the binary) checked against the
# SHA256 of .github/workflows/cicd.yaml, then unpacked in the plugins directory
curl -sSLfo /tmp/hu.tgz https://github.com/helm-unittest/helm-unittest/releases/download/v0.8.2/helm-unittest-linux-amd64-0.8.2.tgz
echo "56ab3091e6fa52a7c92ee951def9bed957f295d9ce98483aed404e748d7b3a94  /tmp/hu.tgz" | sha256sum -c -
mkdir -p "$(helm env HELM_PLUGINS)/unittest" && tar -xzf /tmp/hu.tgz -C "$(helm env HELM_PLUGINS)/unittest"
helm unittest ./charts/mairie360-stack

# Render + schema-validate every instance with both ingress controllers,
# plus bootstrap/ (this is what CI does). CRD schemas (Traefik Middleware,
# Argo CD AppSets, CiliumNetworkPolicy) come from the datreeio CRDs-catalog.
# CI also runs `helm lint --strict` with each instance's values (MAIR-541) and
# shellcheck (warnings and errors) on every *.sh. charts/mairie360-stack/values.schema.json
# closes the list of top-level and `global` keys: add a new top-level or global
# key there, or helm refuses the values.
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
for v in clusters/*/instances/*; do for c in nginx traefik; do
  helm template r ./charts/mairie360-stack -f "$v/values.yaml" --set global.ingressController=$c \
    | kubeconform -strict -summary -schema-location default -schema-location "$CRDS" \
    || echo "KO: $v ($c)"
done; done
kubeconform -strict -schema-location default -schema-location "$CRDS" bootstrap/appsets bootstrap/cluster-addons
# Bootstrap wrapper charts (MAIR-346), as CI renders them
# (scripts/addon-deps.sh adds the upstream repos to a throwaway Helm config first)
for c in bootstrap/addons/*/; do ./scripts/addon-deps.sh "$c" && helm template "$(basename "$c")" "$c" --include-crds \
  | kubeconform -strict -summary -schema-location default -schema-location "$CRDS" -skip CustomResourceDefinition; done

# Resolve subchart deps (needed before template/install; Chart.lock + .tgz gitignored)
helm dependency build ./charts/mairie360-stack

# Every rendered image exists on its registry and follows its env's tag family
# (dev-<sha> / staging-<sha> / semver). Needs skopeo; --offline = policy only.
./scripts/check-image-tags.sh

# Every Secret / key the pods reference is sealed in the instance's
# secrets.yaml (MAIR-414). Blocking in Promote, --warn in CI.
./scripts/check-instance-secrets.sh

# Every instance AppSet of bootstrap/appsets/ reads bootstrap/ at its
# machine's revision, no chart repository, no fixed revision (MAIR-346, CI)
./scripts/check-bootstrap-revisions.sh

# Release manifests (MAIR-1006, releases/README.md): freeze the commit of each
# service repo's main for a platform release (promotions then run with -f sha=),
# and check them (CI runs `check --remote`: every sha is on its repo's main)
./scripts/release-manifest.py new 1.2.0
./scripts/release-manifest.py check --remote

# Values files of an instance, in the instances AppSet's order
# (clusters/_base/<env>.yaml, values.yaml, [secrets.yaml]): every render goes
# through it.
./scripts/instance-values.sh clusters/mairie360/instances/prod --secrets

# End-to-end test of the Kubernetes layer on a throwaway Kind + Cilium cluster
# (needs docker, kind, cilium CLI, chainsaw, jq; KEEP=1 keeps the cluster)
tests/e2e/run.sh

# Generate an instance's SealedSecrets (required before its first sync).
# Normally done by ansible's playbooks/secrets.yml (phase 4 of site.yml), which
# runs this on the group's Argo CD machine — the only one reaching the instance
# API server — and prompts for RESEND_API_KEY / S3_* / AWS_* when missing.
# By hand, from /opt/Deploiment on that machine:
KUBECONFIG=/root/.kube/instance-dev.yaml ./scripts/seal-secrets.sh dev mairie360 dev

# Acceptance test of a deployed instance.
# The Promote workflow runs it on staging before prod (MAIR-346); the RBAC it
# needs is listed at the top of the script.
./scripts/verify.sh <kube-context> dev dev.mairie360-eip.fr

# restic snapshots of an instance's backup bucket (MAIR-244): throwaway pod
# built from <env>-backup, extra arguments go to restic (read-only commands only)
./scripts/list-snapshots.sh <kube-context> dev

# Argo CD admin password (on the group's Argo CD machine)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Machine provisioning is **not** done from this repo — see `mairie360/ansible`.
`scripts/bootstrap-node.sh` remains for preparing an isolated machine by hand.

CI (`.github/workflows/cicd.yaml`, on push to `main`/`develop` and all PRs):
`helm lint` → render **and `kubeconform`** every instance (nginx and traefik)
and `bootstrap/` → render the `bootstrap/addons/` wrapper charts and check
that every instance AppSet reads its machine's revision
(`scripts/check-bootstrap-revisions.sh`, MAIR-346) →
`scripts/check-image-tags.sh` → `helm unittest`, all blocking, plus
`scripts/check-instance-secrets.sh --warn` (annotations only).
The `secret-scan` job runs Gitleaks (mairie360/CICD `actions/security/gitleaks`)
on the new commits of every push/PR and blocks on any finding (MAIR-677). Rules are
`.gitleaks.toml`: defaults plus one allowlist, the `KEY: Ag…` SealedSecret ciphertext
lines of `clusters/*/instances/*/secrets.yaml`; `tests/scripts/mair_677_secret_scan_test.sh`
pins it. Supply chain: every third-party action is pinned by commit SHA with its tag in a
comment (`@<sha> # v7`; Renovate's pinDigest keeps both), `cicd.yaml` runs with
`permissions: contents: read`, and every tool fetched with curl (kubeconform, helm-unittest,
kind, cilium CLI, chainsaw) is checked against a `*_SHA256` written next to its version before
use: a version bump changes both in one commit (`tests/scripts/mair_686_ci_pins_test.sh`).
`trivy config` is not wired yet. The Kind + Cilium
end-to-end suite runs separately (`.github/workflows/k8s-e2e.yaml`).
`.github/workflows/promote.yaml` is the manual main → staging → prod promotion
(it calls `cicd.yaml` as a reusable workflow on the promoted commit, refuses to
move the branch while `scripts/check-instance-secrets.sh` reports a Secret or
key missing from a target instance's `secrets.yaml` (MAIR-414), and, for prod,
runs `scripts/verify.sh` against staging on the self-hosted runner of the
Argo CD machine, see Gotchas). `.github/actionlint.yaml` declares that
runner's label.

## Platform RGAA rate (`scripts/rgaa-global.py`)

`gate` (job `rgaa-global` of `Promote`, target prod, not on a rollback; `promote` needs it not
failed) reads the fronts of `clusters/_base/prod.yaml` at the promoted commit (`FRONTS` maps each
image to its repo: add a new front there or the gate fails with exit 2), downloads the
`rgaa-report.json` asset of each front's release `v<tag>` (attached by mairie360/CICD promote-prod; the front
repos are public, the run's token is enough) and computes the official global rate (a criterion
invalid on one front is invalid for the platform; validated only when validated on every front
that declares it; validated / decided, rounded down). The summary lists the failing criteria per
front, pages and elements; below `--min` (50) it exits 1. A front without a report is listed and
left out; no report at all → warning, pass. `note <version>` writes the platform release note
(French, `releases/<version>.yaml`), checked by `check_note` (heading levels, one title, table
headers, link text, emoji); `.github/workflows/release-note.yml` publishes it as the release
`platform-v<version>`. Tests: `tests/rgaa/` (CI, fake `gh`). Docs: `docs/en|fr/rgaa-global-rate.md`.

## GDPR decisions (`compliance/`, MAIR-294)

`compliance/<org>/` holds a mairie's GDPR decisions (`register.yaml`, `retention.yaml`,
`subprocessors.yaml`, `access.yaml`, `deadlines.yaml`, see `compliance/README.md`); every org of
`clusters/` needs one. `scripts/check-compliance.py` (CI, after the renders; tests in
`tests/compliance/`) renders each instance of `retention.yaml`'s `applies_to` and fails when the
retention CronJob's periods (`retention.policies`, written into `retention_policies` before every
purge), the backup retention, an external host or an egress CIDR does not follow the decisions, or
when the register is incomplete, or when `global.legal` (the legal pages of the fronts, MAIR-292:
`LEGAL_CONFIG` of the fronts of `Fronts.legalConfigInstances`, i.e. login-front) shows other periods
or subprocessors; for the prod instances (MAIR-293) it also fails on an
infrastructure gap (egress not denied by default, backups off or without bucket) unless
`compliance/<org>/accepted-gaps.yaml` accepts it with its reason (today: egress, DNS-only
subprocessors; `tests/gdpr_prod_test.yaml` pins backups, retention and default-deny ingress);
decisions without `validated: {date, by}` are warnings
(`--strict` makes them fail). A period changes in the decision file and in the values together.

## Usage telemetry (`observability.usage`, MAIR-501)

The collector keeps only `observability.spanAttributesAllowlist` on every span
(`transform/span-allowlist`, `keep_keys(span.attributes, …)`), so traces carry actions, never a
user id, query string, body, client address or user agent. With `observability.usage.enabled`, it
also scrapes `/internal/usage` of the services listed in `observability.usage.services`
(`<release>-<name>:<port>`; the APIs/BFFs serve their usage ledger there, `mairie360_api_lib::usage`
/ bffs-lib), keeps only the ledger series and their labels, drops counts under
`observability.usage.threshold` again (`filter/usage-threshold`) and exports the ledger to the
instance's Cockpit metrics, plus Mairie 360 when `observability.usage.export` is enabled (endpoint
required, host to declare in `compliance/<org>/subprocessors.yaml`). The network policy
`…-usage-scrape` lets only the collector reach those ports. Validate a config change with
`docker run otel/opentelemetry-collector-k8s:<tag> validate --config=…` (kubeletstats off).

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
   `bootstrap/appsets/` recursively, from `main`: those AppSet manifests hit
   every machine at once, so they only say **where** and **at which
   revision**. Versions and values live in the wrapper charts of
   `bootstrap/addons/<addon>/` (`Chart.yaml` pins the upstream chart,
   `Chart.lock` committed, `values.yaml` nests the upstream values under the
   dependency name), which each instance AppSet reads at the machine's own
   revision: the Argo CD cluster annotation **`mairie360.fr/revision`**
   written by Ansible from `deploiment_env_revisions`, `main` when absent
   (MAIR-346, ADR 0002). So a bootstrap version bump follows
   main → staging → prod like the chart; changing an AppSet manifest itself
   (selector, sync policy) still reaches every machine at once.
3. Ansible also renders and applies the **instances ApplicationSet** from
   `roles/k8s_argocd/templates/instances-appset.yaml.j2` — it is not in this
   repo because it depends on `org_id` (which `clusters/<org>/` to scan).
4. Same for **argocd-image-updater's configuration**: the chart installed by
   `image-updater-app.yaml` is v1, driven by `ImageUpdater` resources (one per
   dev / staging instance, tag policy per env name; prod and client instances
   have none since MAIR-186, their tags are the ones pinned here), rendered by
   Ansible from `roles/k8s_argocd/templates/image-updaters.yaml.j2`. They
   write to git only (MAIR-444). The GHCR credentials it reads
   (`argocd/ghcr-secret`) and the write-back token
   (`argocd/deploiment-git-creds`) are written by the same role from
   `GHCR_USER` / `GHCR_TOKEN` and `DEPLOIMENT_GIT_USER` /
   `DEPLOIMENT_GIT_TOKEN`; nothing in this repo creates them.

| File | Kind | Generates | Destination |
|---|---|---|---|
| `sealed-secrets-appset.yaml` | AppSet, clusters generator | `sealed-secrets-<cluster>` from `bootstrap/addons/sealed-secrets` (2.22.0, key renewal off) | instances only |
| `cert-manager-appset.yaml` | AppSet, clusters generator | `cert-manager-<cluster>` from `bootstrap/addons/cert-manager` (v1.21.2) | instances only |
| `cluster-issuer-appset.yaml` | AppSet, clusters generator | applies `bootstrap/cluster-addons/` | instances only |
| `ingress-nginx-appset.yaml` | AppSet, clusters generator | `bootstrap/addons/ingress-nginx` (4.15.1, last release, retired upstream), default IngressClass | instances **not** labelled `mairie360.fr/ingress=traefik` |
| `traefik-appset.yaml` | AppSet, clusters generator | `bootstrap/addons/traefik` (chart 41.6.0 = v3.7.13) | instances labelled `mairie360.fr/ingress=traefik` |
| `image-updater-app.yaml` | Application | `argocd-image-updater` 1.3.1, pinned in the manifest, follows `main` | in-cluster (Argo CD machine) |
| `projects.yaml` | AppProjects (wave -1) | `mairie360-platform` (the rows above) and `mairie360-instances` (the instances AppSet, ansible) | Argo CD machine |

**AppProjects (MAIR-414).** Nothing but the root `platform` Application stays
in `default`. `mairie360-platform` admits the add-ons' chart repositories and
namespaces (cluster-scoped kinds allowed: CRDs, webhooks, RBAC);
`mairie360-instances` admits this repository only, `mairie360-*` namespaces
only, and no cluster-scoped kind but `Namespace` and the collector's
`ClusterRole`/`ClusterRoleBinding`. A new add-on chart repository or
namespace must be added to `bootstrap/appsets/projects.yaml`, or its
Application is refused.

The AppSets (all but `image-updater-app.yaml` and `projects.yaml`) read this
repo at the `mairie360.fr/revision` of their cluster (`goTemplate`, clusters
generator `values.revision`).

**The `mairie360.fr/role=instance` label** is what makes "instances only" work.
Ansible sets it during `argocd cluster add`; the clusters generator selects on
it, which excludes the Argo CD machine itself (`in-cluster`, unlabelled) — it
needs no public ingress, no cert-manager, no database.

**The `mairie360.fr/ingress` label (MAIR-260)** picks the ingress controller
of a machine: `traefik` → Traefik, absent or anything else → ingress-nginx.
Only one can own 80/443 (ServiceLB). Ansible writes it from the host var
`ingress_controller` (`k8s_instance_link`, `site.yml --tags labels`). Both
controller AppSets carry the Argo CD resources finalizer, so a flip deletes
the old controller. The instance values must agree:
`global.ingressController`.

### HTTPS chain

`ingress-nginx-appset` or `traefik-appset` (one per machine, default
IngressClass; k3s's bundled Traefik stays disabled so the version is pinned
here) → `cert-manager-appset` → `cluster-issuer-appset` (`letsencrypt-prod` /
`-staging`, HTTP-01 solver class `traefik` by default since MAIR-795, `nginx` before) → the
`cert-manager.io/cluster-issuer` annotation on the fronts Ingress, plus
`acme.cert-manager.io/http01-ingress-ingressclassname: <instance class>`,
which overrides the solver class per Ingress. With Traefik, HTTP → HTTPS is
the web entrypoint's redirect pinned at **priority 1**, so the solver router
(`pathType: Exact`) always answers on port 80: keep it the lowest.

**cert-manager copies that annotation onto the Certificate only when it
creates it** (as `acme.cert-manager.io/http01-override-ingress-ingressclassname`)
and never updates it (MAIR-795). A Certificate created before the annotation
existed, or while the machine ran another ingress controller, keeps the wrong
class or none, and a Certificate with none uses the ClusterIssuer default
(`nginx` until MAIR-795, `traefik` since every instance runs Traefik): on a
machine of the other class its HTTP-01 challenges answer 404 forever and the
renewal stalls without any alert (prod fronts, 2026-11-06). Fix:
`kubectl -n mairie360-<env> delete certificate <name>`; the owning Ingress makes
cert-manager recreate it with the right class, and the TLS Secret (no owner
reference) keeps being served meanwhile. `scripts/verify.sh` step 12c fails on
any such Certificate (`scripts/lib/cert-solvers.sh`,
`tests/scripts/mair_795_cert_solver_test.sh`); `CLUSTER_ISSUER_DEFAULT_SOLVER`
there must stay equal to the ClusterIssuers' solver class in
`bootstrap/cluster-addons/cluster-issuers.yaml`, and the test checks it. The
step needs `list` on Certificates and Ingresses: it is skipped, not failed,
with a context that lacks it, so the Promote workflow only enforces it once
ansible's `github_runner` role grants those two reads. Changing the
ClusterIssuers' default itself is not part of this: that file is read from
`main` by every machine until the `mairie360.fr/revision` annotation is rolled
out (MAIR-346).

Each instance needs public DNS for every front hostname pointing at its own IP.
**`cert-manager-appset.yaml` and `bootstrap/addons/cert-manager/` must stay free of any domain or IP** (MAIR-157, checked by CI):
it is shared by every group. The HTTP-01 self-check goes through public DNS;
it works from inside the cluster because the instance's public IP is on its
interface, so ServiceLB publishes it as the ingress controller's LoadBalancer IP and
kube-proxy short-circuits pod traffic to it. A provider that NATs the public
IP instead would need k3s `node-external-ip` (ansible, `k8s_node`), not
`hostAliases` here.

**ingress-nginx is retired upstream (March 2026)**: 4.15.1 is its last
release and gets no more security fixes. It is being replaced by Traefik one
machine at a time (dev → staging → prod, with rollback): decision and
procedure in `docs/adr/0001-replace-ingress-nginx.md` (accepted, MAIR-260).
`ingress-nginx-appset.yaml` is deleted once prod has switched. Keep
controller >= v1.13.2 while cert-manager >= 1.18 is used: its HTTP-01 solver
Ingress uses `pathType: Exact` (MAIR-228).

### The umbrella chart: `charts/mairie360-stack` (v0.6.x)

Umbrella `type: application` chart with 9 local subcharts (`file://` deps):
`database`, `redis`, `liquibase`, `backup`, `retention`,
`observability`, `APIs`, `BFFs`, `Fronts`.

- **`APIs`, `BFFs`, `Fronts` are generic multi-instance charts.** Each iterates
  `range $name, $cfg := .Values.instances` and emits one Deployment + Service per
  entry where `enabled: true`. Objects are named `<Release.Name>-<instanceName>`.
  Per-instance keys: `image.repository`, `image.tag` (**required**, no `latest`
  default), `port`, `replicaCount`, `resources`, `env`.
- **Non-root, read-only pods (MAIR-229).** Each of the three charts sets a
  pod `securityContext` with a numeric uid/gid (`APIs` 65532 distroless
  `nonroot`, `BFFs` 1000 `node`, `Fronts` 1001 `nextjs`/`nodejs`, matching
  the images' Dockerfiles), `readOnlyRootFilesystem: true`,
  `automountServiceAccountToken: false`, and mounts `writableDirs` as
  `emptyDir` (`/tmp` everywhere, plus `/app/.next/cache` for fronts). A new
  image with another user, or an app that writes elsewhere, needs these
  values changed; `tests/security_context_test.yaml` pins them.
- **Client IP (MAIR-226).** ingress-nginx runs with
  `use-forwarded-headers: "false"` and Traefik with `forwardedHeaders`
  trusting no IP: nothing sits in front of them, so they overwrite
  `X-Forwarded-For` with the TCP peer instead of trusting the client's
  header. Every BFF gets `TRUST_PROXY=loopback, <global.trustedProxyCIDRs>`
  (default `10.42.0.0/16`, the k3s pod CIDR = ansible `k3s_cluster_cidr`),
  so Express skips in-cluster proxies (ingress, fronts) and BFF_user's
  per-IP rate limits see the browser. Change both together if the pod CIDR
  changes; never list a public range. An instance `env` entry
  `TRUST_PROXY` replaces the injected one. The fronts of
  `Fronts.trustIngressIpHeadersInstances` (`login-front`, the only one that
  reads it) get `TRUST_INGRESS_IP_HEADERS=true` under the same condition
  plus `global.networkPolicy.enabled` (the ingress must be the only way in),
  or they would not relay the client IP to BFF_user at all (MAIR-414,
  `tests/trust_ingress_headers_test.yaml`).
- **BFFs get only what they read (MAIR-414).** No `DB_*` (no BFF has a
  database). Since MAIR-531 each BFF does get `REDIS_*` and its own Redis
  ACL account (`~<bff>:*`, no `revoked:*`, no channel), ahead of the bffs-lib
  Redis client (MAIR-499): the password `secretKeyRef` is `optional`, so a
  `secrets.yaml` sealed before those accounts neither blocks the BFFs nor
  Redis (the account is then written `off`). `JWT_SECRET` goes to
  `BFFs.jwtSecretInstances`: MAIR-414 kept it to `user-bff`, but since
  MAIR-474 every BFF verifies the session itself (bffs-lib `requireSession`)
  and refuses to start without it, so the list names all seven (MAIR-520; on
  dev the six others crash-looped and blocked the Argo CD sync of the fronts).
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
- **Session tokens: core-api alone signs (MAIR-680, audit A1).** Until then
  one HS256 `JWT_SECRET` reached the 5 APIs and 7 BFFs, so any compromised pod
  could forge an administrator token. Now core-api signs with an Ed25519 key
  (`JWT_PRIVATE_KEY`, EdDSA) and every API and BFF (compliance-api included)
  verifies with `global.jwt.publicKey`, injected in clear as
  `JWT_PUBLIC_KEY` (PEM, several `PUBLIC KEY` blocks during a rotation;
  `""` = not injected). `global.jwt.signing.enabled` gives `JWT_PRIVATE_KEY`
  (`<release>-jwt-signing-secret`, sealed) to the instance named `core-api`
  and to nothing else; `templates/jwt-session-keys.yaml` fails the render
  when signing is on without a public key, or when `publicKey` is not made of
  complete Ed25519 `PUBLIC KEY` blocks or holds a `PRIVATE KEY`. `scripts/seal-secrets.sh` generates the pair once
  per instance (`openssl genpkey -algorithm ed25519`), seals the private key,
  never replaces it (not even with `--rotate`, and a failed read of the
  Secret stops it), and prints the public key to paste into the instance's
  `values.yaml` (it is plain config, reviewed in the diff; the ansible role
  shows that output). `tests/mair_680_jwt_session_keys_test.yaml`,
  `tests/scripts/mair_680_seal_signing_key_test.sh`, `scripts/verify.sh`
  step 5b (no workload but core-api reads `JWT_PRIVATE_KEY`).
  **Rollout order per instance:** seal + paste `publicKey` (harmless: services
  keep accepting HS256 while `JWT_SECRET` is set) → every API/BFF image
  verifies EdDSA (API_lib / bffs-lib MAIR-680) → `signing.enabled: true` →
  after `JWT_TIMEOUT`, drop `JWT_SECRET` (follow-up branch
  `mair-680-drop-jwt-secret`). Turning signing on before every image
  verifies EdDSA logs every user out of the older services.
- **`extraObjects`** renders raw manifests through `tpl`; this is how each
  environment's `secrets.yaml` (SealedSecrets) is injected.
- `templates/ingress.yaml` creates **one Ingress for all enabled fronts**:
  host = `<frontName minus "-front">.<global.domain>`. **Everything
  controller-specific derives from `global.ingressController`** (`nginx` |
  `traefik`, MAIR-260) through `templates/_helpers.tpl`: `ingressClassName`
  (unless `ingress.className`), the controller namespace the NetworkPolicies
  admit (unless `global.ingressNamespace`), the HTTPS redirect and the body
  limit `ingress.maxBodySizeMiB` (nginx annotations, or Traefik
  `router.entrypoints: websecure` + a `buffering` Middleware from
  `templates/traefik-middlewares.yaml`, rendered only for traefik since the
  CRD does not exist on an nginx machine). `ingress.annotations` are added
  last and win. Instance values never carry controller annotations anymore.
  APIs/BFFs are never exposed.
- `templates/websocket-ingress.yaml` is the **WebSocket Ingress**
  `<release>-websocket`: the exact paths of `ingress.websocket.paths`
  (`message-front: ["/ws", "/stream"]` by default: the messaging WebSocket,
  contract in Message_API `docs/en/realtime-websocket.md`, and its SSE, which
  the buffering Middleware would hold until the stream ends; `/stream` leaves
  the list when the SSE is removed) on the front's host, same TLS
  Secret, same front Service, no cert-manager annotation. Traefik's
  `buffering` Middleware also buffers responses, which an upgraded
  connection cannot go through, so this route goes without it (the body
  limit stays on every other path) and carries `router.priority: "1000"`:
  Traefik's default priority is the rule length, and the fronts router's
  `PathPrefix(`/`)` rule is longer than `Path(`/ws`)`, so without it the
  fronts router keeps `/ws`. On nginx it gets `proxy-read/send-timeout`
  (`ingress.websocket.timeoutSeconds`, 3600) and no proxy buffering.
  `ingress.annotations` are not copied onto it, only
  `ingress.websocket.annotations`. Nothing else is needed: the WebSocket uses
  the HTTP ports of ingress → front → BFF → API, so no NetworkPolicy changes,
  and no session affinity (Message_API fans signals out through Redis to
  every replica, the front and the BFF relay one connection each). The e2e
  `ingress` test opens whoami's `/echo` through Traefik (101, frame echoed
  under 1 s, 90 s idle past Traefik's default 60 s read timeout, Traefik's
  access log naming the WebSocket router: the buffering Middleware can
  hijack too, so a working handshake alone proves nothing) and from a
  front-labelled pod to a BFF through the Cilium L7 rule
  (`ciliumL7Visibility` is on in `tests/e2e/values.yaml`, as on dev).
- `database` is a StatefulSet with a **headless** governing Service
  (`<release>-database-hl`) plus a client Service (`<release>-database`).
  Credentials come from `<release>-database-secret`.
  **CloudNativePG (`database.cnpg`, off by default).** The same subchart can
  render a CloudNativePG `Cluster` `<release>-database-g<generation>` (official
  `ghcr.io/cloudnative-pg/postgresql` bookworm image), an `ObjectStore` that
  archives WAL and base backups to the instance's backup bucket under `cnpg/`
  (Barman Cloud plugin, keys of `<release>-backup-secret`, retention `35d`,
  longer than the bucket's 30-day COMPLIANCE lock or the plugin's deletions
  fail) and a daily `ScheduledBackup`. `database.engine`
  (`statefulset` | `cnpg`) picks what the client Service selects (by
  `cnpg.io/cluster` + `instanceRole: primary`; the CNPG pods never carry the
  StatefulSet's `app: database` label, so both can run side by side);
  `statefulset.enabled` removes the StatefulSet (its PVC stays). The superuser
  is `<release>-database-superuser` (basic-auth, same password, sealed by
  `scripts/seal-secrets.sh`). Argo CD never prunes or deletes a Cluster
  (`Prune=false,Delete=false`): a point-in-time restore bumps
  `cnpg.generation` with `bootstrap: recovery` and the old generation is
  deleted by hand. `bootstrap` (`initdb` | `import` from the StatefulSet |
  `recovery`) is only read when a Cluster is created: keep it in the values
  afterwards. The operator comes from `bootstrap/addons/cloudnative-pg`
  (namespace `cnpg-system`). Cutover and PITR runbook:
  `docs/en/cloudnativepg.md` (+ `docs/fr/`); tests
  `tests/mair_649_cloudnativepg_test.yaml`.
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
- **`backup` (MAIR-119/MAIR-231), enabled on every tracked instance.** A
  CronJob that streams `pg_dump -Fc` straight into `restic backup --stdin`
  against an S3-compatible bucket — restic brings encryption at rest, dedup
  and retention (`restic forget --prune`), so the dump itself never touches
  a disk on either side. Authenticates to the Mairie360 database as the
  same superuser as Liquibase (`<release>-database-secret`), because no
  single per-API role can read every module's schema.
  `<release>-backup-secret`
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`RESTIC_PASSWORD`) is sealed
  the same way as the other per-instance secrets, but those AWS keys can't
  be generated — `scripts/seal-secrets.sh` only writes that Secret when
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are exported before calling
  it or already sealed on the cluster (kept on re-runs), so the bucket (`<org>-backups-<env>`, versioned and COMPLIANCE-locked
  30 days, created by `mairie360/Infra`, MAIR-618) and its key pair come
  from outside this repo (`charts/backup/README.md`) that this repo's values files enabling
  `backup.enabled` don't perform by themselves — until it's done, the
  CronJob's pod sits in `CreateContainerConfigError` like any Secret-less
  new resource (see Gotchas). `templates/restore-job.yaml` (disabled by
  default, `restore.enabled`) is the disaster-recovery counterpart for the
  Mairie360 database (it replaces schema `public` and reloads the dump in one
  transaction, MAIR-240: `pg_restore --clean` fails on partitioned tables;
  `tests/e2e/restore.sh` runs the whole backup → restore round trip) : no Argo CD hook annotation, run by hand via
  `helm template … | kubectl apply -f -` rather than left enabled in a
  tracked values file, or Argo CD would recreate it every sync.
  The disaster-recovery runbook (MAIR-244, `docs/en/disaster-recovery.md` +
  `docs/fr/`) holds the RPO/RTO targets and the full order: rebuild a lost
  machine with ansible `--tags phase1,phase1b,phase2`, put the sealing key
  back (ansible `scripts/restore-sealing-key-file.sh`), `--tags phase3`, no
  phase 4, then stop the writers (and pause the ApplicationSet controller on
  auto-sync envs) and run the restore Job. Its drill log is updated after each
  drill.
  With `global.observability.enabled`, every successful run pushes
  `mairie360_backup_last_success_timestamp_seconds` to the instance's collector
 ; `mairie360/Infra` alerts (`BackupMissed`) after 7 h without one (backups run
  every 6 h, `keepHourly: 8`).
  A failed report never fails the backup.
  `backup.sealing` (MAIR-500, off by default): crypto-shredding. A native sidecar Postgres receives a
  copy of the live dump, `compliance-backup seal` (Compliance_API image) moves each user's personal
  values into blobs encrypted under a data key wrapped by the user's key in Scaleway Key Manager
  (`global.compliance.keyManager`), and restic backs up the sealed dump and the blobs as one
  snapshot; the restore Job unseals after `pg_restore` (erased users stay anonymized). Erasure =
  compliance-api destroys the key; no backup is ever modified. See `charts/backup/README.md`.
- **`retention` (MAIR-236), on by default.** A daily CronJob running
  `SELECT * FROM fn_apply_retention_policies()`, which itself creates the
  next few months of `access_logs` partitions
  (`fn_ensure_access_logs_partitions`) before applying every
  `retention_policies` row (`Devops/Database`). Both functions are
  `SECURITY DEFINER` with `REVOKE ALL ... FROM PUBLIC`, so this Job
  authenticates as the same Postgres superuser as Liquibase and `backup`
  (`<release>-database-secret`) — no separate secret, unlike `backup` it
  needs no external provisioning and is on everywhere by default. Scheduled
  after the backup CronJob's default run so a dump always has yesterday's
  rows before retention can prune them.
- `redis` uses ACL, not `requirepass`: an entrypoint script (in the ConfigMap)
  writes `/acl/users.acl` at container start from per-role env vars
  (`<ROLE>_REDIS_PASSWORD`, one per entry of `global.apis.instances` and of
  `global.bffs.instances`, MAIR-531) and starts `redis-server --aclfile`. The `default`
  account is disabled; `admin` (Secret key `redis-password`) is for probes and
  `helm test`. Fronts have no Redis account — they never used it. `helm test`
  asserts that an unauthenticated `PING` is refused and that `admin` works.
  Each role is confined to `~<role>:*`, plus the **shared JWT revocation
  list `revoked:*` (MAIR-264, values `redis.revokedTokens`)**: read-write for
  `core-api`, read-only `%R~revoked:*` for every other API, none for the
  BFFs. Every channel is
  reset (`resetchannels`) except for the roles of `redis.pubSubRoles`
  (`message-api`, MAIR-394), which get `&<role>:*` plus `PUBLISH` /
  `SUBSCRIBE`: Message API relays its SSE chat events on
  `message-api:sse:chat-events` so every replica notifies its own streams.
  Because Redis now holds that list, `maxmemory-policy` is
  **`noeviction`** (any other policy can drop a `revoked:<sid>` before its
  TTL; `volatile-*` would even drop them first, they are the only keys with a
  TTL) and AOF is on (`config.appendonly`, survives container restarts;
  `persistence.enabled` keeps it across new pods, on for staging and prod). The APIs only read `REDIS_URL`,
  so the APIs chart builds it as
  `redis://$(REDIS_USERNAME):$(REDIS_PASSWORD)@<release>-redis:6379`
  (Kubernetes expands `$(VAR)` from the variables listed before it).
- `liquibase` is a Job with a **stable name**, declared as an Argo CD
  `Sync` hook at wave 1 with `hook-delete-policy: BeforeHookCreation`. Runs as
  the image's `liquibase` user (1001) on a read-only root filesystem
  (`/tmp` emptyDir), like `retention` (postgres, 70) and `backup` (70, restic
  copied by an initContainer from the pinned `restic/restic` image instead
  of an `apk add` at every run), MAIR-414. Every image the chart hardcodes
  (busybox chown, `wait-for-db`, test pods) is now a pinned values entry
  Renovate can bump.
- **`observability` (MAIR-131, POC), off by default.** One OpenTelemetry
  Collector (`otel/opentelemetry-collector-k8s`) per instance, Service
  `<release>-otel-collector` (OTLP 4317/4318). It receives OTLP from the APIs
  listed in `global.observability.apis` (only `core-api` for now), scrapes
  pod CPU/RAM from the node's kubelet (`kubeletstats`, ClusterRole on
  `nodes/stats`, filtered to the instance namespace) and pushes both to
  Scaleway Cockpit over OTLP/HTTP with an `X-TOKEN` header. Cockpit drops
  resource attributes, so `transform/resource-labels` copies
  `observability.metricResourceLabels` (pod, container, namespace,
  environment, service) onto every data point, or all pods share one series.
  `kubeletStats.utilizationMetrics` adds usage as a share of requests and
  limits; it reads the pod specs (`nodes/pods`), and on k3s < 1.33
  `nodes/proxy` (`grantNodesProxy`, the whole kubelet API, accepted on
  2026-11-20; drop it once the machines run >= 1.33). One switch,
  `global.observability.enabled`, renders the collector **and** makes the
  `APIs` chart inject `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` and `OTEL_RESOURCE_ATTRIBUTES`
  into those APIs. Needs `observability.cockpit.{metrics,traces}Endpoint`
  (full push URLs of the two Cockpit data sources, the render fails without
  them) and `<release>-cockpit-secret` (key `COCKPIT_TOKEN`, sealed by
  `scripts/seal-secrets.sh` from the `COCKPIT_TOKEN` env var). A Deployment,
  not a DaemonSet: it only sees the kubelet of its own node, which is enough
  on single-node instances.
- **`compliance-api` (MAIR-498), off by default.** The instance's compliance
  service (mairie360/Compliance_API: permanent scan, centralized erasure,
  compliance journal), an entry of `APIs.instances` switched on by
  `global.compliance.enabled` (the render fails for the instance without the
  switch). The switch adds its Postgres role (`COMPLIANCE_API_PASSWORD`, read
  by the Liquibase job and the API; while off, the job passes a random
  throwaway password for the `compliance_api` role the Database changelog
  creates everywhere), its Redis account (`%R~*` for the long-TTL scan, write
  on its own keys and `global.compliance.redis.erasurePatterns` only,
  `+scan +ttl`), its settings, and the erasure credentials of
  `<release>-compliance-secret` (Resend, S3, every key
  optional, `scripts/seal-secrets.sh` `COMPLIANCE_*`), **injected into
  compliance-api only**. Its NetworkPolicy admits core-api alone: the BFF rule
  and the Cilium L7 rule of the APIs leave it out. The collector
  (`observability.logMasking`) masks personal data in the OTLP logs (body and
  attributes) and span attributes with a copy of Compliance_API's
  `masking-patterns.yaml`: change both together. `observability.cockpit.logsEndpoint`
  turns on the logs pipeline. Container stdout is not collected yet: only OTLP
  logs go through the masking. `tests/compliance_service_test.yaml`.
- **Sync waves**: `-2` NetworkPolicies → `-1` Secrets/ConfigMaps/RBAC → `0`
  data (Postgres, Redis) → `1` migrations, the backup
  CronJob, the retention CronJob and the collector → `2` APIs →
  `3` BFFs → `4` Fronts → `5` Ingresses.

### Network model

One `default-deny` policy on the whole namespace, then one allow rule per hop.
NetworkPolicies are **purely additive** — a single permissive policy
(`podSelector: {}` + `namespaceSelector: {}`) would cancel everything, so never
add one.

```
ingress-controller ─► fronts ─► bffs ─► apis ─► postgres
                                 │          └──► redis
                                 └─────────────► redis   (MAIR-531)
              liquibase job ──────────────────► postgres
              backup CronJob ─────────────────► postgres
              retention CronJob ──────────────► postgres      (MAIR-236)
                        apis ──OTLP 4317/4318──► otel-collector (component: telemetry)
              backup CronJob ──OTLP 4318─────► otel-collector   (MAIR-622, success time)
```

Toggle with `global.networkPolicy.enabled` (false on Kind — its default CNI
ignores NetworkPolicies; true on k3s). `global.networkPolicy.egressDefaultDeny`
also locks outbound traffic, but stays off until the external destinations of
`core-api` (Resend, `smtp.resend.com:587`), `elearning-api` (Scaleway
Object Storage), the backup CronJob (S3 bucket) and the otel collector (node kubelet
:10250, Cockpit) are declared in `egressAllowCIDRs`.

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
already on the cluster, otherwise **fails**, MAIR-414) and `ADMIN_PASSWORD`
likewise, except that it generates it once. **The sealed `ADMIN_PASSWORD` is
the argon2id PHC hash** (m=19456, t=2, p=1, `openssl kdf ARGON2ID` from
OpenSSL 3.2 or the `argon2` CLI): Database's `create_admin.sql` stores it
as-is and `chk_users_password_hashed` rejects anything else. The env var is
the plaintext (an `$argon2id$` value is sealed unchanged); a password the
script generates, or a plaintext sealed before MAIR-414 that it re-hashes,
goes to `ADMIN_PASSWORD_FILE` (mode 600), never to the cluster. That file has
**no default since MAIR-617**: without it the script stops before sealing
anything (`tests/scripts/mair_617_admin_password_no_local_file_test.sh`). The
ansible role always passes both `ADMIN_PASSWORD` and `RESTIC_PASSWORD` in
(resolved on its side and stored in Scaleway Secret Manager under
`/<org>/<env>`, secrets created by `mairie360/Infra`), so the sealed value is
the one in the vault. The Liquibase Job passes
both as changelog parameters (`-Dadmin_email` / `-Dadmin_password`) and,
since MAIR-414, **requires them** (`liquibase.adminAccount.required`): the
`secretKeyRef`s are not optional, and the Job exits before migrating when
`ADMIN_EMAIL` is empty or `ADMIN_PASSWORD` is not an argon2id hash. Only the
e2e values turn it off, which leaves the changelog on its template admin
credentials, same as no parameter at all.
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
  `app.kubernetes.io/component` (plus `probe-core-api` / `probe-project-api`
  with an `app.kubernetes.io/name`, MAIR-610) try every hop (`check-flows.sh`). A denied
  flow must *time out* (Cilium drops silently); a fast failure is reported
  as an error, so a broken Service can't pass as "deny".
- `chainsaw/ingress` (MAIR-260): `run.sh` installs Traefik (versions read
  and values: the wrapper charts `bootstrap/addons/{traefik,cert-manager}`), cert-manager and
  **Pebble** (Let's Encrypt's test ACME server, `tests/e2e/pebble.yaml`),
  and rewrites `*.e2e.invalid` to Traefik in CoreDNS. The test asserts the
  fronts certificate is issued over HTTP-01 through Traefik (the e2e
  ClusterIssuer keeps class `nginx`, proving the per-Ingress override), the
  301/308 HTTP → HTTPS redirect, the 413 above 50 MiB and that a client-sent
  `X-Forwarded-For` is not trusted. The e2e values run Traefik, so the
  network-policies probe sits in the `traefik` namespace.
- `restore.sh` (MAIR-240, sourced by `run.sh` after Chainsaw, placeholder install only): backup then
  restore on the real database. `s3.yaml` deploys a pinned Versity S3 Gateway (MinIO no longer
  publishes images) as the restic repository; the script writes a probe table, runs the backup
  CronJob, damages the data, checks that the restore Job refuses `latest`, a missing
  `confirmDatabase`, another database and an unknown snapshot without changing anything, then
  restores for real and compares the rows, the schema ACL and the grants of the API roles. The
  restore saves the state before it as a `pre-restore` snapshot. It found that `pg_restore --clean`
  fails on the partitioned `access_logs`; the Job now replaces schema `public` in one transaction.
- `chainsaw/data-access`: Redis ACL (prefix and command restrictions) and
  the per-API Postgres role logging in with its Secret password. The latter
  depends on the `Devops/Database` images actually creating those roles.

### Values layout

```
clusters/_base/<env>.yaml   # shared by every <env> instance of every group (prod only so far)
clusters/<org>/instances/<env>/
  values.yaml     # what differs per instance: domain, image tags, sizes
  images.yaml     # staging only: tags written by argocd-image-updater on the staging branch (MAIR-444)
  secrets.yaml    # GENERATED by scripts/seal-secrets.sh — never hand-edited
```

**`clusters/_base/prod.yaml` (MAIR-414)** holds the versions and settings of
every prod instance (mairie360's and the clients'); an instance's
`values.yaml` only sets `global.domain`, `global.emailFrom`,
`global.elearningBucket`, and its backup bucket. Helm
replaces lists instead of merging them, so anything instance-specific inside
an `env` list is a `global.*` value the base reads through `tpl`, never a
copied list. The instances AppSet (ansible) passes the base first
(`ignoreMissingValueFiles` covers dev/staging), then `values.yaml`, then
`images.yaml` when present; every script, the CI and the
unit tests go through `scripts/instance-values.sh` to do the same. Prod
image tags therefore live in the base: bumping them moves every prod.

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
- **`COMMUNE_NAME` of the fronts comes from `global.legal.mairie.name` (MAIR-1109).** lib-components
  2.3 shows « Mairie de » + the commune in the shared Header; `fronts.commonEnv` gives every front the
  trimmed mairie name, and nothing while it is empty (the fronts then hide the block instead of the
  library's sample « Saint-André »). Fill `global.legal.mairie.name` per instance to show it.
  `tests/mair_1109_commune_name_test.yaml`.
- **`APP_VERSION` of the fronts is the image tag (MAIR-844).** `fronts.appVersion` gives every front its
  instance's `image.tag` (footer version of the V2 shell, read at request time); a `commonEnv` or instance
  `env` entry of the same name wins and the generated one is not rendered. The shell's commune name is the
  `COMMUNE_NAME` above, never a second value. `tests/mair_844_shell_info_test.yaml`.
- **BFF_Dashboard needs nothing per instance (MAIR-825, MAIR-1106).** Every BFF gets one
  `<NAME>_URL` per entry of `global.apis.instances` (so `MESSAGE_API_URL` and `ELEARNING_API_URL`
  too) and `MAIRIE_NAME` from the same `global.legal.mairie.name` (trimmed, absent while empty:
  the dashboard then answers `communeName: null`). `tests/mair_825_dashboard_bff_env_test.yaml`.
- **`COOKIE_DOMAIN` of the fronts is derived, never declared.** `fronts.commonEnv`
  (`charts/Fronts/templates/_helpers.tpl`) gives every front `.<global.domain>`; an instance
  `env:` list that declares it too would put it twice. `lib-components` answers 503 on the
  session resume, refresh and logout routes without it (`NODE_ENV=production`), which is how
  `dashboard-front` and `settings-front` lost their session on dev and staging. The BFF
  `user-bff` still declares its own (`BFFs` chart). `tests/mair_747_cookie_domain_test.yaml`
  checks the 8 fronts on dev, staging and prod.
- **Each environment follows its own branch (ADR 0002).** The instances AppSet
  gives every Application a `targetRevision` from Ansible's
  `deploiment_env_revisions`: `dev` → `main`, `staging` → `staging`, `prod` →
  `prod` (chart, `values.yaml` and `secrets.yaml` are all read at that revision).
  So **a merge on `main` only reaches dev**; staging then prod move with the
  `Promote` workflow (`.github/workflows/promote.yaml`, `workflow_dispatch`):
  fast-forward only, a commit must already be in `main` to reach `staging` and
  in `staging` to reach `prod`, the whole `cicd.yaml` re-runs on it, and `prod`
  additionally needs: the commit to be `staging`'s head, the `verify-staging`
  job to pass (MAIR-346: `scripts/verify.sh` against staging, run on the
  **self-hosted runner** of the group's Argo CD machine, labels `self-hosted`,
  `linux`, `mairie360-argocd-mairie360`, the only place reaching the instance
  API servers over WireGuard, with `KUBECONFIG=/home/gh-runner/.kube/instance-staging.yaml`,
  context = that file's current context, domain = `global.domain` of the
  staging values; that kubeconfig has no Secret read, so verify.sh skips its
  two plaintext checks there) and the approval of the `promote-prod` GitHub
  environment. It replaced the former `staging_verified` checkbox. Staging's
  instance Application is synced **by hand** (MAIR-801, 2026-11-20: ansible
  `deploiment_auto_sync_envs` is `dev` only): after a Promote to staging, sync
  it from Argo CD (or `kubectl -n argocd patch application staging --type merge
  -p '{"operation":{"sync":{…}}}'` on the Argo CD machine), and so for the tags
  argocd-image-updater commits on `staging`. Check it is Synced at the promoted
  commit before promoting to prod, or
  verify.sh checks the previous commit (not checked by the workflow yet). `rollback: true` force-moves the branch back to an older
  commit, without verification. **Never delete `staging` or `prod`
  (MAIR-745):** both were deleted on 2026-10-23, which left their Applications
  without a revision and made `Promote` refuse everything; they were recreated
  at `3c006cc` (what Argo CD last deployed) on 2026-11-02. The "environment
  branches protection" ruleset refuses their deletion and force-pushes (so a
  `rollback: true` needs a ruleset bypass), and
  `.github/workflows/environment-branches.yaml` runs
  `scripts/check-env-branches.sh` on every branch deletion and daily, failing
  when one is missing (`tests/scripts/mair_745_env_branches_test.sh`). Since
  MAIR-346 the bootstrap add-ons follow these branches too. **Never commit
  straight onto `staging` or `prod` (MAIR-798):** a fix pushed onto `prod` on
  2026-11-06 blocked every later Promote until `prod` was merged back into
  `main` (merge commit, #250). The same workflow's `divergence` job runs
  `scripts/check-env-divergence.sh` on every push to `staging`/`prod` and
  daily: it fails when `staging` holds anything but argocd-image-updater
  commits on top of `main`, or when `prod` is not an ancestor of `staging`,
  and lists the commits with the way back (PR merging `origin/<env>` into
  `main`, then promote); `scripts/promote-mode.sh` prints the same guidance
  when a Promote is refused (`tests/scripts/mair_798_env_divergence_test.sh`).
  **MAIR-444:** argocd-image-updater
  commits staging's tags straight onto `staging`
  (`clusters/mairie360/instances/staging/images.yaml`, never edited on `main`),
  so `Promote` to staging merges instead of fast-forwarding when `staging` is
  ahead by such commits only (ADR 0002 amendment). Consequences: a change to
  `clusters/mairie360/instances/prod/values.yaml`, a freshly sealed
  `secrets.yaml` or a bump in `bootstrap/addons/` or `bootstrap/cluster-addons/`
  also needs a promotion; the AppSet generator still lists
  directories on `main`, so a **new environment directory must be promoted
  before its Application can render**. **Bootstrap add-ons (MAIR-346):** each
  instance AppSet of `bootstrap/appsets/` reads its wrapper chart
  (`bootstrap/addons/<x>/`) or `bootstrap/cluster-addons/` at the Argo CD
  cluster annotation `mairie360.fr/revision` (ansible, from
  `deploiment_env_revisions`: dev → `main`, `staging`, `prod`), `main` when
  absent; `scripts/check-bootstrap-revisions.sh` (CI) refuses an instance
  AppSet that reads a chart repository or a fixed revision. What stays on
  `main` for every machine at once: `platform-app.yaml`, the AppSet manifests
  themselves and `image-updater-app.yaml` (Argo CD machine only). A **new
  path** referenced by an AppSet (a new addon) needs two PRs: add the path,
  promote it to staging and prod, then reference it from the AppSet; otherwise
  those machines' Applications fail with "path does not exist" until it is
  promoted. Since MAIR-710 a change to the AppSets themselves deletes nothing
  on the instances: `platform` does not prune (remove an ApplicationSet by
  hand once its file is gone) and the add-on AppSets set
  `preserveResourcesOnDeletion` (only the two ingress-controller AppSets keep
  their resources finalizer, to free ports 80/443 on a switch);
  `tests/scripts/mair_710_bootstrap_no_prune_test.sh` pins both.
  Also, when working on a branch, Ansible's `deploiment_repo_branch` repoints
  `platform-app.yaml`, the instances AppSet generator and the `dev` revision —
  do not let them diverge, or Argo CD silently serves the old appsets from
  `main` while you edit the branch.
- **SealedSecrets are per-machine.** The sealing key belongs to one cluster's
  controller; `clusters/<org>/instances/<env>/secrets.yaml` must be generated on
  that machine with `scripts/seal-secrets.sh`. Back up every key — losing one
  makes that instance's committed secrets permanently undecryptable. Since
  MAIR-617 the controller never renews its key (`keyrenewperiod: "0"` in
  `bootstrap/addons/sealed-secrets/values.yaml`,
  `tests/scripts/mair_617_sealing_key_no_renewal_test.sh`): ansible backs every
  key up as a version of the vault secret `/<org>/<env>/sealing-keys`, which
  Scaleway caps at 20 versions, and the chart's 30-day default would fill it.
  Renewal never re-encrypted existing SealedSecrets anyway; rotate on purpose.
- **First sync of a new environment will fail until its secrets.yaml exists**:
  pods stay in `CreateContainerConfigError` with no Secret to mount. Expected.
  `elearning-api` stays there too when `secrets.yaml` was sealed before the
  `S3_*` keys existed: re-run `seal-secrets.sh` with `S3_ACCESS_KEY` /
  `S3_SECRET_KEY` set (`scripts/verify.sh` step 4 reports empty keys). Since
  MAIR-619 every bucket (`<org>-backups-<env>`, `<org>-elearning-<env>`) has
  its own key, limited to it by a bucket policy, issued by `mairie360/Infra`
  into the vault and sealed by ansible's `playbooks/secrets.yml` with nothing
  typed (`tests/scripts/mair_619_instance_buckets_test.sh` pins the names).
- **A GHCR PAT leaked into git history (MAIR-677).** `configs/ghcr-registry-secret.yaml`
  and every `image.pullSecretData` have been removed and the token is revoked
  (GitHub API answers 401, checked 2026-11-01); the history purge is tracked in
  MAIR-677. Never commit a registry credential again: the GHCR credentials live
  in ansible (`GHCR_USER` / `GHCR_TOKEN`), and the `secret-scan` CI job blocks it.
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
  prod/client values a published semver. Since MAIR-444 the image-updater also moves `database` /
  `liquibase`, and writes to git: dev through auto-merged `chore(deps)` PRs
  on `main` (`.github/workflows/image-updater-automerge.yaml`), staging
  through commits on the `staging` branch into `images.yaml`, which
  `Promote` merges main into (`scripts/promote-mode.sh`). Prod has no
  image-updater (MAIR-186): its tags only move through a commit here. On GHCR
  several `<env>-<sha>` of one image can share the same `Created` date
  (build cache): pick by commit date, not by `Created`.
- **Front image name mismatch**: the values key is `project-front` but the image
  is `ghcr.io/mairie360/projects-front` (plural). The image-updater alias follows
  the key, the `image-list` entry follows the image.
- **HTTP-01 means one ACME challenge per host** — 8 fronts per environment
  here (one certificate, `<fullname>-fronts-tls`). All 8 hostnames must
  resolve publicly to the ingress before the certificate is issued, and the Let's Encrypt production
  quota (50 certs/domain/week) burns fast while debugging. Start on
  `letsencrypt-staging`.
- **`maxSurge: 0` with `replicaCount: 1` means downtime on every deploy** (old
  pod killed before the new one is ready). Deliberate on a small VM for the APIs
  and the fronts; it is not a rolling update. The BFFs use `maxSurge: 1` /
  `maxUnavailable: 0` (one more BFF pod during a rollout), a native
  `preStop.sleep` of `preStopSleepSeconds` (5 s, so the endpoints stop routing
  to the pod first) and `terminationGracePeriodSeconds: 30`; the BFF drains its
  requests on SIGTERM (bffs-lib `gracefulShutdown`, under tini).
- **`replicaCount: 2` on Redis would give two independent caches**, not a
  replicated one. Leave it at 1.
- Redis keeps `/data` on a PVC on staging and every prod instance
  (`redis.persistence.enabled: true`, 1Gi `local-path`, set in `clusters/_base/prod.yaml` and the staging
  values; `tests/mair_693_redis_persistence_test.yaml`), so the AOF and the JWT
  revocation list survive a new pod (config change, node drain, chart update).
  Dev stays on the chart default, an `emptyDir` (`persistence.enabled: false`): there a new pod empties
  the list and revoked tokens are accepted again by every API but Core until they expire
  (`JWT_TIMEOUT`). `local-path` is bound to the node, which is fine as an instance is one k3s node;
  a lost machine still loses Redis (see the disaster recovery doc), users sign in again.
  Any change to the Redis ConfigMap restarts the pod (checksum annotation).
- **`scripts/seal-secrets.sh`'s `REDIS_ROLES` and `DB_ROLES` lists are
  hand-maintained**, not read from the chart. `REDIS_ROLES` must be kept in
  sync with `global.apis.instances` + `global.bffs.instances` (BFFs again
  since MAIR-531); `DB_ROLES`
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
  The Redis ACL passwords are put raw in `REDIS_URL` the same way, and the
  base64 ones from before that fix were kept by every re-seal (MAIR-531:
  calendar/message/elearning-api, "Redis URL did not parse"). The script
  now regenerates any kept role password that `scripts/lib/secret-values.sh`
  `url_safe` rejects (restart Redis, then the APIs, after the sync), and
  `scripts/verify.sh` step 4 flags them on the cluster.
- `.env` (gitignored, not tracked) holds a real GHCR token and GitHub App creds
  used for local registry auth — never commit it.
- **The session signing key is only replaced by `--rotate-signing-key`
  (MAIR-680).** A plain run or `--rotate` keeps it, and a run while the
  committed `secrets.yaml` seals a key the cluster has not received yet stops
  (a second key would not match the public key already pasted). Do not delete
  `<release>-jwt-signing-secret` to rotate: its SealedSecret is still in git
  and the controller brings the old Secret back. `--rotate-signing-key`
  generates the new key without reading the cluster, then the rollout is two
  commits, in this order (one commit does not order the restarts, and a
  core-api signing before the verifiers know the key logs users out):
  1. `values.yaml` only, `global.jwt.publicKey` listing the current **and**
     the new block; sync, wait for every API and BFF rollout;
  2. the new `secrets.yaml`; sync, `kubectl rollout restart` core-api (env
     from `secretKeyRef` is read at start only);
  3. after `JWT_TIMEOUT`, drop the old block.
  core-api refuses to start when its private key matches no block of
  `JWT_PUBLIC_KEY`. The chart has no override of the Secret name: it is
  always `<release>-jwt-signing-secret`, the one the script seals.
- **`TOTP_ENCRYPTION_KEY` is never rotated (MAIR-805).** core-api seals the TOTP
  secrets of its users with it (AES-256-GCM, base64 of 32 bytes). It lives in
  `<release>-app-secrets`, is generated once by `scripts/seal-secrets.sh`, kept
  from the cluster on every re-run and by `--rotate`, and read by core-api alone
  (`apis.totpKeyEnv`, `optional`: an instance sealed before MAIR-805 keeps
  starting and core-api answers 503 on the second-factor routes). Losing or
  changing it makes every enrolled second factor unreadable and locks the
  protected accounts out (an admin reset `DELETE /admin/users/{id}/2fa` is then
  the only way back): keep a copy outside the cluster like the sealing key, and
  restore it with `TOTP_ENCRYPTION_KEY=… seal-secrets.sh`.
  `tests/mair_805_totp_key_test.yaml`, `tests/scripts/mair_805_totp_key_test.sh`.
- **`--rotate` on `scripts/seal-secrets.sh` regenerates `RESTIC_PASSWORD`
  too**, same as `JWT_SECRET`/`POSTGRES_PASSWORD`/ACL passwords — but restic
  derives its master key from that one password, and nothing here runs the
  equivalent of `restic key passwd` against the existing repository. Rotate
  it naively and the *whole* bucket (every past snapshot, not just future
  ones) becomes permanently unreadable. Run `restic key passwd` with the old
  and new password first, or don't rotate it at all.

## Known gaps (not addressed in this chart)

- **No PITR until an instance is cut over, no failover.** Every instance
  still runs the single-replica StatefulSet: a lost volume means restoring
  the last daily dump (`backup`). CloudNativePG support is in the chart
  (`database.cnpg`, WAL archiving + PITR) but no instance has switched yet;
  it runs one instance per Cluster, so there is still no automatic failover.
- `runAsNonRoot: false` in every `containerSecurityContext`: the app images do
  not declare a non-root `USER`. Fix the Dockerfiles, then flip the flag and
  make the `trivy config` CI job blocking.
- No `PodDisruptionBudget`, no `HorizontalPodAutoscaler`, no resource quota.
- Monitoring is a POC (MAIR-131): the `observability` collector covers
  `core-api` traces and pod CPU/RAM on `dev` only. `global.monitoringNamespace`
  still opens the NetworkPolicy for a Prometheus that is not deployed.

## Pull request reviewers

Every PR requests a review from the whole team, minus its author: `CarolinHugo`, `LAURETbenjamin`, `MathTek` and `Quentintnrl` (`gh pr create … --reviewer CarolinHugo,LAURETbenjamin,MathTek`). `.github/CODEOWNERS` makes GitHub request them automatically as well.
