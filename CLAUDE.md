# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

GitOps deployment repo for **Mairie360**, a microservices platform (Epitech EIP project).
Argo CD watches this repo and deploys everything with Helm. There is no application
code here — only Helm charts, per-environment values, and Argo CD bootstrap manifests.

The platform is 5 backend APIs (Rust), 7 BFFs (Node), and 8 frontends (Node), plus
PostgreSQL, Redis, a Liquibase migration job, a backup CronJob (MAIR-119/MAIR-231, on
for every tracked instance), an optional OpenTelemetry Collector (MAIR-131 POC) and,
since MAIR-139, one Keycloak (with its own PostgreSQL) per instance.
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
helm plugin install https://github.com/helm-unittest/helm-unittest --verify=false   # once (Helm 4)
helm unittest ./charts/mairie360-stack

# Render + schema-validate every instance with both ingress controllers,
# plus bootstrap/ (this is what CI does). CRD schemas (Traefik Middleware,
# Argo CD AppSets) come from the datreeio CRDs-catalog.
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
for v in clusters/*/instances/*; do for c in nginx traefik; do
  helm template r ./charts/mairie360-stack -f "$v/values.yaml" --set global.ingressController=$c \
    | kubeconform -strict -summary -schema-location default -schema-location "$CRDS" \
        -skip CiliumNetworkPolicy || echo "KO: $v ($c)"
done; done
kubeconform -strict -schema-location default -schema-location "$CRDS" bootstrap/appsets bootstrap/cluster-addons

# Resolve subchart deps (needed before template/install; Chart.lock + .tgz gitignored)
helm dependency build ./charts/mairie360-stack

# Every rendered image exists on its registry and follows its env's tag family
# (dev-<sha> / staging-<sha> / semver). Needs skopeo; --offline = policy only.
./scripts/check-image-tags.sh

# Every Secret / key the pods reference is sealed in the instance's
# secrets.yaml (MAIR-414). Blocking in Promote, --warn in CI.
./scripts/check-instance-secrets.sh

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

# Acceptance test of a deployed instance (KEYCLOAK_REALM=… if not mairie360)
./scripts/verify.sh <kube-context> dev dev.mairie360-eip.fr

# Argo CD admin password (on the group's Argo CD machine)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Machine provisioning is **not** done from this repo — see `mairie360/ansible`.
`scripts/bootstrap-node.sh` remains for preparing an isolated machine by hand.

CI (`.github/workflows/cicd.yaml`, on push to `main`/`develop` and all PRs):
`helm lint` → render **and `kubeconform`** every instance (nginx and traefik)
and `bootstrap/` → `scripts/check-image-tags.sh` → `helm unittest`, all
blocking, plus `scripts/check-instance-secrets.sh --warn` (annotations only). `gitleaks` and `trivy config` are not wired yet. The Kind + Cilium
end-to-end suite runs separately (`.github/workflows/k8s-e2e.yaml`).
`.github/workflows/promote.yaml` is the manual main → staging → prod promotion
(it calls `cicd.yaml` as a reusable workflow on the promoted commit, and
refuses to move the branch while `scripts/check-instance-secrets.sh` reports
a Secret or key missing from a target instance's `secrets.yaml`, MAIR-414).

## GDPR decisions (`compliance/`, MAIR-294)

`compliance/<org>/` holds a mairie's GDPR decisions (`register.yaml`, `retention.yaml`,
`subprocessors.yaml`, `access.yaml`, `deadlines.yaml`, see `compliance/README.md`); every org of
`clusters/` needs one. `scripts/check-compliance.py` (CI, after the renders; tests in
`tests/compliance/`) renders each instance of `retention.yaml`'s `applies_to` and fails when the
retention CronJob's periods (`retention.policies`, written into `retention_policies` before every
purge), the backup retention, an external host or an egress CIDR does not follow the decisions, or
when the register is incomplete; decisions without `validated: {date, by}` are warnings
(`--strict` makes them fail). A period changes in the decision file and in the values together.

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
| `cert-manager-appset.yaml` | AppSet, clusters generator | `cert-manager-<cluster>` v1.21.2 | instances only |
| `cluster-issuer-appset.yaml` | AppSet, clusters generator | applies `bootstrap/cluster-addons/` | instances only |
| `ingress-nginx-appset.yaml` | AppSet, clusters generator | `ingress-nginx` 4.15.1 (last release, retired upstream), default IngressClass | instances **not** labelled `mairie360.fr/ingress=traefik` |
| `traefik-appset.yaml` | AppSet, clusters generator, multi-source | `traefik` chart 41.6.0 (v3.7.13), values `bootstrap/values/traefik.yaml` | instances labelled `mairie360.fr/ingress=traefik` |
| `image-updater-app.yaml` | Application | `argocd-image-updater` | in-cluster (Argo CD machine) |
| `projects.yaml` | AppProjects (wave -1) | `mairie360-platform` (the rows above) and `mairie360-instances` (the instances AppSet, ansible) | Argo CD machine |

**AppProjects (MAIR-414).** Nothing but the root `platform` Application stays
in `default`. `mairie360-platform` admits the add-ons' chart repositories and
namespaces (cluster-scoped kinds allowed: CRDs, webhooks, RBAC);
`mairie360-instances` admits this repository only, `mairie360-*` namespaces
only, and no cluster-scoped kind but `Namespace` and the collector's
`ClusterRole`/`ClusterRoleBinding`. A new add-on chart repository or
namespace must be added to `bootstrap/appsets/projects.yaml`, or its
Application is refused.

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
`-staging`, HTTP-01 solver class `nginx` by default) → the
`cert-manager.io/cluster-issuer` annotation on the fronts Ingress, plus
`acme.cert-manager.io/http01-ingress-ingressclassname: <instance class>`,
which overrides the solver class per Ingress. With Traefik, HTTP → HTTPS is
the web entrypoint's redirect pinned at **priority 1**, so the solver router
(`pathType: Exact`) always answers on port 80: keep it the lowest.

Each instance needs public DNS for every front hostname pointing at its own IP.
**`cert-manager-appset.yaml` must stay free of any domain or IP** (MAIR-157):
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

Umbrella `type: application` chart with 10 local subcharts (`file://` deps):
`database`, `redis`, `liquibase`, `backup`, `retention`, `keycloak`,
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
  database), no `REDIS_*` (none reads Redis), and `JWT_SECRET` only for
  `BFFs.jwtSecretInstances` (`user-bff`): any other BFF holding it could
  forge an admin token.
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
  `templates/keycloak-ingress.yaml` is the only other Ingress
  (`auth.<global.domain>`, own TLS Secret): same `ingress.*` settings plus
  `keycloak.ingress.annotations`. APIs/BFFs are never exposed.
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
- **`backup` (MAIR-119/MAIR-231), enabled on every tracked instance.** A
  CronJob that streams `pg_dump -Fc` straight into `restic backup --stdin`
  against an S3-compatible bucket — restic brings encryption at rest, dedup
  and retention (`restic forget --prune`), so the dump itself never touches
  a disk on either side. Authenticates to the Mairie360 database as the
  same superuser as Liquibase (`<release>-database-secret`), because no
  single per-API role can read every module's schema; when
  `backup.keycloak.enabled` (also on everywhere Keycloak is deployed), the
  same Job dumps `<release>-keycloak-db` right after, with its own
  `KEYCLOAK_DB_PASSWORD` and its own `--host keycloak-<db-name>`, into the
  **same** S3 repository as a separate snapshot lineage.
  `<release>-backup-secret`
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`RESTIC_PASSWORD`) is sealed
  the same way as the other per-instance secrets, but those AWS keys can't
  be generated — `scripts/seal-secrets.sh` only writes that Secret when
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are exported before calling
  it or already sealed on the cluster (kept on re-runs), so a real bucket and key pair per instance is a manual, one-time infra
  step (`charts/backup/README.md`) that this repo's values files enabling
  `backup.enabled` don't perform by themselves — until it's done, the
  CronJob's pod sits in `CreateContainerConfigError` like any Secret-less
  new resource (see Gotchas). `templates/restore-job.yaml` (disabled by
  default, `restore.enabled`) is the disaster-recovery counterpart for the
  Mairie360 database (Keycloak's dump is restored by hand, see
  `charts/backup/README.md`): no Argo CD hook annotation, run by hand via
  `helm template … | kubectl apply -f -` rather than left enabled in a
  tracked values file, or Argo CD would recreate it every sync.
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
  (`<ROLE>_REDIS_PASSWORD`, one per entry of `global.apis.instances`; the
  BFFs have no account since MAIR-414) and starts `redis-server --aclfile`. The `default`
  account is disabled; `admin` (Secret key `redis-password`) is for probes and
  `helm test`. Fronts have no Redis account — they never used it. `helm test`
  asserts that an unauthenticated `PING` is refused and that `admin` works.
  Each role is confined to `~<role>:*`, plus the **shared JWT revocation
  list `revoked:*` (MAIR-264, values `redis.revokedTokens`)**: read-write for
  `core-api`, read-only `%R~revoked:*` for every other API. Because Redis now holds that list, `maxmemory-policy` is
  **`noeviction`** (any other policy can drop a `revoked:<sid>` before its
  TTL; `volatile-*` would even drop them first, they are the only keys with a
  TTL) and AOF is on (`config.appendonly`, survives container restarts;
  `persistence.enabled` for new pods too). The APIs only read `REDIS_URL`,
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
  Scaleway Cockpit over OTLP/HTTP with an `X-TOKEN` header. One switch,
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
  `<release>-compliance-secret` (Keycloak admin client, Resend, S3, every key
  optional, `scripts/seal-secrets.sh` `COMPLIANCE_*`), **injected into
  compliance-api only**. Its NetworkPolicy admits core-api alone: the BFF rule
  and the Cilium L7 rule of the APIs leave it out. The collector
  (`observability.logMasking`) masks personal data in the OTLP logs (body and
  attributes) and span attributes with a copy of Compliance_API's
  `masking-patterns.yaml`: change both together. `observability.cockpit.logsEndpoint`
  turns on the logs pipeline. Container stdout is not collected yet: only OTLP
  logs go through the masking. `tests/compliance_service_test.yaml`.
- **Sync waves**: `-2` NetworkPolicies → `-1` Secrets/ConfigMaps/RBAC → `0`
  data (Postgres, Redis, Keycloak's Postgres) → `1` migrations, the backup
  CronJob, the retention CronJob and the collector → `2` APIs and Keycloak →
  `3` BFFs → `4` Fronts → `5` Ingresses.

### Keycloak (MAIR-139, `charts/keycloak`)

One Keycloak per instance, first brick of the SSO epic (MAIR-135). What the
subchart renders, all named `<release>-keycloak*`:

- **`<release>-keycloak`**: Deployment (1 replica, `Recreate`, `KC_CACHE=local`)
  + Service on 8080. Runs `start --import-realm` in production mode behind
  the ingress controller: `KC_HTTP_ENABLED=true`, `KC_PROXY_HEADERS=xforwarded`,
  `KC_HOSTNAME=https://<global.keycloak.hostname or auth.<global.domain>>`
  with `KC_HOSTNAME_STRICT=true`, so every URL it emits (issuer, redirects,
  admin console) is the public one whatever host the request came in on —
  a BFF calling the cluster Service sees the same issuer as the browser.
  Health probes hit the management port (9000, `KC_HEALTH_ENABLED`), which
  is never exposed. **The admin console is not exposed either (MAIR-414)**:
  the Ingress routes only `keycloak.ingress.paths` (`/realms/`,
  `/resources/`), and `KC_HOSTNAME_ADMIN` (`keycloak.adminUrl`,
  `http://localhost:8080`) serves it through
  `kubectl -n mairie360-<env> port-forward svc/<env>-keycloak 8080:8080`. Image pinned (`quay.io/keycloak/keycloak:26.x`): an
  upgrade migrates Keycloak's schema and cannot be rolled back.
- **`<release>-keycloak-db`**: its own PostgreSQL StatefulSet (stock
  `postgres:17-alpine`, uid 70) + headless and client Services. Deliberately
  **not** the Mairie360 database: Keycloak owns its schema, nothing of the
  `Devops/Database` changelog applies, and the `database` NetworkPolicy
  stays as is. Covered by the `backup` CronJob as a separate dump
  (`backup.keycloak.enabled`, MAIR-231) — its own NetworkPolicy admits
  `component: backup` on 5432 alongside Keycloak itself.
- **`<release>-keycloak-realm`** ConfigMap, mounted at
  `/opt/keycloak/data/import`: the `global.keycloak.realm` realm (`mairie360`)
  with the five `Database` roles (`Admin`, `Maire`, `Responsable`, `User`,
  `Guest`), two OIDC clients — `login-front` (public, authorization code +
  PKCE S256) and `bff-user` (confidential, service account) — both redirecting
  to `https://login.<domain>/*` by default (`keycloak.realm.clients.*`), and
  the Resend SMTP relay when `keycloak.realm.smtp.from` is set. **Keycloak
  only imports a realm that does not exist yet**: after the first sync, edit
  the realm in the admin console (it lives in Keycloak's DB), not in values.
  The ConfigMap holds no secret: `"secret": "${BFF_USER_CLIENT_SECRET}"` and
  `"password": "${SMTP_PASSWORD}"` are Keycloak placeholders resolved at
  import from the container env (`secretKeyRef`), not Helm expressions.
- **`<release>-keycloak-secret`**: `KEYCLOAK_ADMIN_PASSWORD` (bootstrap admin
  `admin` of the master realm, read on the first start of an empty DB only),
  `KEYCLOAK_DB_PASSWORD` (Postgres role, first init only),
  `BFF_USER_CLIENT_SECRET`. Sealed by `scripts/seal-secrets.sh` like the
  others, all generated; **never touched by `--rotate`** for the same
  reason as `ADMIN_PASSWORD`: none of the three is re-read once Keycloak
  has started, so rotate in Keycloak itself, then re-seal the client secret
  with `BFF_USER_CLIENT_SECRET=…`. `SMTP_PASSWORD` is read from
  `<release>-app-secrets` (optional), same Resend key as core-api.
- **Network**: `keycloak` accepts the ingress-controller namespace, `bff`
  and `api` pods on 8080; `keycloak-db` accepts `keycloak` on 5432 and
  nothing else (not the APIs, migration or backup). Fronts never reach it
  server-side, the browser goes through the Ingress.
- **Tests**: `tests/keycloak_test.yaml` (`helm unittest`), the subchart's
  `helm test` pod (issuer of the discovery document from a `bff`-labelled
  pod) and, in e2e, the real Keycloak image: the chainsaw `data-access`
  test gets a `client_credentials` token for `bff-user` with the secret
  from the Secret (proves the placeholder substitution) and
  `network-policies` covers the new hops.
- `scripts/verify.sh` step 4 expects the Secret, step 13b that `/admin` is not routed (MAIR-414), step 12 checks the realm is
  served, step 13 the `auth.` certificate, step 15 that 8080/9000 are closed.
- Not wired yet (MAIR-140/153): the BFFs and fronts get no `KEYCLOAK_*` env
  var; `global.keycloak.{hostname,realm}` exist so the BFFs chart can derive
  the issuer URL when they do.

### Network model

One `default-deny` policy on the whole namespace, then one allow rule per hop.
NetworkPolicies are **purely additive** — a single permissive policy
(`podSelector: {}` + `namespaceSelector: {}`) would cancel everything, so never
add one.

```
ingress-controller ─► fronts ─► bffs ─► apis ─► postgres
                                    └──────────► redis
              liquibase job ──────────────────► postgres
              backup CronJob ─────────────────► postgres
              backup CronJob ─────────────────► keycloak-db   (MAIR-231)
              retention CronJob ──────────────► postgres      (MAIR-236)
ingress-controller ─► keycloak ─► keycloak-db     (MAIR-139)
                bffs / apis ─► keycloak
                        apis ──OTLP 4317/4318──► otel-collector (component: telemetry)
```

Toggle with `global.networkPolicy.enabled` (false on Kind — its default CNI
ignores NetworkPolicies; true on k3s). `global.networkPolicy.egressDefaultDeny`
also locks outbound traffic, but stays off until the external destinations of
`core-api` and Keycloak (Resend, `smtp.resend.com:587`), `elearning-api` (Scaleway
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
goes to `ADMIN_PASSWORD_FILE` (default `~/.mairie360/admin-<org>-<env>.txt`,
mode 600), never to the cluster. The ansible role always passes both `ADMIN_PASSWORD` and
`RESTIC_PASSWORD` in (resolved on its side, backed up to
`~/.mairie360/admin-<org>-<env>.txt` / `restic-<org>-<env>.txt`), so the
sealed value is the backed-up one. The Liquibase Job passes
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
  `app.kubernetes.io/component` try every hop (`check-flows.sh`). A denied
  flow must *time out* (Cilium drops silently); a fast failure is reported
  as an error, so a broken Service can't pass as "deny".
- `chainsaw/ingress` (MAIR-260): `run.sh` installs Traefik (versions read
  from the AppSets, values `bootstrap/values/traefik.yaml`), cert-manager and
  **Pebble** (Let's Encrypt's test ACME server, `tests/e2e/pebble.yaml`),
  and rewrites `*.e2e.invalid` to Traefik in CoreDNS. The test asserts the
  fronts certificate is issued over HTTP-01 through Traefik (the e2e
  ClusterIssuer keeps class `nginx`, proving the per-Ingress override), the
  301/308 HTTP → HTTPS redirect, the 413 above 50 MiB and that a client-sent
  `X-Forwarded-For` is not trusted. The e2e values run Traefik, so the
  network-policies probe sits in the `traefik` namespace.
- `chainsaw/data-access`: Redis ACL (prefix and command restrictions) and
  the per-API Postgres role logging in with its Secret password. The latter
  depends on the `Devops/Database` images actually creating those roles.

### Values layout

```
clusters/_base/<env>.yaml   # shared by every <env> instance of every group (prod only so far)
clusters/<org>/instances/<env>/
  values.yaml     # what differs per instance: domain, image tags, sizes
  secrets.yaml    # GENERATED by scripts/seal-secrets.sh — never hand-edited
```

**`clusters/_base/prod.yaml` (MAIR-414)** holds the versions and settings of
every prod instance (mairie360's and the clients'); an instance's
`values.yaml` only sets `global.domain`, `global.emailFrom`,
`global.elearningBucket`, its backup bucket and Keycloak's sender. Helm
replaces lists instead of merging them, so anything instance-specific inside
an `env` list is a `global.*` value the base reads through `tpl`, never a
copied list. The instances AppSet (ansible) passes the base first
(`ignoreMissingValueFiles` covers dev/staging); every script, the CI and the
unit tests go through `scripts/instance-values.sh` to do the same. Prod
image tags therefore live in the base: bumping them moves every prod.

`values.yaml` overrides only what changes; defaults live in
`charts/mairie360-stack/values.yaml` and each subchart's `values.yaml`.
`secrets.yaml` is consumed through the chart's `extraObjects`. The committed
`secrets.yaml` files predate MAIR-139: `<release>-keycloak-secret` is only
added the next time `scripts/seal-secrets.sh` runs on each instance (Ansible
`playbooks/secrets.yml`), until then its two pods sit in
`CreateContainerConfigError`, like any new Secret (see Gotchas).

There is **no local/Kind values set**: the four machines include a real `dev`,
and maintaining a parallel Kind topology is what produced the earlier
"three incompatible ways to deploy" problem. Local validation is
`helm template` + `helm unittest`.

## Gotchas

- **Subchart directory names are capitalized** (`APIs`, `BFFs`, `Fronts`) and must
  match the top-level values keys exactly.
- **Each environment follows its own branch (ADR 0002).** The instances AppSet
  gives every Application a `targetRevision` from Ansible's
  `deploiment_env_revisions`: `dev` → `main`, `staging` → `staging`, `prod` →
  `prod` (chart, `values.yaml` and `secrets.yaml` are all read at that revision).
  So **a merge on `main` only reaches dev**; staging then prod move with the
  `Promote` workflow (`.github/workflows/promote.yaml`, `workflow_dispatch`):
  fast-forward only, a commit must already be in `main` to reach `staging` and
  in `staging` to reach `prod`, the whole `cicd.yaml` re-runs on it, and `prod`
  additionally needs the `staging_verified` box (run `scripts/verify.sh` on
  staging first: GitHub runners cannot reach the instance API servers) and the
  approval of the `promote-prod` GitHub environment. `rollback: true` force-moves
  the branch back to an older commit. Consequences: a change to
  `clusters/mairie360/instances/prod/values.yaml` or a freshly sealed
  `secrets.yaml` also needs a promotion; the AppSet generator still lists
  directories on `main`, so a **new environment directory must be promoted
  before its Application can render**. The bootstrap appsets (`bootstrap/`,
  cert-manager, ingress-nginx, sealed-secrets, cluster-addons) are **not**
  covered: the root `platform` app follows `main` and hits every instance at once.
  Also, when working on a branch, Ansible's `deploiment_repo_branch` repoints
  `platform-app.yaml`, the instances AppSet generator and the `dev` revision —
  do not let them diverge, or Argo CD silently serves the old appsets from
  `main` while you edit the branch.
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
- **HTTP-01 means one ACME challenge per host** — 8 fronts plus `auth.` for
  Keycloak per environment here (two certificates: `<fullname>-fronts-tls`
  and `<fullname>-keycloak-tls`). All 9 hostnames must resolve publicly to the
  ingress before the certificate is issued, and the Let's Encrypt production
  quota (50 certs/domain/week) burns fast while debugging. Start on
  `letsencrypt-staging`.
- **Keycloak imports its realm once.** Changing `keycloak.realm.*` after the
  first sync does nothing on a running instance (the realm exists, Keycloak
  skips the import): change it in the admin console, or delete the realm and
  restart the pod. Same for the bootstrap admin password: sealed value read
  on the first start only. Its admin console is only reachable through a
  port-forward (MAIR-414, see the Keycloak section).
- **`maxSurge: 0` with `replicaCount: 1` means downtime on every deploy** (old
  pod killed before the new one is ready). Deliberate on a small VM; it is not a
  rolling update.
- **`replicaCount: 2` on Redis would give two independent caches**, not a
  replicated one. Leave it at 1.
- Redis uses `emptyDir` by default (`redis.persistence.enabled: false`): the
  AOF survives a container restart but not a new pod (config change, node
  reboot), which empties the JWT revocation list: revoked tokens are then
  accepted again by every API but Core until they expire (`JWT_TIMEOUT`).
  Any change to the Redis ConfigMap restarts the pod (checksum annotation).
- **`scripts/seal-secrets.sh`'s `REDIS_ROLES` and `DB_ROLES` lists are
  hand-maintained**, not read from the chart. `REDIS_ROLES` must be kept in
  sync with `global.apis.instances` (APIs only since MAIR-414); `DB_ROLES`
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

- **Keycloak runs one replica with a local cache** (`KC_CACHE=local`):
  scaling it needs Infinispan clustering, not just `replicas`. Its Postgres
  is now backed up (`backup.keycloak.enabled`, MAIR-231), but the restore
  Job only automates the Mairie360 database — restoring the Keycloak dump
  is still a manual `restic dump | pg_restore` (`charts/backup/README.md`).
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
- Monitoring is a POC (MAIR-131): the `observability` collector covers
  `core-api` traces and pod CPU/RAM on `dev` only. `global.monitoringNamespace`
  still opens the NetworkPolicy for a Prometheus that is not deployed.

## Pull request reviewers

Every PR requests a review from the whole team, minus its author: `CarolinHugo`, `LAURETbenjamin`, `MathTek` and `Quentintnrl` (`gh pr create … --reviewer CarolinHugo,LAURETbenjamin,MathTek`). `.github/CODEOWNERS` makes GitHub request them automatically as well.
