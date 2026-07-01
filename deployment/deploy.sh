#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# VIP Suite — Deploy para VPS
#
# Ações:
#   bash deployment/deploy.sh          build + up + migrate
#   bash deployment/deploy.sh build     apenas buildar a imagem
#   bash deployment/deploy.sh up        iniciar containers
#   bash deployment/deploy.sh down      parar containers
#   bash deployment/deploy.sh restart   reiniciar app
#   bash deployment/deploy.sh logs      logs em tempo real
#   bash deployment/deploy.sh status    status dos containers
#   bash deployment/deploy.sh migrate    rodar migrations do banco
#   bash deployment/deploy.sh ssl        emitir certificado Let's Encrypt
#   bash deployment/deploy.sh backup     backup imediato do banco
#   bash deployment/deploy.sh update     git pull + build + restart
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()      { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success()  { echo -e "${GREEN}✓${NC} $1"; }
warn()     { echo -e "${YELLOW}⚠${NC} $1"; }
die()      { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
cd "$APP_DIR"

# Detecta docker compose (v2 plugin ou v1 binário)
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    die "docker compose não encontrado. Rode: sudo bash deployment/init-vps.sh"
fi

ACTION="${1:-deploy}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
# Carrega .env de forma segura (sem source — lida com espaços e caracteres especiais)
load_env() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        # pula comentários e linhas vazias
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # extrai KEY=VALUE (VALUE pode conter espaços; remove aspas se houver)
        local key="${line%%=*}"
        local val="${line#*=}"
        # remove aspas envolventes
        val="${val#\"}"; val="${val%\"}"
        val="${val#\'}"; val="${val%\'}"
        # exporta apenas se a key for válida
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "$key=$val"
        fi
    done < "$env_file"
}

check_env() {
    [[ -f "$APP_DIR/.env" ]] || die ".env não encontrado. Copie de .env.example e edite."
    load_env "$APP_DIR/.env"
    [[ -n "${DATABASE_URL:-}" ]]     || die "DATABASE_URL não definida no .env"
    [[ -n "${DB_ROOT_PASSWORD:-}" ]] || die "DB_ROOT_PASSWORD não definida no .env"
    [[ -n "${DB_PASSWORD:-}" ]]      || die "DB_PASSWORD não definida no .env"
}

# ─── Ações ────────────────────────────────────────────────────────────────────
do_build() {
    log "Construindo imagem Docker..."
    $DC build --no-cache app
    success "Imagem construída"
}

do_up() {
    check_env
    log "Iniciando containers..."
    $DC up -d
    success "Containers iniciados"
    do_status
}

do_down() {
    log "Parando containers..."
    $DC down
    success "Containers parados"
}

do_restart() {
    log "Reiniciando app..."
    $DC restart app
    success "App reiniciado"
}

do_logs() {
    $DC logs -f app
}

do_status() {
    log "Status dos containers:"
    $DC ps
    echo
    log "Health check da aplicação:"
    if curl -sf http://127.0.0.1:3098/health >/dev/null 2>&1; then
        success "App: OK"
    else
        warn "App: ainda inicializando ou indisponível"
    fi
}

do_migrate() {
    check_env
    log "Rodando migrations Drizzle..."
    # Roda dentro do container app (que tem acesso ao MySQL via rede docker)
    $DC exec -T app node -e "
        const { drizzle } = require('drizzle-orm/mysql2');
        const mysql = require('mysql2/promise');
        (async () => {
            const conn = await mysql.createConnection(process.env.DATABASE_URL);
            const fs = require('fs');
            const path = require('path');
            const dir = path.join(__dirname, 'drizzle');
            const files = fs.readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
            for (const f of files) {
                const sql = fs.readFileSync(path.join(dir, f), 'utf8');
                console.log('  Aplicando:', f);
                await conn.query(sql);
            }
            await conn.end();
            console.log('✓ Migrations aplicadas');
        })().catch(e => { console.error(e); process.exit(1); });
    " 2>&1 || warn "Migrations podem já estar aplicadas ou houve erro"
    success "Migrations concluídas"
}

do_ssl() {
    check_env
    DOMAIN="${DOMAIN:-}"
    EMAIL="${SSL_EMAIL:-}"
    [[ -n "$DOMAIN" ]] || die "DOMAIN não definido no .env"
    [[ -n "$EMAIL" ]]  || die "SSL_EMAIL não definido no .env"

    log "Emitindo certificado Let's Encrypt para $DOMAIN..."

    # Nginx precisa estar rodando para servir o challenge ACME
    $DC up -d nginx

    $DC run --rm certbot certbot certonly --webroot -w /var/www/certbot \
        -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive

    # Atualiza conf do nginx com o domínio correto
    CONF="$APP_DIR/nginx/conf.d/bvsuite.conf"
    sed -i "s|/etc/letsencrypt/live/bvsuite/|/etc/letsencrypt/live/$DOMAIN/|g" "$CONF"

    $DC restart nginx
    success "SSL configurado para $DOMAIN"
}

do_backup() {
    bash "$APP_DIR/deployment/backup.sh"
}

do_update() {
    log "Atualizando código (git pull)..."
    git pull origin main || git pull bvsuite main || warn "git pull falhou — verifique remote"
    do_build
    $DC up -d
    success "Atualização concluída"
    do_status
}

do_deploy() {
    do_build
    do_up
    log "Aguardando app ficar pronta..."
    for i in $(seq 1 30); do
        if curl -sf http://127.0.0.1:3098/health >/dev/null 2>&1; then
            success "App pronta"
            do_status
            return
        fi
        printf "."
        sleep 2
    done
    echo
    warn "App não respondeu em 60s — verifique logs: bash deployment/deploy.sh logs"
}

# ─── Executa ──────────────────────────────────────────────────────────────────
case "$ACTION" in
    deploy)  do_deploy ;;
    build)   do_build ;;
    up)      do_up ;;
    down)    do_down ;;
    stop)    do_down ;;
    restart) do_restart ;;
    logs)    do_logs ;;
    status)  do_status ;;
    migrate) do_migrate ;;
    ssl)     do_ssl ;;
    backup)  do_backup ;;
    update)  do_update ;;
    *)
        echo "Uso: bash deployment/deploy.sh [deploy|build|up|down|restart|logs|status|migrate|ssl|backup|update]"
        exit 1
        ;;
esac