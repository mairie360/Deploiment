# Runbook de reprise après sinistre

Que faire quand une instance (dev, staging, prod, la prod d'un client) perd ses données ou
sa machine, dans l'ordre qui fonctionne. Version anglaise : [`docs/en/disaster-recovery.md`](../en/disaster-recovery.md).

Références : le chart de sauvegarde (`charts/mairie360-stack/charts/backup/README.md`,
prise des sauvegardes et Job de restauration), le dépôt `ansible` (`README.md`, phases et
secrets), `scripts/verify.sh` (recette d'une instance).

## Objectifs (RPO / RTO)

| | Cible | D'où elle vient |
| --- | --- | --- |
| **RPO**, données qui peuvent être perdues | **24 heures** d'écritures dans la base Mairie360 | Une sauvegarde par jour (`backup.schedule`, `0 3 * * *` UTC). Pas d'archivage WAL, pas de restauration à un instant donné, pas de réplica. |
| **RTO**, base restaurée sur une machine qui fonctionne | **1 heure** | Scénario A ci-dessous. |
| **RTO**, machine d'instance perdue puis reconstruite | **4 heures** | Scénario B : nouvelle machine, phases 1 à 3, synchronisation Argo CD, restauration, vérifications. Les certificats Let's Encrypt et la propagation DNS en font partie. |
| **RTO**, machine Argo CD perdue | **2 heures** | Scénario C : les instances continuent de tourner, seuls les déploiements s'arrêtent. |

Jamais récupéré : Redis (liste de révocation des sessions et caches : les utilisateurs se
reconnectent), les fichiers du bucket Object Storage de l'e-learning ne sont pas couverts
par ces sauvegardes (ils sont dans Scaleway Object Storage, hors de la machine), et tout ce
qui a été écrit après le snapshot.

Revoir ces cibles après chaque exercice (voir « Journal des exercices » à la fin).

## Ce qu'il faut avant de commencer

Conservé **hors** de la machine perdue, dans le coffre de l'équipe (le gestionnaire de mots
de passe partagé) :

| Élément | Fichier écrit par le rôle ansible | Sans lui |
| --- | --- | --- |
| Clé(s) de scellement de l'instance | `~/.mairie360/sealing-keys/<org>-<env>.yaml` | aucun `secrets.yaml` commité de l'instance ne se déchiffre : tout resceller (scénario D) |
| `RESTIC_PASSWORD` du bucket de sauvegarde | `~/.mairie360/restic-<org>-<env>.txt` | **toutes les sauvegardes sont illisibles**, rien ne peut être restauré |
| Premier mot de passe admin | `~/.mairie360/admin-<org>-<env>.txt` | utile seulement si le compte admin est recréé |

La phase 4 d'`ansible` écrit ces fichiers sur le poste de l'opérateur à chaque exécution :
les recopier dans le coffre à chaque fois (README d'`ansible`, « Backups of the generated
secrets »). Le fichier de clé contient toutes les clés que le contrôleur avait à ce
moment ; le contrôleur renouvelle sa clé tous les 30 jours, la copie doit donc être au
moins aussi récente que le dernier `secrets.yaml` commité.

Il faut aussi : l'inventaire local d'`ansible` (`inventory/hosts.yml`, hors git), la
console Scaleway (machines, DNS, bucket de sauvegarde), un checkout de `Deploiment` à côté
d'`ansible`, `kubectl`, `jq`, `helm`.

## Scénario A : données perdues ou corrompues, la machine va bien

1. **Choisir le snapshot.** Depuis une machine dont le contexte kube atteint l'instance (la
   machine Argo CD du groupe, `/root/.kube/instance-<env>.yaml`) :

   ```bash
   ./scripts/list-snapshots.sh <kube-context> <env>
   # une seule lignée : --host <POSTGRES_DB> (Mairie360) ou keycloak-<db> (Keycloak)
   ./scripts/list-snapshots.sh <kube-context> <env> snapshots --host <POSTGRES_DB>
   ```

   Le script lance `restic snapshots` dans un pod jetable construit à partir du CronJob de
   sauvegarde de l'instance (même image, mêmes clés, mêmes labels) ; aucun secret ne sort
   du cluster. Noter l'id du dernier snapshot pris **avant** l'incident.

