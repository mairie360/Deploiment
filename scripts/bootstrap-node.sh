#!/usr/bin/env bash
# =============================================================================
# Transforme un serveur Ubuntu 24.04 vierge en nœud k3s prêt à l'emploi.
#
#   sudo ./scripts/bootstrap-node.sh
#
# Identique pour une machine Argo CD et pour une machine d'instance : ce script
# ne fait QUE le socle système + k3s. Ce qui tourne dessus ensuite est décidé
# par Ansible (rôles k8s_argocd / k8s_instance_link du dépôt `ansible`).
#
# En production, ce script n'est PAS lancé à la main : le rôle Ansible k8s_node
# fait la même chose de façon idempotente et sur toutes les machines à la fois.
# Il reste utile pour dépanner ou préparer une machine isolée.
#
# Ce que fait ce script :
#   1. Durcissement de base (pare-feu, mises à jour auto, swap off)
#   2. Installation de k3s SANS Traefik (le chart argo-cd et les Ingress du
#      dépôt supposent un contrôleur choisi explicitement, pas Traefik par
#      défaut) mais AVEC ServiceLB (indispensable sur un nœud unique pour
#      qu'un Service LoadBalancer se lie aux ports 80/443 de la machine).
#
# Idempotent : peut être relancé sans casser un nœud déjà installé.
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Lancer avec sudo."; exit 1; }

echo "== 1/4 — Système =="
apt-get update -qq
apt-get install -y -qq curl wget jq ufw fail2ban chrony unattended-upgrades >/dev/null
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "== 2/4 — Pare-feu (80/443 publics, reste fermé) =="
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp    comment 'SSH' >/dev/null
ufw allow 80/tcp    comment 'HTTP' >/dev/null
ufw allow 443/tcp   comment 'HTTPS' >/dev/null
# Indispensable : sans ça, UFW casse le réseau interne des pods (CoreDNS en
# CrashLoop, services injoignables entre eux).
ufw allow from 10.42.0.0/16 comment 'k3s pods' >/dev/null
ufw allow from 10.43.0.0/16 comment 'k3s services' >/dev/null
ufw route allow in on cni0 >/dev/null 2>&1 || true
ufw --force enable >/dev/null

echo "== 3/4 — fail2ban (SSH) =="
cat > /etc/fail2ban/jail.local << 'JAIL'
[sshd]
enabled  = true
maxretry = 3
bantime  = 3600
JAIL
systemctl enable --now fail2ban >/dev/null

echo "== 4/4 — k3s =="
if ! command -v k3s >/dev/null 2>&1; then
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/config.yaml << CFG
write-kubeconfig-mode: "0644"
disable:
  - traefik
CFG
  curl -sfL https://get.k3s.io | sh -
else
  echo "k3s déjà installé, on passe."
fi

echo "Attente du nœud..."
until k3s kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 2; done

echo
echo "Nœud prêt."
echo "Kubeconfig local : /etc/rancher/k3s/k3s.yaml"
echo "Pour piloter depuis ton poste :"
echo "  scp \$(whoami)@<ip-de-ce-serveur>:/etc/rancher/k3s/k3s.yaml ./kubeconfig"
echo "  sed -i 's/127.0.0.1/<ip-de-ce-serveur>/' ./kubeconfig"
echo "  export KUBECONFIG=\$PWD/kubeconfig"
