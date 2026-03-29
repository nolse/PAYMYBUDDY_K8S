#!/bin/bash
# =============================================================================
# cleanup.sh - Supprime toutes les ressources PayMyBuddy du cluster
#
# ⚠️  ATTENTION : ce script supprime TOUT y compris le PVC MySQL
#     → les données de la base seront PERDUES
#
# Usage : bash cleanup.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..] $1${NC}"; }
warn() { echo -e "${RED}[⚠️ ]${NC} $1"; }

# =============================================================================
# CONFIRMATION AVANT SUPPRESSION
# =============================================================================
warn "Ce script va supprimer TOUTES les ressources PayMyBuddy"
warn "y compris le PVC MySQL → les données seront PERDUES"
echo ""
read -p "Confirmer ? (oui/non) : " CONFIRM

if [ "$CONFIRM" != "oui" ]; then
  echo "Annulé."
  exit 0
fi

# =============================================================================
# ÉTAPE 1 — Suppression des déploiements et services
# =============================================================================
info "=== Suppression des déploiements ==="
kubectl delete deployment paymybuddy mysql \
  -n paymybuddy --ignore-not-found
kubectl delete svc paymybuddy mysql \
  -n paymybuddy --ignore-not-found
log "Déploiements et services supprimés"

# =============================================================================
# ÉTAPE 2 — Suppression du ConfigMap
# =============================================================================
info "=== Suppression du ConfigMap SQL ==="
kubectl delete configmap mysql-init-scripts \
  -n paymybuddy --ignore-not-found
log "ConfigMap supprimé"

# =============================================================================
# ÉTAPE 3 — Suppression du PVC MySQL
# Le PVC est supprimé EN DERNIER car il contient les données
# =============================================================================
info "=== Suppression du PVC MySQL ==="
kubectl delete pvc mysql-pvc \
  -n paymybuddy --ignore-not-found
log "PVC supprimé"

# =============================================================================
# ÉTAPE 4 — Suppression des règles iptables PayMyBuddy
# On supprime uniquement les règles sur le port 30080
# Les règles WordPress (port 80) sont conservées
# =============================================================================
info "=== Nettoyage des règles iptables ==="

# Supprime la règle DNAT port 30080
sudo iptables -t nat -D PREROUTING \
  -d 192.168.56.100 -p tcp --dport 30080 \
  -j DNAT --to-destination 192.168.49.2:30080 2>/dev/null \
  && log "Règle DNAT supprimée" || log "Règle DNAT absente → skip"

# Supprime la règle MASQUERADE port 30080
sudo iptables -t nat -D POSTROUTING \
  -d 192.168.49.2 -p tcp --dport 30080 \
  -j MASQUERADE 2>/dev/null \
  && log "Règle MASQUERADE supprimée" || log "Règle MASQUERADE absente → skip"

# =============================================================================
# ÉTAPE 5 — Suppression du namespace
# Le namespace est supprimé EN DERNIER
# (supprimer un namespace supprime aussi toutes ses ressources restantes)
# =============================================================================
info "=== Suppression du namespace ==="
kubectl delete namespace paymybuddy --ignore-not-found
log "Namespace supprimé"

# =============================================================================
# RÉCAP
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN}     NETTOYAGE TERMINÉ !${NC}"
echo "=============================================="
echo ""
echo "Vérification :"
kubectl get all -n paymybuddy 2>/dev/null \
  || echo "Namespace paymybuddy supprimé ✅"
