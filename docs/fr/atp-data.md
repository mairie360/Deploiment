# Runbook des données du cahier de recette

Comment créer, vérifier et supprimer les données que le cahier de recette (ATP, fichier
`ATP_Mairie360`, onglet « Info & Access ») attend sur l'instance où il est joué : les quatre
comptes fournis et une courte formation de démonstration. Aucun déploiement ne les crée :
un administrateur les crée à la main, avec les étapes ci-dessous. Version anglaise :
[`docs/en/atp-data.md`](../en/atp-data.md).

Tout le reste de l'ATP (groupes de service, projets, tâches, événements, conversations, le
compte Responsable personnel du testeur) est créé par l'ATP elle-même : ne pas le préparer.

**Aucun mot de passe n'est écrit dans ce fichier, dans un ticket ou dans une discussion.** Les
quatre mots de passe sont ceux de la fiche ATP, rangés dans le gestionnaire de mots de passe de
l'équipe. Les taper dans les écrans, ou les lire dans des variables du shell avec `read -s`
comme ci-dessous.

## Ce qui est créé

| Compte ATP | E-mail | Prénom / nom | Rôle (`roles.name`) |
| --- | --- | --- | --- |
| Employé | `employe@mairie360.fr` | Camille Durand | `User` |
| Responsable | `responsable@mairie360.fr` | Julien Moreau | `Responsable` |
| Maire | `maire@mairie360.fr` | Isabelle Lefèvre | `Maire` |
| Administrateur | `admin@mairie360.fr` | `Administrateur` (renommé) / `User` | `Admin`, le compte semé `id = 1` |

Les prénoms et noms sont fictifs et ne doivent pas figurer dans les mots de passe de la fiche
(la politique de mot de passe refuse un mot de passe qui contient le prénom ou le nom du compte).
L'Administrateur existe déjà : Liquibase le sème à partir du `ADMIN_EMAIL` de l'instance avec le
prénom `Admin`, que son mot de passe de la fiche contient ; il est donc renommé d'abord.

