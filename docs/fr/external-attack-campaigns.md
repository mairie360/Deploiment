# Campagnes d'attaque externe : règles d'engagement

Le cadre que suit chaque campagne d'attaque externe : ce qui peut être attaqué, d'où, avec
quels comptes, à quel débit, quand s'arrêter et qui prévenir. Une campagne rejoue depuis
Internet ce que tenterait un attaquant réel, en boîte noire (sans compte) et en boîte grise
(un compte Guest), et vérifie que rien n'aboutit. Version anglaise :
[`docs/en/external-attack-campaigns.md`](../en/external-attack-campaigns.md).

Les dépôts sont publics : aucune défense ne doit reposer sur le secret de l'implémentation,
et les scénarios supposent que l'attaquant a lu ce fichier.

## Cible

| | |
| --- | --- |
| Cible | **staging** uniquement : `*.staging.mairie360-eip.fr` (les fronts, seuls services exposés) |
| Jamais | la prod (`*.prod.mairie360-eip.fr`), une instance cliente, dev, les machines Argo CD, les API et consoles de Scaleway |
| Pourquoi staging | elle fait tourner la version sur le point d'aller en prod, avec les réglages de prod (network policies, Traefik, secrets scellés), et ne contient aucune donnée d'usager réel |
| Exception | la reconnaissance mensuelle (ci-dessous) regarde toutes les machines du groupe mairie360, prod comprise : elle ne fait que se connecter aux ports et lire des pages publiques, jamais un groupe client |

Staging peut être indisponible pendant une fenêtre de campagne. Elle reste synchronisée à la
main (`deploiment_auto_sync_envs` vaut `dev` seulement) : ne pas la promouvoir ni la
synchroniser pendant une fenêtre, pour qu'un constat soit lié à un commit connu. Ce commit est
noté dans le rapport de campagne.

## Comptes de test

Créés par la migration de la base (`seed_test_accounts`) sur les instances dont les values
activent `liquibase.testAccounts` (dev et staging). `clusters/_base/prod.yaml` l'interdit :
une instance de prod qui l'active ne se rend pas, `scripts/seal-secrets.sh` refuse le mot de
passe pour un environnement nommé `prod`, et `scripts/verify.sh` échoue s'il y est scellé.

| E-mail | Rôle | Usage |
| --- | --- | --- |
| `attack.admin@example.invalid` | `Admin` | vérifications seulement (ce que voit un administrateur après une attaque), jamais source d'attaque |
| `attack.maire@example.invalid` | `Maire` | scénarios de contrôle d'accès |
| `attack.responsable@example.invalid` | `Responsable` | scénarios de contrôle d'accès |
| `attack.user@example.invalid` | `User` | scénarios de contrôle d'accès |
| `attack.user.b@example.invalid` | `User` | propriétaire des données que les autres comptes essaient d'atteindre |
| `attack.user.c@example.invalid` | `User` | seconde victime, scénarios entre utilisateurs |
| `attack.guest@example.invalid` | `Guest` | la posture boîte grise |

Les sept comptes partagent un mot de passe. Le domaine `example.invalid` ne reçoit aucun
e-mail : aucun parcours par e-mail (réinitialisation, invitation) ne peut être testé avec eux.
Chaque déploiement (le Job Liquibase tourne à chaque sync) les remet dans un état connu : même
mot de passe, rôle, actifs, sans étape de première connexion. Leurs projets, messages et
événements sont conservés : un scénario nettoie ce qu'il a créé.

### Fixer le mot de passe (une fois par instance, dev puis staging)

Prérequis : le `liquibase.image.tag` de l'instance est une image `liquibase-migrations` de
Database qui contient `repeatable/common/seed_test_accounts.sql` (toute image construite
depuis le changement de Database qui a ajouté les comptes de test). Une image plus ancienne
ignore le paramètre et ne crée aucun compte.

1. Générer un mot de passe (au moins 16 caractères aléatoires) et le ranger dans le coffre de
   l'équipe (Scaleway Secret Manager de l'organisation, entrée `test-accounts-password` de
   l'instance) et dans le secret GitHub que lisent les workflows de campagne. Il n'est jamais
   écrit dans un ticket, une discussion ou ce dépôt.