2. **Arrêter les écrivains.** Toutes les connexions à la base doivent être fermées : une
   transaction ouverte bloque la restauration, et ce qui est écrit pendant la restauration
   est perdu.

   ```bash
   NS=mairie360-<env>
   # Argo CD les remettrait à l'échelle : le mettre en pause d'abord si l'Application se
   # synchronise seule (dev, et staging quand sa synchro auto est active). Sur la machine Argo CD :
   sudo kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
   sudo kubectl -n argocd patch application <env> --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

   kubectl --context <ctx> -n $NS scale deploy -l app.kubernetes.io/component=api --replicas=0
   kubectl --context <ctx> -n $NS scale deploy -l app.kubernetes.io/component=bff --replicas=0
   kubectl --context <ctx> -n $NS patch cronjob <env>-backup -p '{"spec":{"suspend":true}}'
   kubectl --context <ctx> -n $NS get cronjob -o name | grep retention \
     | xargs -r kubectl --context <ctx> -n $NS patch -p '{"spec":{"suspend":true}}'
   # Suspendre un CronJob n'arrête pas un Job déjà lancé : attendre la fin d'une
   # sauvegarde en cours (sa transaction pg_dump bloquerait la restauration).
   # Tout Job de sauvegarde encore actif (planifié ou créé à la main, ex. <env>-backup-after-restore) ;
   # ceux terminés ou en échec sont ignorés. Le Job de restauration n'existe pas encore à ce stade.
   active_backups() {
     kubectl --context <ctx> -n $NS get jobs -o json | jq -r --arg p "<env>-backup-" \
       '.items[] | select(.metadata.name | startswith($p)) | select(.metadata.name != $p + "restore")
        | select((.status.active // 0) > 0) | .metadata.name'
   }
   while [ -n "$(active_backups)" ]; do echo "en attente de : $(active_backups)"; sleep 15; done
   ```

   Le contrôleur d'ApplicationSet réécrit l'Application depuis son modèle en quelques
   secondes : il doit rester à 0 pour que le patch tienne. Tant qu'il est arrêté, aucune
   Application du groupe n'est créée ou mise à jour depuis l'ApplicationSet (les
   déploiements des autres instances continuent de se synchroniser).

3. **Restaurer** avec le Job de restauration, exactement comme le dit le README du chart
   de sauvegarde (« Restoring » : `helm template … -s
   charts/backup/templates/restore-job.yaml --set backup.restore.enabled=true --set
   backup.restore.snapshotId=<id> --set backup.restore.confirmDatabase=<base> | kubectl
   apply -f -`). Le suivre :

   ```bash
   kubectl --context <ctx> -n $NS logs -f job/<env>-backup-restore
   ```

   Le Job charge le dump en une transaction : si `pg_restore` échoue, la base reste telle
   qu'elle était. Avec `backup.sealing.enabled`, cette garantie ne couvre que le chargement :
   le dump est validé par l'initContainer `restore`, puis le conteneur `unseal` remet les
   données personnelles scellées. Si `unseal` échoue, la base contient déjà le snapshot avec
   ses données personnelles encore scellées : garder les écrivains arrêtés, corriger la
   cause (clé, secret), supprimer le Job en échec (`kubectl --context <ctx> -n $NS delete job
   <env>-backup-restore` : un Job `Failed` ne repart pas sur un nouvel `apply`) et le recréer
   jusqu'à ce qu'il se termine. Les utilisateurs
   effacés depuis le snapshot restent anonymisés.

