# Deploiment

Dépôt GitOps de **Mairie360**. Aucun code applicatif ici : des charts Helm, des
valeurs par instance, et l'amorçage Argo CD.

## Topologie

**Un Argo CD et une instance Mairie360 par machine.** Un groupe = un Argo CD +
ses instances.

```
Groupe mairie360          Groupe client-paris
  machine argocd            machine argocd
  machine dev               machine prod
  machine staging
  machine prod
```

Chaque Argo CD ne connaît que les instances de son groupe. Un client compromis
n'expose aucun autre client : l'isolation vient de la topologie, pas d'une
convention de nommage.

Le provisionnement des machines est dans le dépôt
[`mairie360/ansible`](https://github.com/mairie360/ansible).

## Contenu

| Chemin | Rôle |
|---|---|
| `charts/mairie360-stack/` | Le chart : Postgres, Redis, migrations, sauvegarde (backup), Keycloak (SSO), 5 APIs, 7 BFFs, 8 fronts |
| `clusters/<org>/instances/<env>/` | `values.yaml` + `secrets.yaml` d'une instance |
| `bootstrap/` | Amorçage Argo CD (voir `bootstrap/README.md`) |
| `scripts/` | Préparation d'un nœud, scellement des secrets, recette, flux réseau (Hubble) |

## Ajouter une instance

1. Créer `clusters/<org>/instances/<env>/values.yaml` (copier un existant).
2. Declare the machine in the Ansible inventory and run `site.yml`. Its
   phase 4 seals the instance secrets with `scripts/seal-secrets.sh` on the
   group's Argo CD machine (the only one that reaches the instance API server)
   and asks for the external keys it cannot find:
   - `RESEND_API_KEY`: Resend API key, sealed as `SMTP_PASSWORD` (core-api e-mails);
   - `S3_ACCESS_KEY` / `S3_SECRET_KEY`: Object Storage key pair (Scaleway) read
     by elearning-api, which does not start without it;
   - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`: backup bucket
     (`charts/mairie360-stack/charts/backup/README.md`), only when `backup.enabled`.
   - `ADMIN_EMAIL`: the town hall administrator's e-mail (MAIR-170). Sealed as
     `ADMIN_EMAIL` into `<env>-database-secret` alongside a generated
     `ADMIN_PASSWORD`; the Liquibase Job creates or resets the admin account
     with them, `first_connect = TRUE`. Left empty, the admin account keeps
     its `Database` changelog template credentials.

   `<env>-keycloak-secret` (MAIR-139: Keycloak bootstrap admin, its Postgres
   role, the `bff-user` client secret) is generated entirely, nothing to
   provide. The DNS records must cover `auth.<domain>` as well as the fronts.

   It then writes `clusters/<org>/instances/<env>/secrets.yaml` into this
   checkout.
3. Commit and push it:

```bash
git add clusters/<org>/instances/<env>/secrets.yaml
git commit -m "chore(<org>/<env>): seal secrets" && git push
```

L'Argo CD du groupe détecte le nouveau dossier et synchronise tout seul.

## Vérifier une modification du chart

```bash
helm dependency build ./charts/mairie360-stack
helm lint ./charts/mairie360-stack
helm unittest ./charts/mairie360-stack
helm template r ./charts/mairie360-stack \
  -f ./clusters/mairie360/instances/dev/values.yaml \
  | kubeconform -strict -summary -schema-location default -skip CiliumNetworkPolicy
```

C'est exactement ce que fait la CI. Un rendu qui réussit ne garantit pas que
l'API server acceptera le résultat : `kubeconform` valide contre les schémas
Kubernetes réels.

## Recette d'une instance déployée

```bash
./scripts/verify.sh <contexte-kube> dev dev.mairie360-eip.fr
```

## Network traffic (Cilium / Hubble)

Every machine runs Cilium as CNI (Ansible role `k8s_node`), which enforces
the `NetworkPolicy` objects below and lets Hubble record every flow with its
verdict — `ingress -> fronts -> bffs -> apis -> postgres / redis` and
`ingress -> keycloak -> keycloak-db`.

```bash
./scripts/hubble-flows.sh <contexte-kube> dev
```

prints the last flows of each hop, the dropped ones, and HTTP requests
(method, path, status) once `global.networkPolicy.ciliumL7Visibility` is on
for that instance. See `charts/mairie360-stack/templates/cilium-l7-visibility.yaml`
and the "Network observability" section of the `ansible` repo's `README.md`
for how the CNI itself is installed.

## Principes

- **Aucun secret en clair dans Git.** Uniquement des `SealedSecret`, dont la clé
  est propre à chaque machine.
- **No mobile image tag.** The tag is required and must exist: `dev-<sha>` on
  dev, `staging-<sha>` on staging, a published semver elsewhere, never
  `latest` / `*-latest`. `argocd-image-updater` moves it forward;
  `scripts/check-image-tags.sh` checks it in CI (MAIR-172).
- **Seuls les fronts et Keycloak (`auth.<domain>`) sont exposés.** APIs,
  BFFs, Postgres, Redis et la base de Keycloak sont en `ClusterIP`,
  cloisonnés par des `NetworkPolicy` en `default-deny`. L'API server (6443)
  est sur le VPN, jamais sur Internet.
- **Retour arrière = `git revert`.** Ne jamais corriger un cluster à la main :
  `selfHeal` écrase la modification en trois minutes.

Documentation détaillée : [`CLAUDE.md`](./CLAUDE.md).