2. Sur la machine Argo CD du groupe, depuis `/opt/Deploiment`, le sceller avec les autres
   secrets de l'instance (lire la valeur sans l'afficher) :

   ```bash
   read -rs TEST_ACCOUNTS_PASSWORD && export TEST_ACCOUNTS_PASSWORD
   # dev
   KUBECONFIG=/root/.kube/instance-dev.yaml ./scripts/seal-secrets.sh dev mairie360 dev
   # staging (avec le mot de passe de staging, relu)
   KUBECONFIG=/root/.kube/instance-staging.yaml ./scripts/seal-secrets.sh staging mairie360 staging
   ```

   Seul son hash argon2id est scellé (`TEST_ACCOUNTS_PASSWORD` de `<env>-database-secret`).
   Les exécutions suivantes sans la variable le conservent ; `--rotate` aussi.
3. Committer le nouveau `secrets.yaml` par une pull request et merger : dev se synchronise
   seule. Pour staging, promouvoir, puis synchroniser staging à la main.
4. Vérifier : se connecter sur `https://login.<env>.mairie360-eip.fr/` (`dev`, puis
   `staging`) avec `attack.guest@example.invalid`.

Tant que la clé n'est pas scellée, le Job Liquibase indique que les comptes de test ne sont
pas créés et migre normalement.

## Source

| Scénarios | Source |
| --- | --- |
| Légers : reconnaissance, DNS, authentification, contrôle d'accès, scans d'injection | runners hébergés par GitHub (adresse non fixe, plages publiées par GitHub) |
| Lourds : déni de service, scans actifs longs | la machine source jetable de `mairie360/Infra` (racine `attack-source/`) : une instance Scaleway avec une IP flexible réservée, hors du réseau privé de toute instance, créée pour la fenêtre et détruite après |

L'adresse source est écrite dans l'annonce. La machine source se crée avec
`scripts/tf.sh attack-source apply` et se détruit avec `scripts/tf.sh attack-source destroy`
(dépôt Infra, avec l'accord d'un membre de l'équipe comme tout apply) ; son IP réservée est
la sortie `source_ip`.

## Reconnaissance mensuelle

`security/external/recon/` (workflow `external-recon.yaml`, le premier lundi de chaque mois et à
la demande) vérifie ce qu'un attaquant voit du groupe mairie360 (argocd, dev, staging, prod,
n8n) : ports ouverts, sous-domaines des journaux de transparence des certificats, bannières de
version, interfaces d'administration joignables depuis Internet, secrets dans l'historique des
dépôts publics, enregistrements DNS orphelins ou pendants et enregistrements anti-usurpation des
domaines de messagerie. Elle se connecte au plus une fois par seconde et par hôte et n'envoie aucune
charge d'attaque : elle n'a besoin ni de fenêtre ni d'annonce, sa source est le runner hébergé
par GitHub. Tout écart par rapport à `security/external/recon/expected.json` fait échouer
l'exécution ; le rapport (artefact `external-recon` et résumé du job) liste les changements
depuis le mois précédent. Détails : [`security/external/README.md`](../../security/external/README.md).

## Scénarios d'authentification mensuels

`security/external/auth/` (workflow `external-auth.yaml`, le premier lundi de chaque mois et à la
demande, **staging uniquement**) rejoue, à travers l'ingress, les attaques sur l'authentification :
force brute et bourrage d'identifiants, énumération de comptes (même réponse et même temps qu'un
compte existe ou non), contournement du second facteur, détournement de la réinitialisation de mot de
passe (sans lire l'e-mail : les comptes de test sont sans boîte) et forge de jetons (`alg` none /
HS256 / signature falsifiée, rejeu du refresh). Plafonné à cinq requêtes par seconde, sur les comptes
de test `attack.*` qu'il verrouille volontairement : il tourne donc hors démonstration. Les jetons
forgés le sont sans aucune clé. Tout constat fait échouer l'exécution (artefact `external-auth`,
résumé du job) et part au registre des failles. Corriger un constat est un ticket à part. Détails :
[`security/external/README.md`](../../security/external/README.md).

## DNS et usurpation d'e-mail

