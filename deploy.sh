#!/bin/bash
# =============================================================================
# deploy.sh - Déploiement complet PayMyBuddy sur Kubernetes
#
# Prérequis :
#   - Minikube en cours d'exécution
#   - Java 17 installé (bootstrap.sh)
#   - Image paymybuddy:latest buildée et chargée dans minikube
#
# Ce script gère :
#   - La vérification des prérequis
#   - L'ordre de déploiement (namespace → MySQL → PayMyBuddy)
#   - L'attente que chaque pod soit prêt avant de continuer
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..] $1${NC}"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

# --- Attend que tous les pods d'un déploiement soient Running ---
wait_for_deployment() {
  local name=$1
  local namespace=$2
  local timeout=180
  local elapsed=0
  info "Attente du déploiement '$name' dans le namespace '$namespace'..."
  until kubectl rollout status deployment/$name -n $namespace --timeout=10s &>/dev/null; do
    elapsed=$((elapsed + 10))
    if [ $elapsed -ge $timeout ]; then
      err "Timeout : '$name' non prêt après ${timeout}s"
    fi
    echo "  ... encore en cours ($elapsed s)"
    sleep 10
  done
  log "Déploiement '$name' prêt !"
}

# =============================================================================
# ÉTAPE 0 — Vérification des prérequis
# =============================================================================
info "=== Vérification des prérequis ==="

# Vérifie que minikube tourne
minikube status | grep -q "Running" \
  || err "Minikube n'est pas démarré → lance : minikube start"
log "Minikube OK"

# Vérifie que l'image paymybuddy est bien dans le cache minikube
# → si absente, il faut rebuilder et recharger
minikube image ls 2>/dev/null | grep -q "paymybuddy" \
  || err "Image paymybuddy:latest absente du cache minikube
  → depuis ~/PayMyBuddy :
    docker build -t paymybuddy:latest .
    minikube image load paymybuddy:latest"
log "Image paymybuddy:latest OK"

# Vérifie que l'image mysql est disponible
minikube image ls 2>/dev/null | grep -q "mysql" || {
  info "Image mysql:5.7 absente → chargement en cours..."
  docker pull mysql:5.7
  minikube image load mysql:5.7
}
log "Image mysql:5.7 OK"

# =============================================================================
# ÉTAPE 1 — Nettoyage des anciens déploiements
# Le PVC MySQL est conservé pour préserver les données
# =============================================================================
info "=== Nettoyage des anciens déploiements ==="
kubectl delete deployment paymybuddy mysql -n paymybuddy --ignore-not-found
kubectl delete svc paymybuddy mysql -n paymybuddy --ignore-not-found
kubectl delete configmap mysql-init-scripts -n paymybuddy --ignore-not-found
info "Attente suppression des pods (15s)..."
sleep 15
log "Nettoyage terminé (PVC MySQL conservé)"

# =============================================================================
# ÉTAPE 2 — Création du namespace
# Isole toutes les ressources PayMyBuddy des autres projets du cluster
# kubectl apply = ne recrée pas si déjà existant
# =============================================================================
info "=== Création du namespace ==="
kubectl apply -f namespace.yaml
log "Namespace 'paymybuddy' prêt"

# =============================================================================
# ÉTAPE 3 — ConfigMap SQL
# Injecte les scripts create.sql et data.sql dans MySQL
# → exécutés automatiquement au premier démarrage du container MySQL
# =============================================================================
info "=== Application du ConfigMap SQL ==="
kubectl apply -f mysql-configmap.yaml
log "ConfigMap SQL prêt"

# =============================================================================
# ÉTAPE 4 — PVC MySQL
# kubectl apply = ne recrée pas si déjà existant → données préservées
# =============================================================================
info "=== Création du PVC MySQL ==="
kubectl apply -f mysql-pvc.yaml
kubectl get pvc -n paymybuddy
log "PVC MySQL prêt"

# =============================================================================
# ÉTAPE 5 — Déploiement MySQL
# MySQL doit être prêt AVANT PayMyBuddy qui en dépend pour sa connexion JDBC
# =============================================================================
info "=== Déploiement MySQL ==="
kubectl apply -f mysql-deployment.yaml
kubectl apply -f mysql-service.yaml
wait_for_deployment mysql paymybuddy

# Pause pour laisser MySQL initialiser la base et exécuter les scripts SQL
info "Initialisation MySQL + exécution des scripts SQL (30s)..."
sleep 30
log "MySQL prêt"

# =============================================================================
# ÉTAPE 6 — Déploiement PayMyBuddy
# =============================================================================
info "=== Déploiement PayMyBuddy ==="
kubectl apply -f paymybuddy-deployment.yaml
kubectl apply -f paymybuddy-service.yaml
wait_for_deployment paymybuddy paymybuddy
log "PayMyBuddy prêt"

# =============================================================================
# RÉCAP FINAL
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN}     DÉPLOIEMENT TERMINÉ AVEC SUCCÈS !${NC}"
echo "=============================================="
echo ""
echo "📦 Pods :"
kubectl get pods -n paymybuddy
echo ""
echo "💾 Stockage (PVCs) :"
kubectl get pvc -n paymybuddy
echo ""
echo "🌐 Services :"
kubectl get svc -n paymybuddy
echo ""
echo "🔗 Accès depuis l'hôte Windows :"
echo "   http://192.168.56.100:30080"
echo ""
echo "🔑 Comptes de test disponibles :"
echo "   hayley@mymail.com  / (mot de passe hashé en base)"
echo "   clara@mail.com     / (mot de passe hashé en base)"
echo "   smith@mail.com     / (mot de passe hashé en base)"
