#!/bin/bash
set -euo pipefail

# Configuration
LOG_FILE="/var/log/todo-deploy.log"
ENV_FILE="/opt/todo-stack/.env"
BACKUP_DIR="/var/backups/todo-api"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Fonction pour logger avec horodatage
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1" | tee -a "$LOG_FILE"
}

# Vérification de l'argument
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <nouvelle_version>"
    exit 1
fi

NEW_VERSION=$1
log "=== Début du déploiement de la version $NEW_VERSION ==="

cd /opt/todo-stack

# 1. Récupération de l'ancienne version
OLD_VERSION=$(grep APP_VERSION $ENV_FILE | cut -d '=' -f2)
log "Version actuelle : $OLD_VERSION"

if [ "$OLD_VERSION" == "$NEW_VERSION" ]; then
    log "La version $NEW_VERSION est déjà déployée. Fin du script (idempotence)."
    exit 0
fi

# 2. Pull de la nouvelle image
GHCR_USER=$(grep GHCR_USER $ENV_FILE | cut -d '=' -f2)
IMAGE="ghcr.io/$GHCR_USER/todo-api"
log "Pull de l'image $IMAGE:$NEW_VERSION..."
if ! docker pull "$IMAGE:$NEW_VERSION"; then
     log "Erreur: Impossible de télécharger l'image. Annulation."
     exit 1
fi

# 3. Sauvegarde de la base de données
log "Sauvegarde de la base SQLite..."
docker run --rm -v todo-stack_todo-data:/data -v "$BACKUP_DIR:/backup" alpine cp /data/todos.db "/backup/todos-${TIMESTAMP}.db"

# 4. Mise à jour du .env
log "Mise à jour du fichier .env..."
sed -i "s/APP_VERSION=$OLD_VERSION/APP_VERSION=$NEW_VERSION/" $ENV_FILE

# 5. Redémarrage du service app uniquement
log "Redémarrage du service app..."
docker compose up -d --no-deps app

# 6. Smoke test
log "Lancement du smoke test..."
sleep 5 # Laisser le temps au conteneur de démarrer
MAX_RETRIES=6
SUCCESS=0

for i in $(seq 1 $MAX_RETRIES); do
    if curl -s http://localhost/health | grep -q '"status":"ok"'; then
        log "Smoke test RÉUSSI !"
        SUCCESS=1
        break
    fi
    log "Tentative $i/$MAX_RETRIES échouée. Attente 5s..."
    sleep 5
done

# 7. Rollback automatique si échec
if [ $SUCCESS -eq 0 ]; then
    log " ÉCHEC DU SMOKE TEST. DÉCLENCHEMENT DU ROLLBACK ! "

    # Restauration .env
    sed -i "s/APP_VERSION=$NEW_VERSION/APP_VERSION=$OLD_VERSION/" $ENV_FILE

    # Restauration DB
    log "Restauration de la base de données..."
    docker run --rm -v todo-stack_todo-data:/data -v "$BACKUP_DIR:/backup" alpine cp "/backup/todos-${TIMESTAMP}.db" /data/todos.db

    # Redémarrage ancienne version
    log "Redémarrage de l'ancienne version ($OLD_VERSION)..."
    docker compose up -d --no-deps app

    log "Rollback terminé. L'application est revenue à la version $OLD_VERSION."
    exit 1
fi

log "=== Déploiement terminé avec succès ==="