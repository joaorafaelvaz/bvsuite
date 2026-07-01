#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# VIP Suite — Backup do banco MySQL (executa no VPS)
#   bash deployment/backup.sh
# Roda dentro do cron diário (02:00) ou manualmente.
# Mantém os últimos 14 backups.
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$APP_DIR/backups"
RETENTION_DAYS=14

mkdir -p "$BACKUP_DIR"

# Carrega .env de forma segura (sem source — lida com espaços e caracteres especiais)
load_env() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local key="${line%%=*}"
        local val="${line#*=}"
        val="${val#\"}"; val="${val%\"}"
        val="${val#\'}"; val="${val%\'}"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "$key=$val"
        fi
    done < "$env_file"
}
load_env "$APP_DIR/.env"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER="bvsuite-mysql"
DB_NAME="${DB_NAME:-bvsuite}"
DB_USER="${DB_USER:-bvsuite}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD não definida no .env}"

FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql.gz"

echo "[$(date +'%F %T')] Iniciando backup..."

# Dump via docker exec, pipe para gzip (não grava .sql em disco)
docker exec "$CONTAINER" mysqldump \
    -u"$DB_USER" -p"$DB_PASSWORD" \
    --single-transaction --quick --routines --triggers \
    "$DB_NAME" 2>/dev/null | gzip > "$FILE"

if [[ -s "$FILE" ]]; then
    SIZE=$(du -h "$FILE" | cut -f1)
    echo "✓ Backup criado: $FILE ($SIZE)"
else
    echo "✗ Backup falhou (arquivo vazio)" >&2
    rm -f "$FILE"
    exit 1
fi

# Limpa backups antigos
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
echo "✓ Backups com mais de $RETENTION_DAYS dias removidos"