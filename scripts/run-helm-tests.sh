#!/bin/bash
set -e

# Liste des environnements et services
NAMESPACES=("dev" "staging" "prod")
SERVICES=("database" "redis")

for ns in "${NAMESPACES[@]}"; do
  echo "=============================="
  echo "🌐 Tests pour l'environnement: $ns"
  echo "=============================="

  for svc in "${SERVICES[@]}"; do
    RELEASE="mairie360-$svc-$ns"
    echo "🧪 Lancement du test Helm pour $RELEASE..."
    helm test $RELEASE -n $ns
    echo "✅ Test terminé pour $RELEASE"
    echo "------------------------------"
  done
done

echo "🎉 Tous les tests Helm Database et Redis terminés."
