# VIP Suite — Deploy no VPS

Guia completo para deploy da VIP Suite em um VPS Ubuntu 22.04+ com Docker.

## Pré-requisitos

- VPS Ubuntu 22.04+ (recomendado: 4 GB RAM, 2 vCPU, 40 GB SSD)
- Acesso root ou sudo
- Domínio apontando (registro A) para o IP do VPS

## Passo a passo

### 1. Preparar o VPS (uma vez)

```bash
ssh root@seu-vps
git clone https://github.com/joaorafaelvaz/bvsuite.git /opt/bvsuite
cd /opt/bvsuite
sudo bash deployment/init-vps.sh
```

Isso instala Docker, configura firewall (22/80/443), cria diretórios e cron de backup.

### 2. Configurar `.env`

```bash
nano /opt/bvsuite/.env
```

Preencha:

- `DB_ROOT_PASSWORD`, `DB_PASSWORD` — senhas do MySQL (troque as defaults)
- `JWT_SECRET` — já gerado pelo init-vps.sh
- `VITE_APP_ID`, `OAUTH_SERVER_URL`, `VITE_OAUTH_PORTAL_URL` — credenciais Manus OAuth
- `BUILT_IN_FORGE_API_URL`, `BUILT_IN_FORGE_API_KEY` — APIs do Forge (storage/LLM)
- `SSH_TUNNEL_*`, `DB_EXT_*` — se for usar o Data VIP (banco externo `franquia_producao`)
- `DOMAIN`, `SSL_EMAIL` — para emissão do certificado SSL
- `VITE_APP_PUBLIC_URL` — URL pública (ex: https://suite.seudominio.com)

### 3. Configurar Nginx

Edite o `server_name` e path do certificado:

```bash
nano /opt/bvsuite/nginx/conf.d/bvsuite.conf
# Substitua 'bvsuite' pelo seu domínio em:
#   server_name, ssl_certificate, ssl_certificate_key
```

### 4. Deploy

```bash
bash deployment/deploy.sh
```

Isso faz build da imagem Docker, inicia MySQL + Redis + App + Nginx e verifica health.

### 5. Rodar migrations do banco

```bash
bash deployment/deploy.sh migrate
```

### 6. Emitir certificado SSL (Let's Encrypt)

```bash
bash deployment/deploy.sh ssl
```

Após emitir, o Nginx é reiniciado com HTTPS ativo.

### 7. Verificar

```bash
bash deployment/deploy.sh status
curl http://127.0.0.1:3098/health
```

## Comandos disponíveis

| Comando | Ação |
|--------|------|
| `bash deployment/deploy.sh` | Deploy completo (build + up) |
| `bash deployment/deploy.sh build` | Apenas buildar imagem |
| `bash deployment/deploy.sh up` | Iniciar containers |
| `bash deployment/deploy.sh down` | Parar containers |
| `bash deployment/deploy.sh restart` | Reiniciar app |
| `bash deployment/deploy.sh logs` | Logs em tempo real |
| `bash deployment/deploy.sh status` | Status + health check |
| `bash deployment/deploy.sh migrate` | Rodar migrations SQL |
| `bash deployment/deploy.sh ssl` | Emitir certificado SSL |
| `bash deployment/deploy.sh backup` | Backup imediato do banco |
| `bash deployment/deploy.sh update` | git pull + rebuild + restart |
| `bash deployment/manage.sh shell` | Shell dentro do container app |
| `bash deployment/manage.sh db` | Shell MySQL |
| `bash deployment/manage.sh restore <arquivo>` | Restaurar backup |

## Backup automático

O `init-vps.sh` agenda backup diário às 02:00 via cron. Backups ficam em
`/opt/bvsuite/backups/` (formato `bvsuite_YYYYMMDD_HHMMSS.sql.gz`) com retenção
de 14 dias.

## Estrutura de arquivos de deploy

```
.
├── Dockerfile              # Imagem multi-stage (builder + runtime)
├── docker-compose.yml      # MySQL + Redis + App + Nginx + Certbot
├── .dockerignore
├── .env.example            # Template de variáveis
├── nginx/
│   ├── nginx.conf           # Config global do Nginx
│   └── conf.d/
│       └── bvsuite.conf     # Site (HTTPS, proxy, cache, rate limit)
└── deployment/
    ├── init-vps.sh          # Preparar VPS (Docker, firewall, cron)
    ├── deploy.sh            # Deploy/build/up/down/migrate/ssl/backup
    ├── manage.sh            # Start/stop/logs/shell/db/restore/cleanup
    └── backup.sh            # Backup do MySQL (chamado pelo cron)
```

## Variáveis de ambiente

Veja `.env.example` para a lista completa. As essenciais:

| Variável | Descrição |
|----------|-----------|
| `DATABASE_URL` | URI do MySQL local (usado pela app) |
| `DB_ROOT_PASSWORD` | Senha root do MySQL (docker-compose) |
| `DB_USER` / `DB_PASSWORD` / `DB_NAME` | Credenciais do banco da app |
| `JWT_SECRET` | Segredo do JWT (gerado pelo init-vps.sh) |
| `VITE_APP_ID` | App ID do Manus OAuth |
| `BUILT_IN_FORGE_API_URL` / `BUILT_IN_FORGE_API_KEY` | APIs do Forge |
| `SSH_TUNNEL_*` / `DB_EXT_*` | Banco externo do Data VIP (opcional) |
| `DOMAIN` / `SSL_EMAIL` | Emissão SSL Let's Encrypt |

## Portas

| Porta | Serviço | Exposição |
|-------|---------|-----------|
| 3098 | App | Interna (127.0.0.1) |
| 3306 | MySQL | Interna (127.0.0.1) |
| 6379 | Redis | Interna (127.0.0.1) |
| 80 | Nginx HTTP | Pública |
| 443 | Nginx HTTPS | Pública |

## Troubleshooting

**App não responde**: `bash deployment/deploy.sh logs` e verifique se o `.env` está completo.

**MySQL não conecta**: verifique se `DB_PASSWORD` do `.env` bate com o usado pelo container MySQL.

**Data VIP sem dados**: o túnel SSH precisa de `SSH_TUNNEL_*` e `DB_EXT_*` configurados.

**SSL falha**: confirme que o domínio aponta para o VPS (DNS A record) e que a porta 80 está aberta.

**Build falha (sharp/tfjs-node)**: o Dockerfile já instala `python3 make g++`. Se persistir, faça `docker compose build --no-cache app`.