| Domaine | SPF | DKIM | DMARC |
| --- | --- | --- | --- |
| `mairie360-eip.fr` (boîte de l'équipe chez o2switch, Resend) | o2switch et son relais, `~all` | `default` (o2switch), `resend` | `p=quarantine` |
| `mairie360.fr` (Resend seulement, enveloppe `send.mairie360.fr`) | `v=spf1 -all` | `resend` | `p=quarantine` |

Les deux zones sont dans Scaleway Domains (mairie360/Infra `orgs/mairie360`), qui refuse un
enregistrement DMARC sans politique appliquée ni adresse de rapport. Les rapports agrégés vont à
`dmarc@mairie360.fr` (la boîte de réception Resend). **Cible : `p=reject` sur les deux domaines le
2026-12-28**, une fois qu'un mois de rapports ne montre que Resend et o2switch comme expéditeurs ;
`dmarc_policies` de `expected.json` passe alors à `["reject"]`.

L'expéditeur usurpé est testé pour de vrai chaque mois par `spoof-test.yml` de mairie360/Infra :
une machine jetable du projet d'attaque envoie un e-mail `From: noreply@mairie360-eip.fr` à la
boîte Resend, qui doit le juger `dmarc=fail`. C'est le seul scénario des campagnes qui envoie un
e-mail ; il n'écrit jamais à personne hors du groupe.

## Scénarios de contrôle d'accès mensuels

`security/external/access/` (workflow `external-access.yaml`, le premier lundi de chaque mois et à
la demande, **staging uniquement**) rejoue, à travers les origines des fronts, les attaques de
contrôle d'accès : élévation de privilège (une session Guest appelant le front admin → 403 attendu)
et IDOR (un compte de test crée une ressource, un autre tente de la lire, la modifier ou la
supprimer → 403/404 attendu, aucune donnée du premier). Les matrices d'accès par API sont la source
des autorisations attendues ; les chemins des fronts sont remodelés par les BFFs, donc les scénarios
utilisent les chemins CRUD propres des fronts (la complétude des matrices reste vérifiée par
`access_matrix.rs` côté API). Plafonné à cinq requêtes par seconde, sur les comptes de test
`attack.*`. Tout constat fait échouer l'exécution (artefact `external-access`) et part au registre
des failles. Compliance_API n'a pas encore de matrice (ticket de suivi). Détails :
[`security/external/README.md`](../../security/external/README.md).

## DAST actif (manuel, fenêtre annoncée)

`security/external/dast/` (workflow `external-dast.yaml`, **`workflow_dispatch` seulement**, staging)
est le scan actif : il envoie de vraies charges d'injection et écrit sur staging, donc il se lance à
la main pendant une fenêtre annoncée, 10 requêtes par seconde, 5 threads. Il pilote ZAP (scan actif,
couverture OpenAPI à travers l'ingress avec le hook `CICD/tests/zap`, une session par rôle), sqlmap
sur les paramètres de filtre/tri, testssl.sh par front, et les contrôles HTTP de `dast.py` (en-têtes,
drapeaux du cookie de session, redirection ouverte, traversée de chemin, SSRF). `dast.py` agrège le
rapport de chaque outil dans un même verdict : une alerte Élevée fait échouer l'exécution, une
Moyenne est un constat au registre. Le rapport du premier passage est joint au ticket. Détails :
[`security/external/README.md`](../../security/external/README.md).

## Logique métier et abus sans session (manuel, fenêtre annoncée)

`security/external/business/` (workflow `external-business.yaml`, **`workflow_dispatch` seulement**,
staging) rejoue les failles de logique que les scanners manquent et les abus sans session : des
séquences par module (une étape sautée, une action rejouée, une action sur un élément supprimé ou
archivé, des dates incohérentes — chacune doit être refusée côté serveur même front contourné), une
boucle forgot-password bornée par compte et par IP (un plafond 429 doit apparaître, Resend ne doit pas
devenir un envoyeur de masse) et l'alerte « activité inhabituelle » martelée. Il se lance à la main
pendant une fenêtre annoncée (le bloc e-mail déclenche de vrais envois Resend), 5 requêtes par
seconde ; les boucles s'arrêtent au premier plafond et sont bornées. La future partie publique (spam
de formulaires, dépôt illicite) a un gabarit vide, `scenarios/public.json.template`. Tout constat fait
échouer l'exécution. Détails : [`security/external/README.md`](../../security/external/README.md).

## Déni de service applicatif (machine source, pas de CI)

`security/external/dos/` mesure à partir de quelle charge hostile staging cesse de servir les agents
légitimes et s'il se rétablit seul. Il **tourne depuis la machine source jetable** (`run.sh`), **jamais
depuis un runner GitHub**, dans la sous-fenêtre de déni de service, par paliers, arrêté au premier
seuil de rupture ; la machine Argo CD capture les instantanés cluster (`snapshot.sh`). k6 joue la
rafale HTTP (avec un agent légitime en parallèle), slowhttptest les connexions lentes, et des
générateurs l'épuisement de ressources (corps géant, JSON imbriqué, pagination sans borne, uploads,
WebSocket en masse). `dos.py` agrège les résumés k6, les instantanés kubectl et la sonde de
rétablissement et vérifie : 429/413 et non 5xx/timeouts, aucun pod redémarré, mémoire sous la limite
de chaque pod, latence p95 de l'agent légitime sous le seuil, rétablissement dans la fenêtre. Tout
seuil non tenu est un constat. Pas de workflow GitHub (seuls les tests de l'agrégateur tournent en
CI). Détails : [`security/external/README.md`](../../security/external/README.md).

