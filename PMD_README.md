# Projet Kubernetes — PayMyBuddy sans Helm

Déploiement de l'application Spring Boot **PayMyBuddy** sur Kubernetes, **sans Helm**, en utilisant des manifests YAML écrits à la main.

> **Environnement** : VM Vagrant + VirtualBox + Minikube (driver Docker)
> **OS hôte** : Windows
> **OS VM** : Ubuntu 22.04

---

## Sommaire

- [Architecture](#architecture)
- [Prérequis](#prérequis)
- [Structure du projet](#structure-du-projet)
- [Déploiement pas à pas](#déploiement-pas-à-pas)
- [Accès à l'application](#accès-à-lapplication)
- [Scripts disponibles](#scripts-disponibles)
- [Persistance des données](#persistance-des-données)
- [Dépannage](#dépannage)
- [Limitations environnement DEV](#limitations-environnement-dev)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Machine hôte Windows                     │
│                                                             │
│   Navigateur → http://192.168.56.100:30080                  │
└─────────────────────┬───────────────────────────────────────┘
                      │ interface host-only (192.168.56.100)
                      │ DNAT iptables (setup-network.sh)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    VM Vagrant Ubuntu 22.04                   │
│                    IP : 192.168.56.100                       │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Minikube (driver Docker)                │   │
│  │              IP node : 192.168.49.2                  │   │
│  │                                                      │   │
│  │  Namespace : paymybuddy                              │   │
│  │                                                      │   │
│  │  ┌─────────────────┐      ┌──────────────────────┐  │   │
│  │  │  PayMyBuddy Pod │      │      MySQL Pod        │  │   │
│  │  │  Spring Boot    │─────▶│      mysql:5.7        │  │   │
│  │  │  port: 8080     │      │      port: 3306       │  │   │
│  │  └────────┬────────┘      └──────────┬───────────┘  │   │
│  │           │                          │               │   │
│  │  ┌────────▼────────┐      ┌──────────▼───────────┐  │   │
│  │  │ Service NodePort│      │  Service ClusterIP   │  │   │
│  │  │ port: 30080     │      │  port: 3306          │  │   │
│  │  └─────────────────┘      └──────────────────────┘  │   │
│  │                                     │                │   │
│  │                           ┌──────────▼───────────┐  │   │
│  │                           │   PVC mysql-pvc 2Gi  │  │   │
│  │                           └──────────────────────┘  │   │
│  │                                                      │   │
│  │  PayMyBuddy data → hostPath /data/paymybuddy         │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Flux de connexion

```
Windows:30080 → DNAT → minikube:30080 → Service NodePort
      → PayMyBuddy Pod:8080
      → JDBC mysql://mysql:3306/db_paymybuddy (DNS interne K8s)
      → MySQL Pod:3306
```

### Init base de données

```
ConfigMap (mysql-init-scripts)
  ├── create.sql  → crée la base db_paymybuddy + tables
  └── data.sql    → insère les données de test
        ↓
  monté dans /docker-entrypoint-initdb.d/
        ↓
  exécuté automatiquement au premier démarrage MySQL
```

---

## Prérequis

### Machine hôte Windows

| Outil | Version testée | Lien |
|---|---|---|
| VirtualBox | 7.x | https://www.virtualbox.org |
| Vagrant | 2.x | https://www.vagrantup.com |
| Git | any | https://git-scm.com |

### Cloner les projets

```bash
# Projet Kubernetes (manifests)
git clone <url-de-ce-repo>

# Code source PayMyBuddy (nécessaire pour builder l'image)
git clone https://github.com/eazytraining/PayMyBuddy.git
```

### Démarrer la VM

```bash
# Depuis le dossier contenant le Vagrantfile
vagrant up    # première fois : ~10 min
vagrant ssh
```

---

## Structure du projet

```
PMB_KUBERNETIES/
├── bootstrap.sh               # Installe Java 17 (prérequis au build)
├── setup-network.sh           # Configure les règles iptables (accès Windows)
├── deploy.sh                  # Déploiement complet automatisé
├── cleanup.sh                 # Suppression de toutes les ressources
├── namespace.yaml             # Namespace dédié 'paymybuddy'
├── mysql-configmap.yaml       # Scripts SQL injectés dans MySQL au démarrage
├── mysql-pvc.yaml             # PersistentVolumeClaim MySQL 2Gi
├── mysql-deployment.yaml      # Déploiement MySQL 5.7
├── mysql-service.yaml         # Service ClusterIP MySQL (interne cluster)
├── paymybuddy-deployment.yaml # Déploiement PayMyBuddy (image locale)
└── paymybuddy-service.yaml    # Service NodePort (port 30080)
```

---

## Déploiement pas à pas

### Étape 1 — Installer Java 17

Les repos Ubuntu 22.04 sont hors ligne sur cette box — Java est installé
directement depuis Amazon Corretto sans passer par apt :

```bash
cd ~/PayMyBuddy/PMB_KUBERNETIES
bash bootstrap.sh
source ~/.bashrc

# Vérifie
java -version
# → openjdk version "17.0.x" Amazon Corretto
```

### Étape 2 — Compiler l'application

Le projet inclut un Maven Wrapper qui télécharge automatiquement Maven 3.8.5 :

```bash
cd ~/PayMyBuddy

# -DskipTests = skip les tests pour accélérer le build
./mvnw clean install -DskipTests

# Vérifie que le .jar est produit
ls -la target/paymybuddy.jar
```

### Étape 3 — Builder et charger l'image Docker

```bash
cd ~/PayMyBuddy

# Build l'image depuis le Dockerfile
# Le Dockerfile copie target/paymybuddy.jar dans une image amazoncorretto:17-alpine
docker build -t paymybuddy:latest .

# Charge l'image dans le cache interne de minikube
# (minikube a son propre daemon Docker séparé)
minikube image load paymybuddy:latest

# Vérifie
minikube image ls | grep paymybuddy
```

### Étape 4 — Déployer sur Kubernetes

```bash
cd ~/PayMyBuddy/PMB_KUBERNETIES
bash deploy.sh
```

Le script effectue dans l'ordre :
1. Vérification des prérequis (minikube, image)
2. Nettoyage des anciens déploiements
3. Création du namespace `paymybuddy`
4. Application du ConfigMap SQL
5. Création du PVC MySQL
6. Déploiement MySQL + attente init base (30s)
7. Déploiement PayMyBuddy + attente
8. Récap final

### Étape 5 — Configurer le réseau

```bash
bash setup-network.sh
```

Ce script crée les règles iptables nécessaires pour accéder à l'application
depuis Windows via le réseau host-only VirtualBox.

---

## Accès à l'application

```
http://192.168.56.100:30080
```

### Comptes de test (injectés par data.sql)

| Email | Prénom | Solde |
|---|---|---|
| hayley@mymail.com | Hayley James | 10.00 € |
| clara@mail.com | Clara Tarazi | 133.56 € |
| smith@mail.com | Smith Sam | 8.00 € |
| lambda@mail.com | Lambda User | 96.91 € |

> Les mots de passe sont hashés en bcrypt dans la base.
> Consulter le fichier `src/main/resources/database/data.sql` pour les hashs.

---

## Scripts disponibles

### bootstrap.sh
Installe Java 17 (Amazon Corretto) sans apt.
Idempotent — peut être relancé sans risque.
```bash
bash bootstrap.sh
```

### deploy.sh
Déploie toute la stack PayMyBuddy sur Kubernetes.
```bash
bash deploy.sh
```

### setup-network.sh
Configure les règles iptables pour l'accès depuis Windows.
Idempotent — vérifie si les règles existent avant de les ajouter.
```bash
bash setup-network.sh
```

### cleanup.sh
Supprime toutes les ressources Kubernetes PayMyBuddy.
⚠️ Supprime aussi le PVC → données perdues.
```bash
bash cleanup.sh
```

---

## Persistance des données

| Données | Mécanisme | Emplacement |
|---|---|---|
| Base MySQL | PersistentVolumeClaim 2Gi | géré par Kubernetes |
| Fichiers PayMyBuddy | hostPath | `/data/paymybuddy` sur le nœud |

Le PVC MySQL **n'est pas supprimé** par `deploy.sh` — les données
survivent aux redéploiements. Seul `cleanup.sh` supprime le PVC.

---

## Dépannage

### Pod en ImagePullBackOff

```bash
# L'image paymybuddy doit être dans le cache minikube (pas sur Docker Hub)
minikube image ls | grep paymybuddy

# Si absente → rebuild et rechargement
cd ~/PayMyBuddy
docker build -t paymybuddy:latest .
minikube image load paymybuddy:latest
```

### PayMyBuddy ne se connecte pas à MySQL

```bash
# Vérifie les logs de PayMyBuddy
kubectl logs -n paymybuddy -l app=paymybuddy --tail=50

# Vérifie que MySQL est bien Running
kubectl get pods -n paymybuddy

# Vérifie que la base a bien été initialisée
kubectl exec -n paymybuddy -it \
  $(kubectl get pod -n paymybuddy -l app=mysql -o jsonpath='{.items[0].metadata.name}') \
  -- mysql -u root -ppassword -e "SHOW DATABASES;"
```

### Application inaccessible depuis Windows

```bash
# 1. Vérifie que les pods tournent
kubectl get pods -n paymybuddy

# 2. Vérifie les règles iptables
sudo iptables -t nat -L -n | grep 30080

# 3. Relance le script réseau si besoin
bash setup-network.sh

# 4. Teste depuis la VM
curl -s -o /dev/null -w "%{http_code}" http://192.168.49.2:30080
```

### DNS cassé dans la VM

```bash
sudo chattr -i /etc/resolv.conf
sudo tee /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
sudo chattr +i /etc/resolv.conf
```

---

## Limitations environnement DEV

| Limitation | Risque | Solution en production |
|---|---|---|
| Mots de passe en clair dans les yamls | Fuite de credentials | Kubernetes Secrets |
| Image locale non publiée | Non reproductible sans rebuild | Publier sur Docker Hub ou registry privé |
| 1 seul replica | Pas de haute disponibilité | `replicas: 3` + PodDisruptionBudget |
| hostPath pour PayMyBuddy | Lié au nœud minikube | PVC avec StorageClass |
| NodePort sans TLS | Trafic HTTP en clair | Ingress + cert-manager + TLS |
| iptables manuelles | Perdues au reboot | Service systemd |
| Init SQL via ConfigMap | Réexécuté si pod recréé | Flyway ou Liquibase |
