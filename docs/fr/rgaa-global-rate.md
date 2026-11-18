# Taux RGAA de la plateforme

La promotion en prod de ce dépôt vérifie l'accessibilité de toute la plateforme.

## D'où viennent les chiffres

Chaque front est testé selon le RGAA lors de sa promotion en prod (mairie360/CICD, porte `rgaa`).
Sa release GitHub porte le résultat dans l'asset `rgaa-report.json`.

## Taux global

`scripts/rgaa-global.py` lit le rapport de chaque front épinglé dans `clusters/_base/prod.yaml` :

- un critère est **non respecté** par la plateforme dès qu'un front l'échoue ;
- il est **respecté** quand tous les fronts qui le déclarent le passent ;
- sinon il demande encore une vérification humaine et n'est pas compté.

Taux = respectés / (respectés + non respectés), arrondi à l'inférieur. Seuls les critères décidés
automatiquement comptent : ce n'est pas un audit.

## Porte de la prod

Le job `rgaa-global` de `Promote` (cible prod) liste les critères en échec avec leur front, leurs
pages et leurs éléments dans le résumé du job, et arrête la promotion sous 50 %. Un front publié
sans rapport est listé et exclu du taux.

## Note de release

Une fois la release en prod, lancer le workflow `Release note` avec la version de
`releases/<version>.yaml`. Il publie, comme release GitHub `platform-v<version>`, une note en
français pour les communes : taux, statut légal (totalement conforme à 100 %, partiellement à
partir de 50 %, non conforme en dessous), critères en échec et fronts non mesurés. Le script
vérifie que la note est elle-même accessible avant de la publier.

Les corrections des fronts sont suivies avec un ticket par correction.
