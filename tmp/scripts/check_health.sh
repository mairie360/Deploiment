#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

NAMESPACE="dev"

echo -e "${BLUE}--- Vérification de l'état du cluster ---${NC}"

# 1. État global
kubectl get pods -n $NAMESPACE

# 2. Test Database
echo -e "\n2. Test de connexion Database..."
# On cherche un pod qui contient "database" dans son nom
DB_POD=$(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "database" | head -n 1)

if [ -z "$DB_POD" ]; then
    echo -e "${RED}❌ Pod Database introuvable.${NC}"
else
    # On teste si postgres répond
    if kubectl exec -n $NAMESPACE $DB_POD -- pg_isready -U postgres > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Database prête (pg_isready OK).${NC}"
    else
        echo -e "${RED}❌ Database ne répond pas encore.${NC}"
    fi
fi

# 3. Test Redis
echo -e "\n3. Test de connexion Redis..."
REDIS_POD=$(kubectl get pods -n $NAMESPACE --no-headers -o custom-columns=":metadata.name" | grep "redis" | head -n 1)

if [ -z "$REDIS_POD" ]; then
    echo -e "${RED}❌ Pod Redis introuvable.${NC}"
else
    # On teste avec redis-cli (sans mot de passe d'abord pour vérifier la présence)
    if kubectl exec -n $NAMESPACE $REDIS_POD -- redis-cli ping > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Redis répond (PONG).${NC}"
    else
        echo -e "${RED}❌ Redis ne répond pas (vérifie le mot de passe ou le port).${NC}"
    fi
fi

# 4. Liquibase
echo -e "\n4. État Liquibase..."
if kubectl get jobs -n $NAMESPACE | grep -q "1/1"; then
    echo -e "${GREEN}✅ Migration réussie.${NC}"
else
    echo -e "${RED}❌ Migration en cours ou échouée.${NC}"
fi
