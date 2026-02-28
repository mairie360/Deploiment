#!/bin/bash

# Couleurs pour la lisibilité
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}--- Nettoyage complet de l'environnement Kubernetes ---${NC}"

# 1. Suppression du cluster Kind
# Cela supprime les nœuds (conteneurs Docker), les volumes et tout le réseau associé.
if kind get clusters | grep -q "mairie360-cluster"; then
    echo -e "${RED}Suppression du cluster : mairie360-cluster...${NC}"
    kind delete cluster --name mairie360-cluster
else
    echo "Aucun cluster 'mairie360-cluster' n'a été trouvé."
fi

# 2. Nettoyage des processus de port-forwarding
# Si vous aviez des tunnels SSH ou des 'kubectl port-forward' en arrière-plan
echo -e "${YELLOW}Nettoyage des processus port-forward résiduels...${NC}"
pkill -f "kubectl port-forward" || echo "Aucun processus port-forward en cours."

# 3. Nettoyage Docker (Optionnel mais conseillé)
# Supprime les volumes orphelins pour libérer de l'espace disque
echo -e "${YELLOW}Nettoyage des volumes Docker inutilisés...${NC}"
docker volume prune -f

echo -e "${RED}--------------------------------------------------${NC}"
echo -e "${RED}Tout a été supprimé.${NC}"
echo -e "Les binaires (kind, kubectl, docker) sont toujours installés."
echo -e "Pour tout relancer, utilisez : ./scripts/deploy.sh"
echo -e "${RED}--------------------------------------------------${NC}"
