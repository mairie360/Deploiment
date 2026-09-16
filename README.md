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
| `charts/mairie360-stack/` | Le chart : Postgres, Redis, migrations, 7 APIs, 7 BFFs, 8 fronts |
| `clusters/<org>/instances/<env>/` | `values.yaml` + `secrets.yaml` d'une instance |
| `bootstrap/` | Amorçage Argo CD (voir `bootstrap/README.md`) |
| `scripts/` | Préparation d'un nœud, scellement des secrets, recette |

## Ajouter une instance

1. Créer `clusters/<org>/instances/<env>/values.yaml` (copier un existant).
2. Déclarer la machine dans l'inventaire Ansible, lancer `site.yml`.
3. Générer ses secrets et pousser :

```bash
# S3_ACCESS_KEY / S3_SECRET_KEY : couple de clés Object Storage (Scaleway)
# lu par elearning-api. Sans elles, elearning-api ne démarre pas.
S3_ACCESS_KEY=SCW... S3_SECRET_KEY=... \
  ./scripts/seal-secrets.sh <contexte-kube> <org> <env>
git add clusters/<org>/instances/<env>/secrets.yaml
git commit -m "chore(<org>/<env>): secrets scellés" && git push
```

L'Argo CD du groupe détecte le nouveau dossier et synchronise tout seul.

## Vérifier une modification du chart

```bash
helm dependency build ./charts/mairie360-stack
helm lint ./charts/mairie360-stack
helm unittest ./charts/mairie360-stack
helm template r ./charts/mairie360-stack \
  -f ./clusters/mairie360/instances/dev/values.yaml \
  | kubeconform -strict -summary -schema-location default
```

C'est exactement ce que fait la CI. Un rendu qui réussit ne garantit pas que
l'API server acceptera le résultat : `kubeconform` valide contre les schémas
Kubernetes réels.

## Recette d'une instance déployée

```bash
./scripts/verify.sh <contexte-kube> dev dev.mairie360-eip.fr
```

## Principes

- **Aucun secret en clair dans Git.** Uniquement des `SealedSecret`, dont la clé
  est propre à chaque machine.
- **Aucune image en `latest`.** Le tag est obligatoire ; `argocd-image-updater`
  le met à jour.
- **Seuls les fronts sont exposés.** APIs, BFFs, Postgres et Redis sont en
  `ClusterIP`, cloisonnés par des `NetworkPolicy` en `default-deny`. L'API
  server (6443) est sur le VPN, jamais sur Internet.
- **Retour arrière = `git revert`.** Ne jamais corriger un cluster à la main :
  `selfHeal` écrase la modification en trois minutes.

Documentation détaillée : [`CLAUDE.md`](./CLAUDE.md).
