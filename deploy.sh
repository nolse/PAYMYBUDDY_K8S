#!/bin/bash
# =============================================================================
# deploy.sh - Déploiement complet PayMyBuddy sur Kubernetes
#
# Prérequis :
#   - Minikube en cours d'exécution
#   - Image alphabalde/paymybuddy:latest publiée sur Docker Hub
#
# Ce script gère :
#   - La vérification des prérequis
#   - L'ordre de déploiement (namespace → Secret → MySQL → PayMyBuddy)
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
# Augmenté à 300s pour laisser le temps à Spring Boot de démarrer
# et à Kubernetes de puller l'image depuis Docker Hub
wait_for_deployment() {
  local name=$1
  local namespace=$2
  local timeout=300
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

# Vérifie la connexion à Docker Hub (nécessaire pour puller l'image)
# L'image est maintenant hébergée sur Docker Hub, plus besoin du cache minikube
docker pull alphabalde/paymybuddy:latest &>/dev/null \
  || err "Impossible de joindre Docker Hub → vérifie ta connexion internet"
log "Image alphabalde/paymybuddy:latest accessible sur Docker Hub"

# Vérifie que l'image mysql est disponible
minikube image ls 2>/dev/null | grep -q "mysql" || {
  info "Image mysql:5.7 absente → chargement en cours..."
  docker pull mysql:5.7
  minikube image load mysql:5.7
}
log "Image mysql:5.7 OK"

# =============================================================================
# ÉTAPE 1 — Nettoyage des anciens déploiements
# Le PVC MySQL est conservé pour préserver les données entre les redéploiements
# Le Secret est recréé à chaque déploiement (données non persistantes)
# =============================================================================
info "=== Nettoyage des anciens déploiements ==="
kubectl delete deployment paymybuddy mysql -n paymybuddy --ignore-not-found
kubectl delete svc paymybuddy mysql -n paymybuddy --ignore-not-found
kubectl delete configmap mysql-init-scripts -n paymybuddy --ignore-not-found
kubectl delete secret mysql-secret -n paymybuddy --ignore-not-found
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
# ÉTAPE 3 — Secret MySQL
# Stocke les credentials MySQL de façon sécurisée
# Doit être créé AVANT MySQL et PayMyBuddy qui en dépendent
# =============================================================================
info "=== Création du Secret MySQL ==="
kubectl apply -f mysql-secret.yaml
log "Secret MySQL prêt"

# =============================================================================
# ÉTAPE 4 — ConfigMap SQL
# Injecte les scripts create.sql et data.sql dans MySQL
# → exécutés automatiquement au premier démarrage du container MySQL
# =============================================================================
info "=== Application du ConfigMap SQL ==="
kubectl apply -f mysql-configmap.yaml
log "ConfigMap SQL prêt"

# =============================================================================
# ÉTAPE 5 — PVC MySQL
# kubectl apply = ne recrée pas si déjà existant → données préservées
# =============================================================================
info "=== Création du PVC MySQL ==="
kubectl apply -f mysql-pvc.yaml
kubectl get pvc -n paymybuddy
log "PVC MySQL prêt"

# =============================================================================
# ÉTAPE 6 — Déploiement MySQL
# MySQL doit être prêt AVANT PayMyBuddy qui en dépend pour sa connexion JDBC
# La readinessProbe garantit que MySQL accepte les connexions avant de continuer
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
# ÉTAPE 7 — Déploiement PayMyBuddy
# L'image est pullée depuis Docker Hub (imagePullPolicy: Always)
# Les readinessProbe et livenessProbe surveillent l'état de l'application
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
