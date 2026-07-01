#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# VIP Suite — Gerenciamento do VPS
#
#   bash deployment/manage.sh start     iniciar containers
#   bash deployment/manage.sh stop      parar containers
#   bash deployment/manage.sh restart   reiniciar
#   bash deployment/manage.sh logs       logs em tempo real
#   bash deployment/manage.sh status     status + health
#   bash deployment/manage.sh shell      shell dentro do container app
#   bash deployment/manage.sh db         shell MySQL
#   bash deployment/manage.sh backup     backup imediato
#   bash deployment/manage.sh restore <arquivo.sql.gz>
#   bash deployment/manage.sh cleanup    remover containers + imagens antigas
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
cd "$APP_DIR"

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "✗ docker compose não encontrado" >&2; exit 1
fi

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

case "${1:-help}" in
    start)
        $DC up -d
        echo "✓ Containers iniciados"
        ;;
    stop)
        $DC down
        echo "✓ Containers parados"
        ;;
    restart)
        $DC restart
        echo "✓ Containers reiniciados"
        ;;
    logs)
        $DC logs -f app
        ;;
    status)
        $DC ps
        echo
        if curl -sf http://127.0.0.1:3098/health >/dev/null 2>&1; then
            echo "✓ App: OK"
        else
            echo "⚠ App: indisponível"
        fi
        docker exec bvsuite-mysql mysqladmin ping -h localhost -u root -p"${DB_ROOT_PASSWORD:-}" 2>/dev/null | grep -q alive \
            && echo "✓ MySQL: OK" || echo "⚠ MySQL: indisponível"
        docker exec bvsuite-redis redis-cli ping 2>/dev/null | grep -q PONG \
            && echo "✓ Redis: OK" || echo "⚠ Redis: indisponível"
        ;;
    shell)
        $DC exec app /bin/sh
        ;;
    db)
        $DC exec mysql mysql -u"${DB_USER:-bvsuite}" -p"${DB_PASSWORD:?}" "${DB_NAME:-bvsuite}"
        ;;
    backup)
        bash deployment/backup.sh
        ;;
    restore)
        FILE="${2:-}"
        [[ -n "$FILE" && -f "$FILE" ]] || { echo "Uso: manage.sh restore <arquivo.sql.gz>"; exit 1; }
        echo "Restaurando $FILE..."
        gunzip -c "$FILE" | docker exec -i bvsuite-mysql mysql -u"${DB_USER:-bvsuite}" -p"${DB_PASSWORD:?}" "${DB_NAME:-bvsuite}"
        echo "✓ Restaurado"
        ;;
    cleanup)
        $DC down -v --rmi local
        echo "✓ Containers, volumes locais e imagens removidos"
        ;;
    help|*)
        echo "Uso: bash deployment/manage.sh <start|stop|restart|logs|status|shell|db|backup|restore|cleanup>"
        ;;
esac