# PostgreSQL sur CloudNativePG : bascule et restauration à un instant donné

Le sous-chart `database` peut faire tourner le PostgreSQL de Mairie360 de deux façons :

- **`statefulset`** (par défaut) : un pod Postgres issu de `ghcr.io/mairie360/database`,
  sauvegardé une fois par jour par le CronJob `backup` (`pg_dump` + restic). Une base perdue ou
  corrompue revient au dernier dump : jusqu'à 24 heures d'écritures sont perdues.
- **`cnpg`** : un `Cluster` [CloudNativePG](https://cloudnative-pg.io) dont le WAL est archivé
  en continu dans le bucket de sauvegarde de l'instance par le plugin Barman Cloud, avec une
  sauvegarde de base chaque nuit. La base peut être restaurée à **n'importe quelle seconde** des
  35 derniers jours.

Version anglaise : [`docs/en/cloudnativepg.md`](../en/cloudnativepg.md). Le runbook général de
reprise après sinistre est [`disaster-recovery.md`](disaster-recovery.md).

## Comment les pièces s'assemblent

| Pièce | Où | Rôle |
| --- | --- | --- |
| Opérateur + plugin Barman Cloud | `bootstrap/addons/cloudnative-pg` (namespace `cnpg-system`, un par machine d'instance) | Font tourner le `Cluster`, archivent le WAL, prennent et restaurent les sauvegardes. Le plugin a besoin de cert-manager, déjà présent sur chaque instance. |
| `Cluster` `<release>-database-g<génération>` | `charts/database/templates/cnpg-cluster.yaml` | Postgres (image officielle `ghcr.io/cloudnative-pg/postgresql`, Debian bookworm comme celle du StatefulSet). Argo CD ne le supprime jamais (`Prune=false,Delete=false`). |
| `ObjectStore` `<release>-database-backups` | même fichier | `s3://<bucket>/cnpg/<nom du cluster>/`, clés de `<release>-backup-secret`, rétention `35d`. |
| `ScheduledBackup` `<cluster>-daily` | même fichier | Une sauvegarde de base à 02:30 UTC, et une dès que le Cluster est prêt. |
| Service client `<release>-database` | `charts/database/templates/service.yaml` | `engine` choisit ce qu'il atteint : le pod du StatefulSet ou le primaire de la génération courante. APIs, Liquibase, backup et rétention gardent le même hôte. |
| `<release>-database-superuser` | `scripts/seal-secrets.sh` | `kubernetes.io/basic-auth`, `postgres` et le `POSTGRES_PASSWORD` de `<release>-database-secret` : chaque Job se connecte de la même façon sur les deux moteurs. |

La sauvegarde `pg_dump` + restic continue sur les deux moteurs : elle reste la copie logique
de long terme (et celle sur laquelle travaille `backup.sealing`), l'archive WAL est la copie
fine.

**Pourquoi 35 jours :** le bucket de sauvegarde a un verrou d'objet de 30 jours en mode
COMPLIANCE (`mairie360/Infra`). Le plugin supprime les objets plus vieux que sa rétention ; avec
une rétention plus courte que le verrou, ces suppressions échoueraient.

**Générations :** CloudNativePG ne restaure jamais sur place, il démarre un nouveau `Cluster` à
partir des sauvegardes. Le chart nomme chaque Cluster d'après `database.cnpg.generation` ; une
restauration l'incrémente, le nouveau Cluster se restaure depuis le dossier de la génération
précédente dans le bucket et archive dans le sien. Le Service client suit la génération
courante.

## Avant la première bascule d'une instance

1. L'opérateur tourne sur la machine : l'AppSet `cloudnative-pg-appset.yaml` le déploie sur
   chaque instance (il lit `bootstrap/addons/cloudnative-pg` à la révision de la machine,
   l'addon doit donc avoir été promu dans cet environnement d'abord).

   ```bash
   kubectl -n cnpg-system get deploy        # cnpg-cloudnative-pg et barman-cloud : Available
   ```

2. `<release>-database-superuser` est scellé : relancer les secrets de l'instance (ansible
   `playbooks/secrets.yml`, ou `scripts/seal-secrets.sh`), committer `secrets.yaml`.
   `scripts/check-instance-secrets.sh` (Promote) refuse une instance avec `cnpg.enabled` sans
   ce Secret.
3. Le bucket de sauvegarde et `<release>-backup-secret` existent (c'est déjà le cas sur chaque
   instance suivie).

## Bascule d'une instance existante (StatefulSet → CloudNativePG)

Prévoir une fenêtre de maintenance : les écritures s'arrêtent pendant la copie de la base.
Compter quelques minutes pour une petite base.

1. **Arrêter les écritures.** Désactiver l'auto-sync de l'Application de l'instance dans
   Argo CD (sur dev et staging), puis :

   ```bash
   kubectl -n mairie360-<env> scale deploy -l app.kubernetes.io/component=api --replicas=0
   ```

2. **Commit 1, la copie.** Dans le `values.yaml` de l'instance :

   ```yaml
   database:
     cnpg:
       enabled: true
       bootstrap: import
       backup:
         s3:
           endpoint: https://s3.fr-par.scw.cloud
           bucket: <org>-backups-<env>
   ```

   Synchroniser **seulement les nouveaux objets** (Argo CD → Sync → le `Cluster`,
   l'`ObjectStore`, le `ScheduledBackup`, la NetworkPolicy `<release>-database-allow-cnpg` et le
   Secret `<release>-database-superuser`) : une synchronisation complète relancerait les APIs.
   CloudNativePG crée `<release>-database-g1` et copie la base et ses rôles depuis le
   StatefulSet (via `<release>-database-hl`). Le Service client pointe toujours sur le
   StatefulSet.

   ```bash
   kubectl -n mairie360-<env> get cluster <release>-database-g1     # STATUS : Cluster in healthy state
   kubectl -n mairie360-<env> get backup                             # première sauvegarde de base : completed
   ```

   Comparer quelques comptages (`users`, `projects`, `access_logs`) entre les deux pods
   (`kubectl exec <release>-database-0` et `kubectl exec <release>-database-g1-1`, `psql -U postgres -d <db>`).

3. **Commit 2, la bascule.** Ajouter `engine: cnpg` sous `database`. Synchroniser : le Job
   Liquibase tourne sur la nouvelle base (il réapplique les mots de passe des rôles des APIs),
   le Service client atteint le nouveau primaire, Argo CD relance les APIs. Réactiver
   l'auto-sync et lancer `scripts/verify.sh`.

   **Revenir en arrière** à ce stade, c'est remettre `engine: statefulset` : le StatefulSet est
   toujours là, mais tout ce qui a été écrit depuis la bascule n'est que dans le Cluster.

4. **Commit 3, quelques jours plus tard.** `statefulset.enabled: false`. Garder
   `bootstrap: import` : l'opérateur ne le lit qu'à la création d'un Cluster, et l'enlever ne
   ferait qu'afficher un écart. Le volume du StatefulSet est conservé ; le supprimer quand le
   retour arrière n'est plus voulu :

   ```bash
   kubectl -n mairie360-<env> delete pvc data-<release>-database-0
   ```

Une **nouvelle** instance démarre directement avec `cnpg.enabled: true`, `engine: cnpg`,
`statefulset.enabled: false` et le `bootstrap: initdb` par défaut (base vide, créée pour
Liquibase).

## Restauration à un instant donné

1. **Choisir l'instant** juste avant le dommage, en horodatage RFC 3339 avec son fuseau
   (`2026-11-20T09:30:00+01:00`). Vérifier qu'il est couvert :

   ```bash
   kubectl -n mairie360-<env> get backup --sort-by=.status.startedAt   # sauvegardes de base
   kubectl -n mairie360-<env> get cluster <release>-database-g<N> \
     -o jsonpath='{.status.firstRecoverabilityPoint}{"\n"}'
   ```

2. **Arrêter les écritures** comme pour la bascule (auto-sync coupé, APIs à 0), pour que plus
   rien ne soit écrit dans la génération N.
3. **Un seul commit** dans le `values.yaml` de l'instance :

   ```yaml
   database:
     cnpg:
       generation: <N+1>
       bootstrap: recovery
       recovery:
         targetTime: "2026-11-20T09:30:00+01:00"   # "" = rejouer tout le WAL archivé
   ```

   Synchroniser seulement le nouveau `Cluster`, son `ScheduledBackup` et le Service
   `<release>-database`. CloudNativePG crée `<release>-database-g<N+1>` à partir de la
   sauvegarde de base antérieure à cet instant et rejoue le WAL jusqu'à lui ; le Service client
   le sélectionne déjà (aucun endpoint tant que la restauration n'est pas finie).
   La génération N continue de tourner, intacte : Argo CD ne supprime jamais un Cluster.
4. **Vérifier** les données, puis tout synchroniser (Liquibase, les APIs reviennent), réactiver
   l'auto-sync, lancer `scripts/verify.sh`. Supprimer ensuite l'ancienne génération à la main
   (son archive reste dans le bucket jusqu'à l'expiration du verrou ; supprimer
   `s3://<bucket>/cnpg/<release>-database-g<N>/` ensuite pour récupérer la place) :

   ```bash
   kubectl -n mairie360-<env> delete cluster <release>-database-g<N>
   ```

Garder `bootstrap: recovery` dans les values ensuite, pour la même raison que `import`.
Une restauration depuis une génération plus ancienne que N renseigne `recovery.fromGeneration`.

Le dump restic (`backup.restore.*`, scénario A de `disaster-recovery.md`) fonctionne toujours
sur une instance CloudNativePG : il restaure une journée entière, dans la génération courante.

## Limites

- Une instance par Cluster (`cnpg.instances: 1`), comme les machines : pas encore de
  basculement automatique. Un réplica ne demande que `instances: 2` et la place sur la machine.
- L'archive WAL vit dans le même bucket que les dumps : perdre la paire de clés du bucket
  arrête les deux jusqu'à ce qu'elle soit rescellée.
- Pas encore essayé sur une vraie instance : les en-têtes de somme de contrôle du client S3 du
  plugin face au verrou d'objet de Scaleway. Surveiller le premier `Backup` et
  `kubectl -n mairie360-<env> get cluster` (condition `ContinuousArchiving`) après la bascule
  de dev.
