#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# VIP Suite — Inicialização do VPS (Ubuntu 22.04+)
#
# Instala Docker, Docker Compose, cria estrutura de diretórios, configura
# firewall e cron de backup. Roda UMA vez no VPS como root (ou sudoer).
#
#   sudo bash deployment/init-vps.sh
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()      { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success()  { echo -e "${GREEN}✓${NC} $1"; }
warn()     { echo -e "${YELLOW}⚠${NC} $1"; }
die()      { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# Detecta diretório da aplicação (um nível acima de deployment/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

[[ "$EUID" -eq 0 ]] || die "Rode com sudo: sudo bash deployment/init-vps.sh"

log "Iniciando inicialização do VPS..."
log "Diretório da aplicação: $APP_DIR"

# ─── 1. Atualizar sistema ────────────────────────────────────────────────────
log "Atualizando pacotes do sistema..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git htop net-tools ufw fail2ban ca-certificates gnupg >/dev/null
success "Sistema atualizado"

# ─── 2. Docker ──────────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
    success "Docker já instalado: $(docker --version)"
else
    log "Instalando Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    success "Docker instalado"
fi

# docker compose v2 (plugin) — preferido; fallback para v1
if docker compose version >/dev/null 2>&1; then
    success "Docker Compose v2 disponível"
elif ! command -v docker-compose >/dev/null 2>&1; then
    log "Instalando docker-compose v1 (fallback)..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    success "docker-compose v1 instalado"
fi

# ─── 3. Estrutura de diretórios ──────────────────────────────────────────────
log "Criando diretórios auxiliares..."
mkdir -p "$APP_DIR"/{logs,data,backups,nginx/conf.d}
# Permissões para o usuário do container (uid 1001)
chown -R 1001:1001 "$APP_DIR"/logs "$APP_DIR"/data 2>/dev/null || true
success "Diretórios criados"

# ─── 4. Firewall ──────────────────────────────────────────────────────────────
log "Configurando firewall (ufw)..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   # SSH
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS
ufw --force enable >/dev/null
success "Firewall ativo (22, 80, 443)"

# ─── 5. Arquivo .env ──────────────────────────────────────────────────────────
if [[ ! -f "$APP_DIR/.env" ]]; then
    log "Criando .env a partir do .env.example..."
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    # Gerar JWT_SECRET aleatório
    JWT=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    sed -i "s|JWT_SECRET=.*|JWT_SECRET=$JWT|" "$APP_DIR/.env"
    warn ".env criado — EDITE com credenciais reais: nano $APP_DIR/.env"
else
    success ".env já existe"
fi

# ─── 6. Cron de backup diário (02:00) ────────────────────────────────────────
BACKUP_SCRIPT="$APP_DIR/deployment/backup.sh"
CRON_LINE="0 2 * * * $BACKUP_SCRIPT >> $APP_DIR/logs/backup.log 2>&1"
if [[ -f "$BACKUP_SCRIPT" ]]; then
    chmod +x "$BACKUP_SCRIPT"
    ( crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" ; echo "$CRON_LINE" ) | crontab -
    success "Backup automático agendado (02:00 diário)"
fi

# ─── 7. Resumo ────────────────────────────────────────────────────────────────
echo
log "════════════════════════════════════════════════════════════"
success "VPS pronto para deploy!"
log "════════════════════════════════════════════════════════════"
echo
echo "Próximos passos:"
echo "  1. Edite o .env:        nano $APP_DIR/.env"
echo "  2. Edite o nginx conf:  nano $APP_DIR/nginx/conf.d/bvsuite.conf"
echo "     (substitua 'bvsuite' pelo seu domínio no path do certificado)"
echo "  3. Faça o deploy:       bash deployment/deploy.sh"
echo "  4. Emita SSL:           bash deployment/deploy.sh ssl"
echo
echo "Docker:  $(docker --version)"
echo "Compose: $(docker compose version 2>/dev/null || docker-compose --version)"
echo