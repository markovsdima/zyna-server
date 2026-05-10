#!/usr/bin/env bash
set -euo pipefail

# Backups produced by this script contain sensitive data:
# .env, Synapse signing keys, APNS keys, and service secrets.
# Never commit generated backup archives to git.

APP_DIR="/opt/zyna"
BACKUP_ROOT="$APP_DIR/backups"
TS="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$BACKUP_ROOT/zyna_$TS"
ARCHIVE="$BACKUP_ROOT/zyna_$TS.tar.gz"

cd "$APP_DIR"

mkdir -p "$BACKUP_DIR"

echo "==> Backing up PostgreSQL..."
docker compose exec -T postgres pg_dump -U synapse -Fc synapse > "$BACKUP_DIR/synapse.dump"

echo "==> Backing up Synapse config and keys..."
mkdir -p "$BACKUP_DIR/synapse"
sudo cp "$APP_DIR/synapse/data/homeserver.yaml" "$BACKUP_DIR/synapse/"
sudo cp "$APP_DIR/synapse/data/"*.signing.key "$BACKUP_DIR/synapse/" 2>/dev/null || true
sudo cp "$APP_DIR/synapse/data/"*.log.config "$BACKUP_DIR/synapse/" 2>/dev/null || true

echo "==> Backing up media_store..."
mkdir -p "$BACKUP_DIR/synapse/media_store"
sudo rsync -a "$APP_DIR/synapse/data/media_store/" "$BACKUP_DIR/synapse/media_store/" 2>/dev/null || true

echo "==> Backing up service configs..."
mkdir -p "$BACKUP_DIR/config"
cp "$APP_DIR/docker-compose.yml" "$BACKUP_DIR/config/"
cp "$APP_DIR/.env" "$BACKUP_DIR/config/" 2>/dev/null || true
cp "$APP_DIR/caddy/Caddyfile" "$BACKUP_DIR/config/" 2>/dev/null || true
cp "$APP_DIR/coturn/turnserver.conf" "$BACKUP_DIR/config/" 2>/dev/null || true

echo "==> Backing up Go services..."
mkdir -p "$BACKUP_DIR/services"

rsync -a \
  --exclude '.git' \
  --exclude '.claude' \
  --exclude 'bin' \
  --exclude 'server' \
  --exclude 'last_seen.json' \
  --exclude 'last_seen.json.tmp' \
  "$APP_DIR/zyna-presence/" "$BACKUP_DIR/services/zyna-presence/" 2>/dev/null || true

rsync -a \
  --exclude '.git' \
  --exclude '.claude' \
  --exclude 'bin' \
  --exclude 'server' \
  --exclude 'last_seen.json' \
  --exclude 'last_seen.json.tmp' \
  "$APP_DIR/zyna-push/" "$BACKUP_DIR/services/zyna-push/" 2>/dev/null || true

echo "==> Backing up secrets..."
mkdir -p "$BACKUP_DIR/secrets"
sudo rsync -a "$APP_DIR/secrets/" "$BACKUP_DIR/secrets/" 2>/dev/null || true

echo "==> Backing up presence data..."
mkdir -p "$BACKUP_DIR/presence"
docker run --rm \
  -v zyna_presence-data:/data:ro \
  -v "$BACKUP_DIR/presence:/backup" \
  alpine sh -c 'cp -a /data/. /backup/ 2>/dev/null || true'

echo "==> Fixing backup file ownership..."
sudo chown -R "$(id -u):$(id -g)" "$BACKUP_DIR"

echo "==> Creating archive..."
tar -czf "$ARCHIVE" -C "$BACKUP_ROOT" "zyna_$TS"

echo "==> Cleaning temporary backup directory..."
rm -rf "$BACKUP_DIR"

echo "==> Backup created:"
echo "$ARCHIVE"

echo "==> Archive size:"
du -h "$ARCHIVE"
