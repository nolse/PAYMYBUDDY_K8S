#!/bin/bash
# =============================================================================
# bootstrap.sh - Installation de Java 17 (Amazon Corretto)
#
# Contexte : les repos Ubuntu 22.04 (Jammy) sont hors ligne sur cette box,
# on télécharge donc directement depuis les sources officielles.
#
# Maven N'EST PAS installé ici car le projet PayMyBuddy inclut un Maven Wrapper
# (.mvn/wrapper/maven-wrapper.properties) qui télécharge automatiquement
# Maven 3.8.5 lors du premier appel à ./mvnw
#
# Ce script est idempotent : peut être relancé sans risque.
# Usage : bash bootstrap.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..] $1${NC}"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

JAVA_HOME_DIR="/opt/java"

# Remet un PATH système complet dès le début
# → évite les erreurs "command not found" si le PATH est corrompu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

# =============================================================================
# JAVA 17 — Amazon Corretto
# On utilise Amazon Corretto car c'est la même distribution que le Dockerfile
# (image amazoncorretto:17-alpine) → cohérence entre dev et prod
# =============================================================================
info "=== Vérification Java 17 ==="

if java -version 2>/dev/null | grep -q "17"; then
  log "Java 17 déjà installé → skip"
else
  info "Java 17 non trouvé, installation depuis Amazon Corretto..."

  curl -Lo /tmp/java17.tar.gz \
    https://corretto.aws/downloads/latest/amazon-corretto-17-x64-linux-jdk.tar.gz \
    || err "Échec du téléchargement de Java 17"

  sudo mkdir -p "$JAVA_HOME_DIR"
  sudo tar -xzf /tmp/java17.tar.gz -C "$JAVA_HOME_DIR" --strip-components=1
  rm -f /tmp/java17.tar.gz

  log "Java 17 installé"
fi

# Active Java dans la session courante
export JAVA_HOME="$JAVA_HOME_DIR"
export PATH="$JAVA_HOME/bin:$PATH"

java -version 2>&1 | head -1
log "Java OK"

# =============================================================================
# PERSISTANCE dans .bashrc
# =============================================================================
info "=== Mise à jour du PATH dans ~/.bashrc ==="

sed -i '/JAVA_HOME/d' ~/.bashrc
sed -i '/opt\/java/d' ~/.bashrc
sed -i '/bootstrap.sh/d' ~/.bashrc

cat >> ~/.bashrc << 'EOF'

# Java 17 Amazon Corretto — installé par bootstrap.sh
export JAVA_HOME=/opt/java
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$JAVA_HOME/bin:$PATH
EOF

log ".bashrc mis à jour"

# =============================================================================
# RÉCAP
# =============================================================================
echo ""
echo "=============================================="
echo -e "${GREEN}     BOOTSTRAP TERMINÉ !${NC}"
echo "=============================================="
echo ""
java -version 2>&1 | head -1
echo ""
echo "ℹ️  Maven n'est pas installé séparément :"
echo "   Le projet utilise le Maven Wrapper (./mvnw)"
echo "   qui télécharge automatiquement Maven 3.8.5"
echo ""
echo "Prochaine étape → compiler PayMyBuddy :"
echo "   cd ~/PayMyBuddy"
echo "   ./mvnw clean install -DskipTests"
