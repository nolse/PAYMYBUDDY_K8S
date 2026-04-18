#!/bin/bash
# =============================================================================
# setup-network.sh - Configuration réseau pour accès depuis l'hôte Windows
#
# Problème : Minikube en driver Docker crée son propre réseau bridge interne
# invisible depuis Windows (réseau 192.168.49.x ou 192.168.58.x selon la session).
#
# Solution : règles iptables qui redirigent le trafic entrant sur l'interface
# host-only de la VM Vagrant vers le NodePort Minikube, détecté dynamiquement.
#
# Schéma :
#   Windows → 192.168.56.100:30080
#                    ↓ DNAT iptables
#             <minikube ip>:30080  (NodePort PayMyBuddy)
#                    ↓
#             paymybuddy pod:8080
#
# Usage :
#   bash setup-network.sh          → configure les règles iptables
#   bash setup-network.sh clean    → supprime toutes les règles du projet
#   bash setup-network.sh help     → affiche cette aide
#
# Notes :
#   - Les règles iptables sont perdues au reboot de la VM
#   - Relancer ce script à chaque nouvelle session Minikube
#   - L'IP Minikube peut changer entre sessions → détection automatique
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..] === $1 ===${NC}"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
title(){ echo -e "${CYAN}$1${NC}"; }

# =============================================================================
# VARIABLES
# IP host-only fixe de la VM Vagrant (interface enp0s8 / VirtualBox)
# IP Minikube détectée dynamiquement → change entre sessions Docker
# Le réseau Minikube est dérivé de l'IP pour construire la règle FORWARD
# =============================================================================
VM_IP="192.168.56.100"
MINIKUBE_IP=$(minikube ip 2>/dev/null) \
  || err "Impossible de récupérer l'IP Minikube → Minikube est-il démarré ?"
MINIKUBE_NET="$(echo $MINIKUBE_IP | cut -d. -f1-3).0/24"
APP_PORT="30080"

# =============================================================================
# OPTION CLEAN — Supprime toutes les règles iptables ajoutées par ce script
# Utile avant un redémarrage de Minikube ou pour repartir d'un état propre
# =============================================================================
clean() {
  title "\n=============================="
  title "  NETTOYAGE DES RÈGLES IPTABLES"
  title "==============================\n"

  info "Suppression règle DNAT"
  if sudo iptables -t nat -C PREROUTING \
    -d $VM_IP -p tcp --dport $APP_PORT \
    -j DNAT --to-destination $MINIKUBE_IP:$APP_PORT 2>/dev/null; then
    sudo iptables -t nat -D PREROUTING \
      -d $VM_IP -p tcp --dport $APP_PORT \
      -j DNAT --to-destination $MINIKUBE_IP:$APP_PORT
    log "Règle DNAT supprimée"
  else
    log "Règle DNAT absente → skip"
  fi

  info "Suppression règle MASQUERADE"
  if sudo iptables -t nat -C POSTROUTING \
    -d $MINIKUBE_IP -p tcp --dport $APP_PORT \
    -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -D POSTROUTING \
      -d $MINIKUBE_IP -p tcp --dport $APP_PORT \
      -j MASQUERADE
    log "Règle MASQUERADE supprimée"
  else
    log "Règle MASQUERADE absente → skip"
  fi

  info "Suppression règle FORWARD réseau Minikube"
  if sudo iptables -C FORWARD -d $MINIKUBE_NET -j ACCEPT 2>/dev/null; then
    sudo iptables -D FORWARD -d $MINIKUBE_NET -j ACCEPT
    log "Règle FORWARD supprimée"
  else
    log "Règle FORWARD absente → skip"
  fi

  info "Suppression règle FORWARD RELATED,ESTABLISHED"
  if sudo iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    log "Règle FORWARD conntrack supprimée"
  else
    log "Règle FORWARD conntrack absente → skip"
  fi

  echo ""
  log "Nettoyage terminé — toutes les règles du projet ont été supprimées"
  show_help
  exit 0
}