4. **Keycloak** (instances avec `keycloak.enabled`, jusqu'à son retrait, MAIR-804) : sa
   base est une lignée à part que le Job ne restaure pas. Ne la restaurer que si la base
   Keycloak elle-même est perdue :

   ```bash
   kubectl --context <ctx> -n $NS scale deploy <env>-keycloak --replicas=0
   ./scripts/list-snapshots.sh <ctx> <env> dump <keycloak-snapshot-id> /keycloak.dump > keycloak.dump
   pg_restore --list keycloak.dump > /dev/null   # l'archive doit être complète avant de supprimer quoi que ce soit
   kubectl --context <ctx> -n $NS exec -i <env>-keycloak-db-0 -- \
     pg_restore --clean --if-exists --no-owner --single-transaction -U keycloak -d keycloak < keycloak.dump
   rm keycloak.dump
   kubectl --context <ctx> -n $NS scale deploy <env>-keycloak --replicas=1
   ```

5. **Redémarrer** tout ce qui a été arrêté, dans l'ordre inverse :

   ```bash
   kubectl --context <ctx> -n $NS patch cronjob <env>-backup -p '{"spec":{"suspend":false}}'
   kubectl --context <ctx> -n $NS get cronjob -o name | grep retention \
     | xargs -r kubectl --context <ctx> -n $NS patch -p '{"spec":{"suspend":false}}'
   # Machine Argo CD : le contrôleur d'ApplicationSet remet la politique de synchro
   sudo kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1
   ```

   Puis synchroniser l'Application (interface Argo CD, ou `argocd app sync <env> --core`
   sur la machine Argo CD) : elle remet les APIs et les BFFs au nombre de réplicas des
   values.

6. **Vérifier** : `./scripts/verify.sh <ctx> <env> <domaine>`, se connecter sur le front
   Login, ouvrir un projet et un calendrier. Lancer une fois le CronJob de sauvegarde à la
   main pour que le prochain snapshot ne soit pas dans 24 heures :

   ```bash
   kubectl --context <ctx> -n $NS create job --from=cronjob/<env>-backup <env>-backup-after-restore
   ```

## Scénario B : la machine de l'instance est perdue

L'ordre compte : le contrôleur sealed-secrets génère une **nouvelle** clé quand il démarre
sur un cluster qui n'en a pas, et le `secrets.yaml` commité ne se déchiffre plus. L'ancienne
clé revient **entre la phase 2 et la phase 3**, car c'est la phase 3 qui fait déployer le
contrôleur par Argo CD. La phase 4 n'est **pas** lancée : elle scellerait de nouveaux mots
de passe au lieu de ceux qu'utilisent le `secrets.yaml` commité (et les sauvegardes).

1. **Nouvelle machine.** La créer dans le projet Scaleway de l'instance (même type et même
   image que la machine perdue ; `mairie360/Infra` la décrit, jamais de `terraform apply`
   sans l'équipe). Pointer les enregistrements DNS du domaine de l'instance vers sa nouvelle
   IP publique.
2. **Inventaire.** Dans `ansible/inventory/hosts.yml`, changer `ansible_host` de l'instance
   pour la nouvelle adresse. Garder son `wg_ip`, son `org_id` et son `env_name`.
3. **Phases 1, 1b et 2**, sur tout le groupe (WireGuard a besoin de toutes les machines) :

   ```bash
   cd ansible
   ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances' --tags phase1,phase1b,phase2
   ```

4. **Remettre la clé de scellement**, depuis la copie du coffre :

   ```bash
   scripts/restore-sealing-key-file.sh ~/.mairie360/sealing-keys/<org>-<env>.yaml root@<nouvelle machine>
   ```

   Le script applique les clés avec le `kubectl` k3s de la machine (rien n'est écrit sur
   disque) et redémarre le contrôleur s'il tourne déjà.