## Fenêtre et annonce

- Annoncée dans le canal de l'équipe **au moins 24 heures avant** : début et fin (date et
  heure, Europe/Paris), familles d'attaque jouées, adresse source, commit de staging, qui la
  mène.
- Les fenêtres sont en semaine, de 9 h à 18 h, jamais pendant une démonstration, un suivi
  avec les mentors ou une mise en prod.
- La personne qui mène la campagne reste au clavier pendant toute la fenêtre.

## Débits plafonnés

| Famille | Plafond |
| --- | --- |
| Reconnaissance, DNS et e-mail | 1 requête par seconde et par hôte, ports scannés une fois par fenêtre |
| Authentification, sessions, contrôle d'accès, logique métier | 5 requêtes par seconde |
| Scans actifs d'injection (ZAP) | 10 requêtes par seconde, 5 threads au plus |
| Déni de service applicatif | sa propre sous-fenêtre dans la campagne, montée par paliers, arrêt au premier seuil de rupture (scénarios de cette famille) |

Le déni de service volumétrique réseau n'est pas simulé : il relève de la protection de
l'hébergeur.

## Critères d'arrêt

Arrêter immédiatement tous les scénarios, puis prévenir l'équipe, quand :

1. un autre environnement (dev, prod, une instance cliente, une machine Argo CD) reçoit du
   trafic de la campagne ou se dégrade pendant la fenêtre ;
2. staging reste indisponible plus de 15 minutes après l'arrêt des scénarios ;
3. les scénarios atteignent des données qui ne sont pas des données de test (usager réel,
   document réel) ;
4. un secret ou un identifiant est obtenu : arrêter, écrire le constat, le faire changer avant
   de reprendre ;
5. Scaleway envoie un signalement d'abus ou bloque l'adresse source ;
6. la fin de la fenêtre est atteinte.

## Qui prévenir

- Avant : l'équipe, par l'annonce.
- Pendant, quand un critère d'arrêt est atteint : le canal de l'équipe, puis la personne qui
  peut revenir en arrière ou resynchroniser staging.
- Après : le rapport de campagne (un par famille) et chaque constat au registre des failles,
  avec sa sévérité et son ticket MAIR.

## Accord de l'hébergeur (Scaleway)

Scaleway ne publie aucune politique client sur les tests d'intrusion ou de charge (vérifié le
2026-11-26). Avant la première campagne, une demande écrite part au support Scaleway : la
campagne ci-dessus, sa source, ses plafonds, et une confirmation de la protection anti-DDoS de
chaque machine (contrôle E-05). Sa réponse est archivée sur le ticket Jira du cadre de
campagne et résumée ici.

| Date | Demande | Réponse |
| --- | --- | --- |
| — | à envoyer | — |
