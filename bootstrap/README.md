# bootstrap/

Amorçage GitOps. **Une machine Argo CD par groupe** (mairie360, puis un par
client) ; chaque Argo CD ne pilote que les instances de son propre groupe.

```
Ansible (rôle k8s_argocd) sur la machine Argo CD du groupe
  ├── installe Argo CD
  ├── kubectl apply bootstrap/platform-app.yaml
  │     └── platform (app-of-apps) → syncs bootstrap/appsets/
  │           ├── sealed-secrets-appset   ┐
  │           ├── cert-manager-appset     │ clusters generator, selector
  │           ├── cluster-issuer-appset   │ mairie360.fr/role=instance
  │           ├── ingress-nginx-appset    │ → instances only; the last two
  │           ├── traefik-appset          ┘   split on mairie360.fr/ingress
  │           └── image-updater-app         → in-cluster (Argo CD machine)
  │
  ├── kubectl apply <instances-appset rendu>   ← templates/ du dépôt ansible
  │     └── une Application par clusters/<org>/instances/*
  ├── argocd/ghcr-secret                       ← GHCR_USER / GHCR_TOKEN, never committed
  └── kubectl apply <image-updaters rendus>    ← one ImageUpdater per instance
```

`argocd-image-updater` v1 is configured by `ImageUpdater` resources, not by
Application annotations. They depend on the group's instances (one per
environment, tag policy per environment name), so Ansible renders them too,
from `roles/k8s_argocd/templates/image-updaters.yaml.j2`.

## Ingress controller: ingress-nginx or Traefik (MAIR-260)

A machine runs exactly one ingress controller: both publish a LoadBalancer
Service on 80/443 and k3s ServiceLB cannot bind a port twice. The Argo CD
cluster label `mairie360.fr/ingress` (ansible var `ingress_controller`)
chooses it: `traefik` → `traefik-appset.yaml` (chart pinned there, values in
`values/traefik.yaml`, also used by `tests/e2e/run.sh`), anything else →
`ingress-nginx-appset.yaml` (retired upstream, kept until prod has
switched). Both carry the Argo CD resources finalizer, so flipping the label
removes one controller and installs the other. The instance values must say
the same (`global.ingressController`). Procedure and rollback:
`docs/adr/0001-replace-ingress-nginx.md`.

`values/` is not synced by the platform app (it only reads `appsets/`): its
files are read by the AppSets through an Argo CD `$values` source that
tracks `main`, like `cluster-addons/`.

## Pourquoi l'ApplicationSet des instances n'est pas ici

Il dépend de `org_id` : l'Argo CD de `mairie360` doit scanner
`clusters/mairie360/instances/*`, celui d'un client
`clusters/<client>/instances/*`. C'est Ansible qui le rend, depuis
`roles/k8s_argocd/templates/instances-appset.yaml.j2` du dépôt `ansible`.

C'est ce scope par groupe qui garantit qu'un Argo CD ne voit jamais les
instances d'un autre client — et qu'un environnement nommé `prod` chez un
client n'entre pas en collision avec le `prod` de mairie360.

## Le label `mairie360.fr/role=instance`

Posé par Ansible au moment de `argocd cluster add` (rôle `k8s_instance_link`).
Les AppSets du socle l'utilisent comme sélecteur, ce qui exclut automatiquement
la machine Argo CD (`in-cluster`, non labellisée) : elle n'a besoin ni
d'ingress public, ni de cert-manager, ni de base de données.

## Ordre de la première mise en route

1. `sealed-secrets` must be `Healthy` **before** `scripts/seal-secrets.sh`:
   `kubeseal` asks the controller for its public key. Ansible's phase 4
   (`k8s_instance_secrets`) waits for it before sealing.
2. `cert-manager` avant `cluster-issuers` — la politique de reprise encaisse le
   « CRD not found » initial, mais la première synchronisation apparaîtra en
   erreur une minute ou deux.
3. L'instance ne convergera pas tant que son `secrets.yaml` n'existe pas : les
   pods restent en `CreateContainerConfigError`, faute de Secret à monter.
   C'est attendu, pas un bug.

## Accès à Argo CD

Pas d'Ingress public. Argo CD détient les droits d'administration sur les
instances de son groupe : il est joignable par `kubectl port-forward` à travers
le VPN, jamais depuis Internet.
