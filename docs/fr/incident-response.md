# Runbook de réponse à une attaque

Que faire quand une vraie attaque touche une instance (dev, staging, prod, la prod d'un client),
dans l'ordre qui fonctionne. C'est le pendant du runbook de reprise après sinistre : celui-là
restaure une machine ou une base perdue, celui-ci arrête une attaque en cours et limite ses dégâts.
Version anglaise : [`docs/en/incident-response.md`](../en/incident-response.md).

Références : les campagnes d'attaque externe et leurs règles d'engagement
([`docs/fr/external-attack-campaigns.md`](external-attack-campaigns.md)), le runbook de reprise après
sinistre ([`disaster-recovery.md`](disaster-recovery.md)), le modèle réseau et la section Cilium /
Hubble de `CLAUDE.md`, et les décisions RGPD de chaque org (`compliance/<org>/`).

## Qui décide

| Rôle | Personne | Fait |
| --- | --- | --- |
| **Responsable d'incident** | **Quentin** | décide, lance les coupures, parle à la mairie, écrit le constat |
| **Suppléant** | **Hugo** (`CarolinHugo`) | prend le rôle de responsable quand Quentin est injoignable |
| Renfort | `LAURETbenjamin`, `MathTek` | surveillent les signaux, exécutent les commandes sous la direction du responsable |

Une seule personne est responsable à la fois. Le responsable peut déléguer une commande mais reste
redevable de la décision de couper. On joint l'équipe sur le canal habituel ; si aucun des deux
responsables ne répond en 15 minutes, la personne présente prend le rôle et note qu'elle l'a pris.

## 1. Reconnaître une attaque

Signaux à regarder, dans l'ordre le plus rapide à lire :

- **Logs ingress / fronts** : un flot de requêtes d'une même adresse, un pic de 4xx/5xx, une route
  bien plus sollicitée que d'habitude. Sur la machine Argo CD (la seule qui atteint l'API de
  l'instance) :
  `kubectl --context <ctx> -n mairie360-<env> logs -l app.kubernetes.io/component=frontend --since=10m | tail`
  et les logs du contrôleur d'ingress dans son namespace (`traefik` ou `ingress-nginx`).
- **Échecs de connexion** : une rafale de 401/429 sur `login.<domaine>` ou beaucoup de comptes de
  forme `attack` ; le limiteur de BFF_user qui répond 429 (par compte et par IP). La campagne
  d'authentification (`security/external/auth/`) ressemble à un pic bénin — vérifier que ce n'est pas
  une exécution planifiée.
- **Charge / redémarrages des pods** : `kubectl --context <ctx> -n mairie360-<env> top pods` et
  `get pods` — mémoire proche de la limite, un pod qui redémarre, un `OOMKilled`. Une tentative de
  déni de service se voit ici (voir `security/external/dos/`).
- **Flux réseau (Hubble)** : `scripts/hubble-flows.sh <ctx> <env>` affiche chaque flux autorisé/refusé
  saut par saut — un saut qui devrait être refusé mais passe, ou une nouvelle destination externe.
- **Cockpit** (métriques / alertes) : les séries `BackupMissed`, `RestoreTooSlow`, mémoire et débit de
  requêtes de l'instance.

Décider le **type** de ce qu'on voit : volumétrique / déni de service, abus d'authentification (force
brute, bourrage d'identifiants), faille applicative exploitée (injection, contrôle d'accès), ou
événement de chaîne de livraison (image piégée, abus de workflow). La coupure à choisir en dépend.

## 2. Couper d'abord, par type

Chaque coupure ci-dessous est une **action d'urgence hors-bande** : sur staging et prod (synchronisés
à la main, voir `CLAUDE.md` « Each environment follows its own branch »), elle tient jusqu'au prochain
sync Argo CD, qui la rétablira ou l'élaguera. Après l'incident, soit on rapatrie le changement dans
git (pour qu'Argo le garde), soit on le lève. Chacune est une commande testée
(`tests/scripts/mair_1194_incident_cuts_test.sh`) ; à essayer à blanc sur staging pendant une fenêtre
de campagne avant d'en avoir besoin pour de vrai.

| Attaque | Coupure | Commande |
| --- | --- | --- |
| Une adresse hostile | la bloquer en bordure | `scripts/incident/block-ip.sh <ip\|cidr> --context <ctx>` (lever : `--remove`) |
| Un front sous abus | fermer cette route | `scripts/incident/close-route.sh <instance-front> --context <ctx> --namespace mairie360-<env>` (rouvrir : `--remove`) |
| Instance entière saturée | maintenance (surface publique coupée) | `scripts/incident/maintenance.sh on --context <ctx> --namespace mairie360-<env>` (lever : `off` puis re-sync Argo CD) |
| Session / jeton compromis | révoquer **toutes** les sessions | `scripts/seal-secrets.sh <ctx> <org> <env> --rotate-signing-key` puis le déploiement en deux commits de `CLAUDE.md` « session signing key » ; tout le monde se reconnecte |
| Un secret fuité | le faire tourner | `scripts/seal-secrets.sh <ctx> <org> <env> --rotate` (ou `--rotate-roles` pour les mots de passe de rôles DB/Redis), sync, redémarrer les pods qui le lisent |
| Une image piégée / non signée | arrêter la promotion, vérifier ce qui tourne | `scripts/check-signed-images.sh` (step 16 de `verify.sh`) dit quel digest en service n'est pas signé ; revenir au dernier tag sûr dans git et sync |

Ordre dans un incident : **arrêter l'hémorragie** (bloquer l'adresse ou fermer la route si l'attaque
est localisée ; maintenance sinon), **puis** contenir (révoquer les sessions / faire tourner un secret
fuité), **puis** enquêter. Ne pas faire tourner un secret avant d'avoir bloqué le chemin par lequel
l'attaquant l'a atteint, sinon il profite de la fenêtre de rotation.