# =============================================================================
# OPTION HELP — Affiche les commandes disponibles
# =============================================================================
show_help() {
  echo ""
  title "=============================================="
  title "     COMMANDES DISPONIBLES"
  title "=============================================="
  echo ""
  echo "  bash setup-network.sh          → Configure les règles iptables"
  echo "  bash setup-network.sh clean    → Supprime toutes les règles du projet"
  echo "  bash setup-network.sh help     → Affiche cette aide"
  echo ""
  echo "  Variables :"
  echo "    VM_IP       = $VM_IP   (IP host-only Vagrant)"
  echo "    MINIKUBE_IP = $MINIKUBE_IP        (IP Minikube — détectée dynamiquement)"
  echo "    MINIKUBE_NET= $MINIKUBE_NET     (réseau Minikube)"
  echo "    APP_PORT    = $APP_PORT                 (NodePort PayMyBuddy)"
  echo ""
  echo "  ⚠️  Les règles iptables sont perdues au reboot de la VM"
  echo "     Relancer ce script à chaque nouvelle session Minikube"
  echo ""
}

# Dispatch selon l'argument passé
case "$1" in
  clean) clean ;;
  help)  show_help; exit 0 ;;
esac

# =============================================================================
# ÉTAPE 1 — Active le forwarding IP
# Sans ça, la VM ne route pas les paquets entre ses interfaces réseau.
# Le forwarding est requis pour que les paquets transitent de enp0s8 (host-only)
# vers l'interface bridge Minikube.
# =============================================================================
info "Activation du forwarding IP"
sudo sysctl -w net.ipv4.ip_forward=1
log "ip_forward activé"

# =============================================================================
# ÉTAPE 2 — Règle DNAT (Destination NAT)
# Intercepte les paquets arrivant sur VM_IP:APP_PORT et modifie leur
# destination vers MINIKUBE_IP:APP_PORT avant routage.
# → PREROUTING = appliqué avant que le paquet soit routé localement
# La vérification préalable évite les règles dupliquées en cas de relance.
# =============================================================================
info "Ajout règle DNAT"
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
# ÉTAPE 3 — Règle MASQUERADE (SNAT dynamique)
# Remplace l'IP source du paquet par celle de la VM avant envoi au pod.
# Sans cette règle, le pod répondrait directement à l'IP Windows, qui ne
# connaît pas le réseau Minikube → la connexion serait perdue en retour.
# → POSTROUTING = appliqué après routage, juste avant l'envoi sur le réseau
# =============================================================================
info "Ajout règle MASQUERADE"
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
# ÉTAPE 4 — Règles FORWARD
# Autorise le transit des paquets vers le réseau Minikube.
# La policy par défaut de la chaîne FORWARD est DROP sur cette VM →
# sans ces règles, les paquets NATés seraient silencieusement jetés.
#   - Première règle  : autorise tout paquet à destination du réseau Minikube
#   - Deuxième règle  : autorise les réponses des connexions déjà établies
#     (RELATED,ESTABLISHED) → requis pour le trafic retour du pod vers Windows
# =============================================================================
info "Ajout règles FORWARD"
if sudo iptables -C FORWARD -d $MINIKUBE_NET -j ACCEPT 2>/dev/null; then
  log "Règle FORWARD déjà présente → skip"
else
  sudo iptables -I FORWARD -d $MINIKUBE_NET -j ACCEPT
  sudo iptables -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log "Règles FORWARD ajoutées (réseau $MINIKUBE_NET)"
fi

# =============================================================================
# ÉTAPE 5 — Test de connectivité depuis la VM
# Vérifie que l'application répond avant d'afficher l'URL Windows.
# HTTP 200 = page servie normalement
# HTTP 302 = redirection (ex: /login) → également valide, app démarrée
# HTTP 000 = connexion refusée ou timeout → pod non prêt ou mauvais port
# =============================================================================
info "Test de connectivité"
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
# RÉCAP FINAL
# =============================================================================
echo ""
title "=============================================="
title "     RÉSEAU CONFIGURÉ !"
title "=============================================="
echo ""
echo "📋 Règles iptables actives :"
sudo iptables -t nat -L -n | grep -E "$MINIKUBE_IP|$VM_IP" || true
echo ""
echo "🔗 Accès depuis l'hôte Windows :"
echo "   http://$VM_IP:$APP_PORT"
echo ""
show_help
