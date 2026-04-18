#!/bin/bash
# =============================================================================
# deploy.sh - Déploiement complet PayMyBuddy sur Kubernetes
#
# Ce script gère l'intégralité du cycle de vie du déploiement :
#   - Vérification des prérequis (Minikube, Docker Hub, images)
#   - Nettoyage des anciens déploiements (PVC MySQL conservé)
#   - Déploiement ordonné : namespace → Secret → ConfigMap → PVC → MySQL → PayMyBuddy
#   - Attente que chaque pod soit prêt avant de passer à l'étape suivante
#
# Usage :
#   bash deploy.sh          → déploiement complet
#   bash deploy.sh clean    → supprime toutes les ressources Kubernetes du projet
#   bash deploy.sh help     → affiche cette aide
#
# Prérequis :
#   - Minikube en cours d'exécution  (minikube start)
#   - Image alphabalde/paymybuddy:latest publiée sur Docker Hub
#   - Fichiers manifests présents dans le répertoire courant
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
# FONCTION — Attend que le rollout d'un déploiement soit terminé
# Interroge kubectl toutes les 10s jusqu'à ce que tous les pods soient Ready
# ou jusqu'au timeout (300s par défaut — Spring Boot peut être lent au démarrage)
# =============================================================================
wait_for_deployment() {
  local name=$1
  local namespace=$2
  local timeout=300
  local elapsed=0
  info "Attente du déploiement '$name' (namespace: $namespace)"
  until kubectl rollout status deployment/$name -n $namespace --timeout=10s &>/dev/null; do
    elapsed=$((elapsed + 10))
    if [ $elapsed -ge $timeout ]; then
      err "Timeout : '$name' non prêt après ${timeout}s → kubectl logs -n $namespace"
    fi
    echo "  ... encore en cours (${elapsed}s / ${timeout}s)"
    sleep 10
  done
  log "Déploiement '$name' prêt !"
}

# =============================================================================
# OPTION CLEAN — Supprime toutes les ressources Kubernetes du projet
# Le PVC MySQL peut être supprimé ou conservé selon le flag --purge
#
# Usage :
#   bash deploy.sh clean          → supprime tout sauf le PVC MySQL (données conservées)
#   bash deploy.sh clean --purge  → supprime TOUT y compris le PVC MySQL (données perdues)
# =============================================================================
clean() {
  title "\n=============================="
  title "  NETTOYAGE DES RESSOURCES K8S"
  title "==============================\n"

  info "Suppression des déploiements"
  kubectl delete deployment paymybuddy mysql -n paymybuddy --ignore-not-found
  log "Déploiements supprimés"

  info "Suppression des services"
  kubectl delete svc paymybuddy mysql -n paymybuddy --ignore-not-found
  log "Services supprimés"

  info "Suppression du ConfigMap SQL"
  kubectl delete configmap mysql-init-scripts -n paymybuddy --ignore-not-found
  log "ConfigMap supprimé"

  info "Suppression du Secret MySQL"
  kubectl delete secret mysql-secret -n paymybuddy --ignore-not-found
  log "Secret supprimé"

  # Suppression du PVC uniquement si --purge est passé en argument
  # Sans --purge, les données MySQL sont conservées entre les redéploiements
  if [ "$2" = "--purge" ]; then
    info "Suppression du PVC MySQL (--purge activé — données PERDUES)"
    kubectl delete pvc mysql-pvc -n paymybuddy --ignore-not-found
    log "PVC MySQL supprimé"

    info "Suppression du namespace"
    kubectl delete namespace paymybuddy --ignore-not-found
    log "Namespace supprimé"
  else
    log "PVC MySQL conservé (données préservées) → utilise --purge pour tout supprimer"
  fi

  echo ""
  log "Nettoyage terminé"
  show_help
  exit 0
}

# =============================================================================
# OPTION HELP — Affiche les commandes et options disponibles
# =============================================================================
show_help() {
  echo ""
  title "=============================================="
  title "     COMMANDES DISPONIBLES"
  title "=============================================="
  echo ""
  echo "  bash deploy.sh                → Déploiement complet PayMyBuddy"
  echo "  bash deploy.sh clean          → Supprime les ressources (PVC conservé)"
  echo "  bash deploy.sh clean --purge  → Supprime TOUT y compris PVC et namespace"
  echo "  bash deploy.sh help           → Affiche cette aide"
  echo ""
  echo "  Workflow typique par session :"
  echo "    1. minikube start --driver=docker"
  echo "    2. bash deploy.sh"
  echo "    3. bash setup-network.sh"
  echo "    4. Accès → http://192.168.56.100:30080"
  echo ""
  echo "  Fin de session :"
  echo "    bash setup-network.sh clean"
  echo "    bash deploy.sh clean         (données conservées)"
  echo "    minikube stop"
  echo ""
  echo "  Comptes de test :"
  echo "    hayley@mymail.com  / (mot de passe hashé en base)"
  echo "    clara@mail.com     / (mot de passe hashé en base)"
  echo "    smith@mail.com     / (mot de passe hashé en base)"
  echo ""
}

# Dispatch selon l'argument passé
case "$1" in
  clean) clean "$@" ;;
  help)  show_help; exit 0 ;;
esac

# =============================================================================
# ÉTAPE 0 — Vérification des prérequis
# Bloque le déploiement si les conditions minimales ne sont pas réunies
# =============================================================================
info "Vérification des prérequis"

