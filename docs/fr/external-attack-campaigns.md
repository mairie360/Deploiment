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

1. Générer un mot de passe (au moins 16 caractères aléatoires) et le ranger dans le coffre de
   l'équipe (Scaleway Secret Manager de l'organisation, entrée `test-accounts-password` de
   l'instance) et dans le secret GitHub que lisent les workflows de campagne. Il n'est jamais
   écrit dans un ticket, une discussion ou ce dépôt.
2. Sur la machine Argo CD du groupe, depuis `/opt/Deploiment`, le sceller avec les autres
   secrets de l'instance (lire la valeur sans l'afficher) :

   ```bash
   read -rs TEST_ACCOUNTS_PASSWORD && export TEST_ACCOUNTS_PASSWORD
   KUBECONFIG=/root/.kube/instance-staging.yaml ./scripts/seal-secrets.sh staging mairie360 staging
   ```

   Seul son hash argon2id est scellé (`TEST_ACCOUNTS_PASSWORD` de `<env>-database-secret`).
   Les exécutions suivantes sans la variable le conservent ; `--rotate` aussi.
3. Committer le nouveau `secrets.yaml` par une pull request, merger, promouvoir en staging,
   synchroniser staging.
4. Vérifier : se connecter sur `https://login.staging.mairie360-eip.fr/` avec
   `attack.guest@example.invalid`.

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
