#!/usr/bin/env bash
set -euo pipefail

# Experimental restore script.
# Not yet tested on a fresh server.
# Test on a disposable VPS/VM before production use.
#
# Restores a Zyna server backup into /opt/zyna.
# The backup directory must be unpacked first.
#
# Backups may contain sensitive data:
# .env, Synapse signing keys, APNS keys, and service secrets.
# Never commit generated backup archives to git.

APP_DIR="/opt/zyna"

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 /path/to/unpacked_backup_dir"
  echo "Example: $0 /opt/zyna/restore/zyna_YYYY-MM-DD_HH-MM-SS"
  exit 1
fi

BACKUP_DIR="$1"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Backup dir not found: $BACKUP_DIR"
  exit 1
fi

required_files=(
  "$BACKUP_DIR/synapse.dump"
  "$BACKUP_DIR/config/docker-compose.yml"
  "$BACKUP_DIR/config/.env"
  "$BACKUP_DIR/config/Caddyfile"
  "$BACKUP_DIR/config/turnserver.conf"
  "$BACKUP_DIR/synapse/homeserver.yaml"
)

for f in "${required_files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "Required file missing: $f"
    exit 1
  fi
done

echo "==> Restoring Zyna server from:"
echo "$BACKUP_DIR"
echo

read -r -p "This may overwrite files in $APP_DIR. Continue? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Aborted."
  exit 1
fi

cd "$APP_DIR"

echo "==> Stopping existing stack if present..."
docker compose down || true

echo "==> Creating directories..."
mkdir -p \
  "$APP_DIR/caddy/data" \
  "$APP_DIR/caddy/config" \
  "$APP_DIR/coturn" \
  "$APP_DIR/synapse/data" \
  "$APP_DIR/postgres/data" \
  "$APP_DIR/secrets" \
  "$APP_DIR/backups" \
  "$APP_DIR/scripts"

echo "==> Restoring compose and config files..."
cp "$BACKUP_DIR/config/docker-compose.yml" "$APP_DIR/docker-compose.yml"
cp "$BACKUP_DIR/config/.env" "$APP_DIR/.env"
cp "$BACKUP_DIR/config/Caddyfile" "$APP_DIR/caddy/Caddyfile"
cp "$BACKUP_DIR/config/turnserver.conf" "$APP_DIR/coturn/turnserver.conf"

echo "==> Restoring Go services..."
rm -rf "$APP_DIR/zyna-presence" "$APP_DIR/zyna-push"

if [ -d "$BACKUP_DIR/services/zyna-presence" ]; then
  cp -a "$BACKUP_DIR/services/zyna-presence" "$APP_DIR/zyna-presence"
fi

if [ -d "$BACKUP_DIR/services/zyna-push" ]; then
  cp -a "$BACKUP_DIR/services/zyna-push" "$APP_DIR/zyna-push"
fi

echo "==> Restoring secrets..."
if [ -d "$BACKUP_DIR/secrets" ]; then
  rsync -a "$BACKUP_DIR/secrets/" "$APP_DIR/secrets/"
fi

echo "==> Restoring Synapse config, signing key, and media_store..."
cp "$BACKUP_DIR/synapse/homeserver.yaml" "$APP_DIR/synapse/data/homeserver.yaml"

if ls "$BACKUP_DIR/synapse/"*.signing.key >/dev/null 2>&1; then
  cp "$BACKUP_DIR/synapse/"*.signing.key "$APP_DIR/synapse/data/"
fi

if ls "$BACKUP_DIR/synapse/"*.log.config >/dev/null 2>&1; then
  cp "$BACKUP_DIR/synapse/"*.log.config "$APP_DIR/synapse/data/"
fi

rm -rf "$APP_DIR/synapse/data/media_store"
mkdir -p "$APP_DIR/synapse/data/media_store"

if [ -d "$BACKUP_DIR/synapse/media_store" ]; then
  rsync -a "$BACKUP_DIR/synapse/media_store/" "$APP_DIR/synapse/data/media_store/"
fi

echo "==> Restoring presence data..."
docker volume create zyna_presence-data >/dev/null

if [ -d "$BACKUP_DIR/presence" ]; then
  docker run --rm \
    -v zyna_presence-data:/data \
    -v "$BACKUP_DIR/presence:/backup:ro" \
    alpine sh -c 'cp -a /backup/. /data/ 2>/dev/null || true'
fi

echo "==> Fixing file permissions..."
sudo chown -R "$(id -u):$(id -g)" "$APP_DIR"
chmod 600 "$APP_DIR/.env" || true
chmod 600 "$APP_DIR"/secrets/zyna-push/*.p8 2>/dev/null || true

# Synapse official Docker image uses UID 991 in this setup.
sudo chown -R 991:991 "$APP_DIR/synapse/data"
sudo chmod 644 "$APP_DIR/synapse/data/homeserver.yaml" || true
sudo chmod 600 "$APP_DIR/synapse/data/"*.signing.key 2>/dev/null || true

echo "==> Starting PostgreSQL only..."
docker compose up -d postgres

echo "==> Waiting for PostgreSQL..."
for i in {1..60}; do
  if docker compose exec -T postgres pg_isready -U synapse -d synapse >/dev/null 2>&1; then
    echo "PostgreSQL is ready."
    break
  fi

  if [ "$i" = "60" ]; then
    echo "PostgreSQL did not become ready in time."
    docker compose logs --tail=100 postgres
    exit 1
  fi

  sleep 1
done

echo "==> Restoring PostgreSQL dump..."
cat "$BACKUP_DIR/synapse.dump" | docker compose exec -T postgres pg_restore \
  -U synapse \
  -d synapse \
  --clean \
  --if-exists \
  --no-owner

echo "==> Starting full stack..."
docker compose up -d --build

echo
echo "==> Restore complete."
echo

# Load non-sensitive endpoint variables for convenience.
# shellcheck disable=SC1091
set -a
source "$APP_DIR/.env"
set +a

MSG_DOMAIN="${MSG_DOMAIN:-msg.example.com}"
PUSH_DEV_DOMAIN="${PUSH_DEV_DOMAIN:-push-dev.example.com}"
PUSH_PROD_DOMAIN="${PUSH_PROD_DOMAIN:-push.example.com}"

echo "Run checks:"
echo "  docker compose ps"
echo "  curl https://${MSG_DOMAIN}/_matrix/client/versions"
echo "  curl -i -X POST https://${MSG_DOMAIN}/presence/auth"
echo "  curl -i -X POST https://${PUSH_DEV_DOMAIN}/_matrix/push/v1/notify -H 'Content-Type: application/json' --data '{}'"
echo "  curl -i -X POST https://${PUSH_PROD_DOMAIN}/_matrix/push/v1/notify -H 'Content-Type: application/json' --data '{}'"