5. **Phase 3** (et phase 5 si le groupe a le runner de promotion) :

   ```bash
   ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances' --tags phase3
   ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances' --tags phase5
   ```

   Argo CD réenregistre le cluster et déploie le socle (sealed-secrets, cert-manager,
   contrôleur d'ingress), puis l'instance (seule sur dev ; sur staging et prod,
   synchroniser l'Application à la main).
6. **Les secrets se déchiffrent.** Chaque SealedSecret doit être `Synced` :

   ```bash
   kubectl --context <ctx> -n mairie360-<env> get sealedsecrets
   ```

   Un statut `no key could decrypt secret` signifie que le fichier de clé est plus ancien
   que le `secrets.yaml` commité : trouver une copie plus récente, ou passer au scénario D.
7. **Attendre la stack.** Postgres démarre vide, Liquibase crée le schéma et le compte
   admin, les APIs démarrent. Les certificats reviennent de Let's Encrypt (attention à ses
   limites : 5 certificats identiques par semaine et par ensemble de domaines).
8. **Restaurer les données** : scénario A à partir de l'étape 1. Le bucket de sauvegarde
   est hors de la machine et ses clés sont dans `<env>-backup-secret`, déchiffré.
9. **Clôturer** : `ansible-playbook playbooks/verify.yml`, puis recopier les fichiers de
   `~/.mairie360` dans le coffre si quelque chose a été rescellé.

## Scénario C : la machine Argo CD est perdue

Les instances continuent de servir : seules les synchronisations et le runner de promotion
s'arrêtent.

1. Nouvelle machine, inventaire mis à jour (`ansible_host` de `<org>-argocd`), DNS s'il y en a.
2. `ansible-playbook playbooks/site.yml --limit '<org>_argocd:<org>_instances'` (toutes les
   phases : la machine Argo CD ne porte aucune clé de scellement, la phase 4 garde toutes
   les valeurs déjà présentes sur les instances et ne fait que les resceller).
3. `ansible-playbook playbooks/verify.yml`, puis vérifier que chaque Application est `Synced`.

## Scénario D : la clé de scellement est perdue elle aussi

Le `secrets.yaml` commité de l'instance ne sert plus à rien. Ce qui compte encore, c'est
`RESTIC_PASSWORD` (coffre) : avec lui, les données reviennent.

1. Dérouler le scénario B jusqu'à l'étape 3, sauter l'étape 4, lancer la phase 3 puis la
   **phase 4** en redonnant l'ancien `RESTIC_PASSWORD` (le rôle lit
   `~/.mairie360/restic-<org>-<env>.txt` quand l'instance n'en a pas : y remettre d'abord la
   copie du coffre). La phase 4 génère de nouveaux secrets base, Redis et JWT, et demande
   les clés externes (Resend, Object Storage, clés du bucket de sauvegarde, e-mail admin).
2. Publier la nouvelle clé de session, puis les secrets. La phase 4 lance
   `scripts/seal-secrets.sh`, qui affiche la nouvelle clé publique de la clé de session de
   Core : la mettre dans `global.jwt.publicKey` du `values.yaml` de l'instance (l'ancien
   bloc peut partir, sa clé privée est perdue), commiter et pousser, puis commiter et
   pousser le nouveau `secrets.yaml` et laisser Argo CD déployer les deux. Sans la nouvelle
   clé publique, tous les services refusent les jetons que Core signe et personne ne peut
   se connecter.
3. Restaurer les données (scénario A). Le dump est restauré avec `--no-owner`, les nouveaux
   mots de passe de la base n'ont donc pas d'importance.
4. Ranger la nouvelle clé de scellement et le mot de passe admin dans le coffre. Tous les
   utilisateurs doivent se reconnecter (nouvelles clés JWT).

## Journal des exercices

Un exercice rejoue les étapes risquées sur des clusters jetables, jamais sur une vraie instance.

| Date | Ce qui a été rejoué | Résultat |
| --- | --- | --- |
| 2026-11-16 | Scénario B étapes 4 à 6 sur des clusters kind jetables (`ansible` `tests/mair_244_sealing_key_drill.sh`) : un Secret scellé par le contrôleur du cluster 1, la clé sauvegardée comme le fait la phase 4, le cluster 1 supprimé, la clé remise sur le cluster 2 avec `restore-sealing-key-file.sh`, puis le SealedSecret appliqué | Déchiffré quand la clé est remise avant le contrôleur, et quand elle l'est après (le script redémarre le contrôleur). Un cluster sans la clé ne le déchiffre pas (`no key could decrypt secret`). |
| 2026-11-16 | `scripts/list-snapshots.sh` sur un cluster kind avec le CronJob dev rendu et un `dev-backup-secret` factice (`restic version`, puis `restic snapshots` contre le bucket dev, injoignable), plus `tests/scripts/mair_244_list_snapshots_test.sh` | Le pod démarre avec l'image, les clés et les labels du CronJob, affiche la sortie de restic et est supprimé ensuite ; aucune valeur secrète ne passe sur la ligne de commande. |

La partie base (sauvegarde puis restauration sur un vrai cluster) est rejouée par le test
e2e du chart de sauvegarde (`tests/e2e/restore.sh`, MAIR-240).
