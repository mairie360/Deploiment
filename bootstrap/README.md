# bootstrap/

GitOps bootstrap. **One Argo CD machine per group** (mairie360, then one per
client); each Argo CD only manages the instances of its own group.

```
Ansible (role k8s_argocd) on the group's Argo CD machine
  ├── installs Argo CD
  ├── kubectl apply bootstrap/platform-app.yaml
  │     └── platform (app-of-apps, follows main) → syncs bootstrap/appsets/
  │           ├── sealed-secrets-appset   ┐ clusters generator, selector
  │           ├── cert-manager-appset     │ mairie360.fr/role=instance
  │           ├── cluster-issuer-appset   │ → instances only; the last two
  │           ├── ingress-nginx-appset    │   split on mairie360.fr/ingress.
  │           ├── traefik-appset          ┘   Each reads addons/<x> (or
  │           │                               cluster-addons/) at the
  │           │                               cluster's mairie360.fr/revision
  │           └── image-updater-app         → in-cluster (Argo CD machine)
  │
  ├── kubectl apply <rendered instances-appset>  ← templates/ of the ansible repo
  │     └── one Application per clusters/<org>/instances/*
  ├── argocd/ghcr-secret                         ← GHCR_USER / GHCR_TOKEN, never committed
  └── kubectl apply <rendered image-updaters>    ← one ImageUpdater per instance
```

`argocd-image-updater` v1 is configured by `ImageUpdater` resources, not by
Application annotations. They depend on the group's instances (one per
environment, tag policy per environment name), so Ansible renders them too,
from `roles/k8s_argocd/templates/image-updaters.yaml.j2`.

## Versions are promoted, AppSets are not (MAIR-346)

`platform` reads `appsets/` from `main` and applies it to every machine at
once. So the AppSets only say **where** (cluster selector) and **at which
revision**; everything that changes over time lives in files read at the
machine's own revision:

| Directory | Content |
|---|---|
| `addons/<addon>/` | Wrapper chart: `Chart.yaml` pins the upstream chart as its only dependency, `Chart.lock` (committed) pins its digest, `values.yaml` holds the values under the dependency's name (`cert-manager:`, `traefik:`, …). |
| `cluster-addons/` | Plain manifests (ClusterIssuers). |

The revision is the Argo CD cluster annotation `mairie360.fr/revision`,
written by Ansible (role `k8s_instance_link`) from `deploiment_env_revisions`:
`main` for dev, `staging`, `prod`. The AppSets read it through the clusters
generator's `values.revision` and fall back to `main` when it is absent. A
bump in `addons/` therefore reaches dev on merge, and staging then prod only
through the `Promote` workflow, like the application chart
(`docs/adr/0002-environment-promotion.md`).

Still global, straight from `main`: `platform-app.yaml`, the AppSet manifests
themselves (a selector or sync policy change hits every machine at once) and
`image-updater-app.yaml`, which runs on the Argo CD machine, not on an
instance. Adding an addon takes two PRs: add `addons/<new>/` and promote it to
staging and prod, then reference it from an AppSet.

`tests/e2e/run.sh` installs `addons/traefik` and `addons/cert-manager`
themselves, so the ingress e2e test runs the machines' versions and values.

## Ingress controller: ingress-nginx or Traefik (MAIR-260)

A machine runs exactly one ingress controller: both publish a LoadBalancer
Service on 80/443 and k3s ServiceLB cannot bind a port twice. The Argo CD
cluster label `mairie360.fr/ingress` (ansible var `ingress_controller`)
chooses it: `traefik` → `traefik-appset.yaml` (`addons/traefik`), anything
else → `ingress-nginx-appset.yaml` (`addons/ingress-nginx`, retired upstream,
kept until prod has switched). Both carry the Argo CD resources finalizer, so
flipping the label removes one controller and installs the other. The
instance values must say the same (`global.ingressController`). Procedure and
rollback: `docs/adr/0001-replace-ingress-nginx.md`.

## Why the instances ApplicationSet is not here

It depends on `org_id`: the `mairie360` Argo CD must scan
`clusters/mairie360/instances/*`, a client's `clusters/<client>/instances/*`.
Ansible renders it from `roles/k8s_argocd/templates/instances-appset.yaml.j2`
in the `ansible` repo.

That per-group scope is what guarantees that an Argo CD never sees another
client's instances, and that an environment named `prod` at a client does not
collide with mairie360's `prod`.

## The `mairie360.fr/role=instance` label

Set by Ansible during `argocd cluster add` (role `k8s_instance_link`). The
bootstrap AppSets select on it, which automatically excludes the Argo CD
machine (`in-cluster`, unlabelled): it needs no public ingress, no
cert-manager and no database.

## First start order

1. `sealed-secrets` must be `Healthy` **before** `scripts/seal-secrets.sh`:
   `kubeseal` asks the controller for its public key. Ansible's phase 4
   (`k8s_instance_secrets`) waits for it before sealing.
2. `cert-manager` before `cluster-issuers`: the retry policy absorbs the
   initial "CRD not found", but the first sync shows as failed for a minute or
   two.
3. The instance does not converge until its `secrets.yaml` exists: pods stay
   in `CreateContainerConfigError`, with no Secret to mount. Expected, not a
   bug.

## Access to Argo CD

No public Ingress. Argo CD holds admin rights on the instances of its group:
it is reached through `kubectl port-forward` over the VPN, never from the
Internet.