# Minikube doit être démarré et Running
minikube status | grep -q "Running" \
  || err "Minikube n'est pas démarré → lance : minikube start --driver=docker"
log "Minikube Running"

# L'image PayMyBuddy doit être accessible sur Docker Hub
# imagePullPolicy: Always dans le manifest → Kubernetes pullera à chaque déploiement
docker pull alphabalde/paymybuddy:latest &>/dev/null \
  || err "Impossible de joindre Docker Hub → vérifie ta connexion internet"
log "Image alphabalde/paymybuddy:latest accessible sur Docker Hub"

# L'image MySQL doit être disponible localement dans Minikube
# pour éviter un pull Docker Hub à chaque déploiement
minikube image ls 2>/dev/null | grep -q "mysql" || {
  info "Image mysql:5.7 absente du cache Minikube → chargement en cours..."
  docker pull mysql:5.7
  minikube image load mysql:5.7
}
log "Image mysql:5.7 disponible dans Minikube"

# =============================================================================
# ÉTAPE 1 — Nettoyage des anciens déploiements
# Supprime les ressources existantes pour repartir d'un état propre.
# Le PVC MySQL est volontairement conservé → les données de la base
# survivent entre les redéploiements (comptes utilisateurs, transactions).
# Le Secret est recréé à chaque fois depuis mysql-secret.yaml.
# =============================================================================
info "Nettoyage des anciens déploiements"
kubectl delete deployment paymybuddy mysql -n paymybuddy --ignore-not-found
kubectl delete svc paymybuddy mysql -n paymybuddy --ignore-not-found
kubectl delete configmap mysql-init-scripts -n paymybuddy --ignore-not-found
kubectl delete secret mysql-secret -n paymybuddy --ignore-not-found

# Attente de la terminaison effective des pods avant de recréer les ressources
info "Attente suppression des pods (15s)"
sleep 15
log "Nettoyage terminé — PVC MySQL conservé"

# =============================================================================
# ÉTAPE 2 — Création du namespace
# Isole toutes les ressources PayMyBuddy dans un namespace dédié.
# kubectl apply est idempotent → ne recrée pas si déjà existant.
# =============================================================================
info "Création du namespace"
kubectl apply -f namespace.yaml
log "Namespace 'paymybuddy' prêt"

# =============================================================================
# ÉTAPE 3 — Secret MySQL
# Stocke les credentials MySQL (user, password, database) sous forme encodée.
# Doit être créé AVANT MySQL et PayMyBuddy qui en dépendent tous les deux.
# =============================================================================
info "Création du Secret MySQL"
kubectl apply -f mysql-secret.yaml
log "Secret MySQL prêt"

# =============================================================================
# ÉTAPE 4 — ConfigMap SQL
# Contient les scripts create.sql et data.sql montés dans le container MySQL.
# MySQL les exécute automatiquement au premier démarrage du container
# (répertoire /docker-entrypoint-initdb.d/).
# =============================================================================
info "Application du ConfigMap SQL"
kubectl apply -f mysql-configmap.yaml
log "ConfigMap SQL prêt"

# =============================================================================
# ÉTAPE 5 — PVC MySQL
# Réserve le stockage persistant pour les données MySQL.
# kubectl apply est idempotent → si le PVC existe déjà (données conservées),
# cette étape ne fait rien et les données restent intactes.
# =============================================================================
info "Création du PVC MySQL"
kubectl apply -f mysql-pvc.yaml
kubectl get pvc -n paymybuddy
log "PVC MySQL prêt"

# =============================================================================
# ÉTAPE 6 — Déploiement MySQL
# MySQL doit être entièrement prêt AVANT PayMyBuddy.
# Spring Boot tente la connexion JDBC au démarrage — si MySQL n'est pas prêt,
# l'application crashe immédiatement (CrashLoopBackOff).
# wait_for_deployment attend que la readinessProbe MySQL passe au vert.
# La pause de 30s supplémentaire laisse MySQL exécuter les scripts SQL d'init.
# =============================================================================
info "Déploiement MySQL"
kubectl apply -f mysql-deployment.yaml
kubectl apply -f mysql-service.yaml
wait_for_deployment mysql paymybuddy

# Pause pour laisser MySQL terminer l'initialisation de la base
# et l'exécution des scripts SQL (create.sql + data.sql)
info "Initialisation MySQL — exécution des scripts SQL (30s)"
sleep 30
log "MySQL prêt et base initialisée"

# =============================================================================
# ÉTAPE 7 — Déploiement PayMyBuddy
# L'image est pullée depuis Docker Hub (imagePullPolicy: Always).
# Les probes readiness (/login, port 8080) et liveness surveillent l'état.
# wait_for_deployment attend que Spring Boot ait terminé son démarrage.
# =============================================================================
info "Déploiement PayMyBuddy"
kubectl apply -f paymybuddy-deployment.yaml
kubectl apply -f paymybuddy-service.yaml
wait_for_deployment paymybuddy paymybuddy
log "PayMyBuddy prêt"

# =============================================================================
# RÉCAP FINAL
# =============================================================================
echo ""
title "=============================================="
title "     DÉPLOIEMENT TERMINÉ AVEC SUCCÈS !"
title "=============================================="
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
show_help