Formation « Prise en main de Mairie 360 » : origine `platform` (fournie avec l'outil), niveau
`beginner`, non obligatoire, trois modules courts, chacun avec un lien public et un court contenu
`other`, sans quiz. L'Employé, le Responsable et le Maire y sont inscrits : le catalogue d'un
agent ne liste que les formations où il est inscrit.

## Prérequis

1. **La version que l'ATP teste est déployée sur l'instance** : la Core API qui accepte un mot de
   passe contenant la partie locale de l'e-mail, l'API et le schéma e-learning qui connaissent
   l'origine d'une formation (`courses.source`), et les fronts.
2. **Les identifiants de l'administrateur** : le compte `ADMIN_EMAIL` de l'instance et son mot de
   passe actuel, dans le gestionnaire de mots de passe de l'équipe (le premier mot de passe est
   généré par `scripts/seal-secrets.sh` et rangé là), et son second facteur s'il en a un
   (application d'authentification ou code de secours).
3. **`ADMIN_EMAIL` vaut `admin@mairie360.fr`.** Le vérifier en se connectant sur
   `https://login.<domain>/` avec `admin@mairie360.fr` et le mot de passe administrateur actuel.
   Si l'administrateur a une autre adresse, deux choses, faites par la personne qui a les droits
   de scellement de l'instance :
   - changer l'adresse du compte 1 en `admin@mairie360.fr` (Administration → Utilisateurs →
     l'administrateur → « Adresse e-mail », ou `PATCH /api/v1/admin/users/1/ {"email": …}`).
     Re-sceller seul ne change rien sur une instance en service : le semis Liquibase de
     l'administrateur n'écrit le compte 1 que tant qu'il porte les identifiants du modèle ;
   - re-sceller `ADMIN_EMAIL` pour que le Secret corresponde au compte
     (`ADMIN_EMAIL=admin@mairie360.fr` `./scripts/seal-secrets.sh <env> mairie360 <env>` sur la
     machine Argo CD du groupe, voir l'en-tête de `clusters/mairie360/instances/<env>/secrets.yaml`),
     committer le nouveau `secrets.yaml` par une pull request et le promouvoir comme tout
     changement.

   Ne jamais déchiffrer la valeur scellée pour la vérifier.
4. **Les quatre boîtes `@mairie360.fr` sont accessibles à l'équipe** : la création d'un compte
   lui envoie un e-mail d'invitation, et l'ATP vérifie l'e-mail de récupération du mot de passe
   (F5).

## Étapes dans les écrans (à privilégier)

Se connecter sur `https://admin.<domain>/` en administrateur.

1. **Renommer l'administrateur.** Utilisateurs → la ligne de l'administrateur → modifier : prénom
   `Administrateur` (ou un vrai nom de l'équipe que le mot de passe de la fiche ne contient pas),
   Enregistrer. Puis « Réinitialiser le mot de passe » du même compte : le mot de passe
   Administrateur de la fiche, deux fois. Se déconnecter et se reconnecter avec.
2. **Créer les trois comptes.** Pour chaque ligne du tableau : Utilisateurs → « Nouvel
   utilisateur », prénom, nom, e-mail, un mot de passe temporaire de votre choix (12 caractères
   au moins, il est remplacé à l'étape suivante), Créer. Ouvrir le nouveau compte, choisir son
   « Rôle » (`User`, `Responsable` ou `Maire`), Enregistrer.
3. **Poser les mots de passe définitifs.** Sur chacun des trois comptes, « Réinitialiser le mot
   de passe » avec le mot de passe de la fiche pour ce compte. Une réinitialisation par un
   administrateur supprime l'étape de première connexion : les testeurs se connectent
   directement. L'e-mail d'invitation envoyé à l'étape 2 reste valable 7 jours ; l'ignorer.
4. **Créer la formation.** Les écrans e-learning ne créent une formation qu'avec l'origine
   `internal` : la créer avec l'appel d'API de la section suivante (étape 4) pour qu'elle porte
   l'origine `platform`. Si l'API est hors d'atteinte, la créer depuis
   `https://elearning.<domain>/` → « Nouvelle formation » avec le contenu ci-dessous ; elle
   apparaît alors sous l'origine « interne », ce que l'ATP ne vérifie pas.
5. **Inscrire les apprenants.** `https://elearning.<domain>/` → la formation → « Agents
   inscrits » → « Inscrire des agents » : Camille Durand, Julien Moreau, Isabelle Lefèvre.

## Les mêmes étapes par l'API (secours, et la formation)

Les API ne sont pas exposées sur internet : les joindre depuis la machine de l'instance par une
redirection de port (l'accès SSH est décrit dans le dépôt `ansible`).

```bash
ssh -L 3000:127.0.0.1:13000 -L 3006:127.0.0.1:13006 ubuntu@<instance-ip>
# sur la machine, dans cette session :
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo -E kubectl -n mairie360-<env> get svc | grep -E 'core-api|elearning-api'
sudo -E kubectl -n mairie360-<env> port-forward svc/<core-api-service> 13000:<its port> &
sudo -E kubectl -n mairie360-<env> port-forward svc/<elearning-api-service> 13006:<its port> &
```

Sur votre machine (`curl` et `jq`), avec `CORE=http://localhost:3000` et
`ELEARNING=http://localhost:3006` :

```bash
read -rs -p 'Mot de passe administrateur : ' ADMIN_PW; echo
JWT=$(curl -sS -D - -o /dev/null -X POST "$CORE/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e admin@mairie360.fr --arg p "$ADMIN_PW" '{email:$e,password:$p,device_info:"atp-runbook"}')" \
  | sed -n 's/^[Aa]uthorization: Bearer \(.*\)\r$/\1/p')
```

Un `JWT` vide veut dire que la connexion n'a pas répondu `200` : un `202` demande le second
facteur (`POST /api/v1/auth/login/2fa` avec son `token` et un code, le JWT est dans l'en-tête
`Authorization` de cette réponse), un `412` veut dire que l'administrateur n'a jamais choisi son
propre mot de passe (se connecter une fois dans les écrans d'abord).

```bash
AUTH="Authorization: Bearer $JWT"
JSON='Content-Type: application/json'

# 1. Renommer l'administrateur (compte 1), puis poser son mot de passe de la fiche.
curl -sS -X PATCH "$CORE/api/v1/admin/users/1/" -H "$AUTH" -H "$JSON" -d '{"first_name":"Administrateur"}'
curl -sS -X PATCH "$CORE/api/v1/admin/users/1/password" -H "$AUTH" -H "$JSON" \
  -d "$(jq -n --arg p "$ADMIN_PW" '{new_password:$p}')"   # 204 ; se reconnecter pour un nouveau JWT

# Identifiants des rôles de l'instance.
curl -sS "$CORE/api/v1/admin/roles/" -H "$AUTH" | jq '.[] | {id, name}'

# 2 et 3. Un compte : création (mot de passe temporaire), rôle, mot de passe définitif.
create_account() { # <email> <first name> <last name> <role id>
  local pw tmp id
  read -rs -p "Mot de passe de la fiche pour $1 : " pw; echo
  tmp="$(openssl rand -base64 24)"
  id=$(curl -sS -X POST "$CORE/api/v1/admin/users/" -H "$AUTH" -H "$JSON" \
    -d "$(jq -n --arg e "$1" --arg f "$2" --arg l "$3" --arg p "$tmp" '{email:$e,first_name:$f,last_name:$l,password:$p}')" | jq -r .id)
  curl -sS -X POST "$CORE/api/v1/admin/users/$id/roles/" -H "$AUTH" -H "$JSON" -d "{\"role_id\":$4}"
  curl -sS -o /dev/null -w '%{http_code}\n' -X PATCH "$CORE/api/v1/admin/users/$id/password" -H "$AUTH" -H "$JSON" \
    -d "$(jq -n --arg p "$pw" '{new_password:$p}')"
  echo "$1 -> account $id"
}
create_account employe@mairie360.fr Camille Durand <id de User>
create_account responsable@mairie360.fr Julien Moreau <id de Responsable>
create_account maire@mairie360.fr Isabelle 'Lefèvre' <id de Maire>
```

Un `409` à la création veut dire que l'adresse est déjà prise (compte gardé d'un passage
précédent, ou archivé) : voir « Rejouer » plus bas. La réinitialisation du mot de passe répond
`204` ; un `400` nomme la règle que le mot de passe enfreint.

```bash
# 4. La formation.
COURSE=$(curl -sS -X POST "$ELEARNING/api/v1/admin/formations/" -H "$AUTH" -H "$JSON" -d @- <<'EOF' | jq -r .id
{
  "name": "Prise en main de Mairie 360",
  "description": "Une courte découverte de l'outil : ses modules, leur usage au quotidien et les bons réflexes avec les données des administrés.",
  "category": "Prise en main",
  "level": "beginner",
  "is_mandatory": false,
  "source": "platform",
  "instructor": "Équipe Mairie 360",
  "modules": [
    {
      "name": "Découvrir Mairie 360",
      "description": "À quoi sert l'outil et comment s'y connecter.",
      "files": [
        { "title": "Le service public numérique", "file_type": "link", "url": "https://www.numerique.gouv.fr/", "duration_seconds": 180 },
        { "title": "En résumé : se connecter et naviguer", "file_type": "other", "description": "Connectez-vous depuis la page de connexion, puis passez d'un module à l'autre avec le menu de gauche.", "duration_seconds": 120 }
      ]
    },
    {
      "name": "Les modules de l'outil",
      "description": "Tableau de bord, projets, calendrier, messagerie et formations.",
      "files": [
        { "title": "Travailler en équipe dans une collectivité", "file_type": "link", "url": "https://www.collectivites-locales.gouv.fr/", "duration_seconds": 180 },
        { "title": "En résumé : un module par usage", "file_type": "other", "description": "Les projets suivent les travaux, le calendrier les rendez-vous, la messagerie les échanges entre services.", "duration_seconds": 120 }
      ]
    },
    {
      "name": "Les bons réflexes avec les données",
      "description": "Ce que le RGPD demande à un agent au quotidien.",
      "files": [
        { "title": "Le RGPD pour les collectivités (CNIL)", "file_type": "link", "url": "https://www.cnil.fr/fr/collectivites", "duration_seconds": 240 },
        { "title": "En résumé : ne partager que le nécessaire", "file_type": "other", "description": "Ne transmettez que les données utiles à la démarche, et seulement aux personnes qui en ont besoin.", "duration_seconds": 120 }
      ]
    }
  ]
}
EOF
)
echo "course $COURSE"

# 5. Inscrire les trois apprenants (ids affichés à l'étape 2). Idempotent : un nouveau 200 garde la progression.
for id in <id employé> <id responsable> <id maire>; do
  curl -sS -o /dev/null -w '%{http_code}\n' -X POST "$ELEARNING/api/v1/admin/formations/$COURSE/" -H "$AUTH" -H "$JSON" -d "{\"user_id\":$id}"
done
unset ADMIN_PW JWT AUTH
```

## Liste de vérification

- [ ] Les quatre comptes se connectent sur `https://login.<domain>/` avec leur mot de passe de
      la fiche, sans changement de mot de passe demandé, et chacun a son rôle (Administration →
      Utilisateurs, ou le profil).
- [ ] Connecté en Employé, `https://elearning.<domain>/` liste « Prise en main de Mairie 360 »
      avec ses trois modules ; la formation s'ouvre.
- [ ] En administrateur, le filtre « Origine » → « Formations de l'outil » du catalogue
      e-learning montre la formation (origine `platform`).
- [ ] « Mot de passe oublié » sur `https://login.<domain>/` pour un des comptes : l'e-mail de
      réinitialisation arrive dans sa boîte `@mairie360.fr` (F5). Ne pas aller au bout de la
      réinitialisation, sinon le mot de passe de la fiche ne marche plus ; si c'est fait, reposer
      le mot de passe de la fiche par une réinitialisation administrateur.
- [ ] Ne pas commencer la formation avec un compte de test avant l'ATP : F53 à F55 la jouent
      depuis le début.

## Nettoyage après l'ATP

Seulement quand l'équipe de l'ATP le décide ; sinon ces données ne gênent pas l'instance.

1. **Archiver les trois comptes** : Administration → Utilisateurs → chaque compte → archiver, ou
   `curl -X DELETE "$CORE/api/v1/admin/users/<id>/" -H "$AUTH"`. Les sessions se terminent, le
   compte garde son historique.
2. **Supprimer la formation** : depuis sa carte dans le catalogue e-learning, ou
   `curl -X DELETE "$ELEARNING/api/v1/admin/formations/$COURSE/" -H "$AUTH"`.
3. **Rendre son prénom à l'administrateur** si l'équipe le souhaite (`Admin`, ou un vrai nom),
   et changer son mot de passe pour un autre que celui de la fiche : la fiche est partagée avec
   les testeurs.

Les données créées par l'ATP elle-même (groupes, projets, événements, conversations, le compte
Responsable du testeur) se suppriment de la même façon si besoin, par l'équipe de l'ATP.

## Rejouer

Les étapes se rejouent sans risque : l'inscription est idempotente, une réinitialisation de mot
de passe peut se répéter, et un compte ou une formation qui existe déjà est gardé (`409` à la
création d'un compte : retrouver le compte dans Administration → Utilisateurs et ne refaire que
son rôle et son mot de passe). Un compte archivé garde son adresse : pour le recréer, soit le
restaurer en base (`restore_user`), soit l'effacer d'abord
(`POST /api/v1/admin/users/<id>/erase`, définitif) puis le créer à nouveau.
