#!/bin/bash
# =============================================================================
# setup-network.sh - Configuration réseau pour accès depuis l'hôte Windows
#
# Problème : Minikube en driver Docker crée son propre réseau bridge interne
# (192.168.49.0/24) invisible depuis Windows.
#
# Solution : règles iptables qui redirigent le trafic entrant sur l'interface
# host-only (192.168.56.100) vers le NodePort minikube (192.168.49.2:30080)
#
# Schéma :
#   Windows → 192.168.56.100:30080
#                    ↓ DNAT iptables
#             192.168.49.2:30080 (minikube NodePort)
#                    ↓
#             paymybuddy pod:8080
#
# Usage : bash setup-network.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..] $1${NC}"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

VM_IP="192.168.56.100"       # IP host-only de la VM Vagrant (enp0s8)
MINIKUBE_IP="192.168.49.2"   # IP du node minikube (driver Docker)
MINIKUBE_NET="192.168.49.0/24"
APP_PORT="30080"              # NodePort de PayMyBuddy

# =============================================================================
# ÉTAPE 1 — Active le forwarding IP
# Sans ça, la VM ne route pas les paquets entre ses interfaces
# =============================================================================
info "=== Activation du forwarding IP ==="
sudo sysctl -w net.ipv4.ip_forward=1
log "ip_forward activé"

# =============================================================================
# ÉTAPE 2 — Règle DNAT
# Redirige le trafic entrant sur VM_IP:APP_PORT vers MINIKUBE_IP:APP_PORT
# → PREROUTING = appliqué avant que le paquet soit routé
# =============================================================================
info "=== Ajout règle DNAT ==="

# Vérifie si la règle existe déjà pour éviter les doublons
if sudo iptables -t nat -C PREROUTING \
  -d $VM_IP -p tcp --dport $APP_PORT \
  -j DNAT --to-destination $MINIKUBE_IP:$APP_PORT 2>/dev/null; then
  log "Règle DNAT déjà présente → skip"
else
  sudo iptables -t nat -A PREROUTING \
    -d $VM_IP -p tcp --dport $APP_PORT \
    -j DNAT --to-destination $MINIKUBE_IP:$APP_PORT
  log "Règle DNAT ajoutée : $VM_IP:$APP_PORT → $MINIKUBE_IP:$APP_PORT"
fi

# =============================================================================
# ÉTAPE 3 — Règle MASQUERADE
# Masque l'IP source pour que le pod réponde via la VM
# → sans ça, le pod répondrait directement à Windows qui ne connaît pas
#   192.168.49.x et la connexion serait perdue
# =============================================================================
info "=== Ajout règle MASQUERADE ==="

if sudo iptables -t nat -C POSTROUTING \
  -d $MINIKUBE_IP -p tcp --dport $APP_PORT \
  -j MASQUERADE 2>/dev/null; then
  log "Règle MASQUERADE déjà présente → skip"
else
  sudo iptables -t nat -A POSTROUTING \
    -d $MINIKUBE_IP -p tcp --dport $APP_PORT \
    -j MASQUERADE
  log "Règle MASQUERADE ajoutée"
fi

# =============================================================================
# ÉTAPE 4 — Règle FORWARD
# Autorise le transit des paquets vers le réseau minikube
# → la chaîne FORWARD a une policy DROP par défaut sur cette VM
# =============================================================================
info "=== Ajout règle FORWARD ==="

if sudo iptables -C FORWARD -d $MINIKUBE_NET -j ACCEPT 2>/dev/null; then
  log "Règle FORWARD déjà présente → skip"
else
  sudo iptables -I FORWARD -d $MINIKUBE_NET -j ACCEPT
  sudo iptables -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log "Règles FORWARD ajoutées"
fi

# =============================================================================
# ÉTAPE 5 — Test de connectivité depuis la VM
# =============================================================================
info "=== Test de connectivité ==="
sleep 2

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 http://$MINIKUBE_IP:$APP_PORT || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  log "Application répond → HTTP $HTTP_CODE ✅"
else
  err "Application ne répond pas (HTTP $HTTP_CODE)
  → Vérifie que les pods sont Running :
    kubectl get pods -n paymybuddy"
fi

# =============================================================================
# RÉCAP
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN}     RÉSEAU CONFIGURÉ !${NC}"
echo "=============================================="
echo ""
echo "📋 Règles iptables actives :"
sudo iptables -t nat -L -n | grep -E "$MINIKUBE_IP|$VM_IP"
echo ""
echo "🔗 Accès depuis l'hôte Windows :"
echo "   http://$VM_IP:$APP_PORT"
echo ""
echo "⚠️  Ces règles sont temporaires (perdues au reboot)"
echo "   Pour les rendre persistantes :"
echo "   sudo iptables-save > /etc/iptables/rules.v4"