## 3. Prévenir la mairie, et l'horloge RGPD

- **Quand** : prévenir la mairie concernée dès que l'incident est confirmé et qu'on a un premier fait
  à donner (ce qui est coupé, ce qu'on fait). Ne pas attendre l'analyse complète.
- **Qui** : le responsable d'incident, par le contact convenu de cette org (`compliance/<org>/access.yaml`
  liste qui a accès ; le DPO de la mairie est nommé dans son AIPD).
- **Violation de données personnelles** : si des données personnelles ont pu être lues, modifiées,
  exfiltrées ou perdues, l'horloge RGPD de 72 heures démarre au moment où on en prend connaissance.
  Ouvrir la procédure de violation de `compliance/<org>/deadlines.yaml` (`breach-exercise` est
  l'exercice annuel de exactement ça), évaluer si la mairie doit notifier la CNIL et les personnes
  concernées, et consigner la chronologie. Mairie 360 est sous-traitant ; la mairie est responsable de
  traitement et fait la notification — lui donner les faits à temps.

## 4. Traces à conserver

Collecter et garder, hors du cluster, avant tout scale ou élagage :

- les logs ingress / fronts / API de la fenêtre : `kubectl ... logs ... --since=<fenêtre> > incident-<date>-<svc>.log` ;
- les flux Hubble de la fenêtre (`scripts/hubble-flows.sh`) et les graphes Cockpit (capture ou export) ;
- `kubectl ... get events --sort-by=.lastTimestamp` et `get pods -o wide` à l'instant ;
- les commandes de coupure exactes exécutées et quand (garder son historique shell / un court journal) ;
- pour une violation : quelles données, combien de personnes, le chemin d'accès, dans le registre des violations.

Les ranger dans le ticket Jira de l'incident (pièces jointes) et, pour une violation, dans le dossier
de conformité de la mairie. Ne jamais coller un secret ou une donnée personnelle dans le ticket ;
masquer les valeurs.

## 5. Après : boucler

- **Registre des failles** : chaque faiblesse confirmée exploitée par l'attaque devient une entrée du
  registre des vulnérabilités, comme un constat de campagne.
- **Ticket** : ouvrir un ticket Jira par correctif (un par repo touché), sous la bonne epic, selon le
  flux habituel.
- **Test de non-régression** : le correctif embarque un test qui échoue sur l'ancien comportement et
  passe sur le correctif, sur la couche qui l'a observé (règle du `CLAUDE.md` racine) — pour que la
  même attaque ne puisse pas réussir deux fois en silence.
- **Lever les coupures d'urgence** : retirer les policies `incident-*` et le scale de maintenance (ou
  les rapatrier dans git s'ils doivent rester), et re-synchroniser Argo CD pour que l'instance
  corresponde de nouveau à git.
- **Mettre à jour ce runbook** : si une coupure manquait ou si un signal a été long à lire, l'ajouter ici.

## Exercice à blanc

Un essai à blanc de ce runbook est joué pendant la première campagne d'attaque externe :
sur staging, en fenêtre, exécuter chaque commande de coupure et son inverse, chronométrer la
détection, et noter ce qu'il faut améliorer. L'exercice annuel de violation de données personnelles
(`compliance/<org>/deadlines.yaml`, `breach-exercise`) répète la section 3.
