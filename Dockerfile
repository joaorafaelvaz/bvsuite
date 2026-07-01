# syntax=docker/dockerfile:1.7
# VIP Suite - Dockerfile multi-stage para VPS
# Build: docker compose build
# Run:  docker compose up -d

# ─── Stage 1: Build ───────────────────────────────────────────────────────────
FROM node:22-slim AS builder

WORKDIR /app

# Dependências de build para módulos nativos (sharp, canvas, tfjs-node, ffmpeg-static)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copiar manifests e patches primeiro (cache de camadas)
COPY package.json pnpm-lock.yaml .npmrc ./
COPY patches ./patches

# Instalar pnpm na versão pinada e dependências
RUN npm install -g pnpm@10.4.1 \
    && pnpm install --frozen-lockfile

# Copiar código fonte
COPY . .

# Build: vite (client → dist/public) + esbuild (server → dist/index.js) + ensure-ffmpeg
RUN pnpm run build

# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM node:22-slim AS runtime

WORKDIR /app

ENV NODE_ENV=production

# Dependências mínimas de runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

# Usuário não-root
RUN groupadd -g 1001 -r nodejs \
    && useradd -r -u 1001 -g nodejs -m -d /app nodejs

# pnpm para reinstalar deps de produção
RUN npm install -g pnpm@10.4.1

# Copiar manifests e instalar TODAS as deps (sharp/tfjs/canvas/ffmpeg precisam de bins nativos)
COPY package.json pnpm-lock.yaml .npmrc ./
COPY patches ./patches
RUN pnpm install --frozen-lockfile --prod=false

# Copiar artefatos de build
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/drizzle ./drizzle
COPY --from=builder /app/client/public/models ./client/public/models

# Diretório de logs
RUN mkdir -p /var/log/vip-suite && chown -R nodejs:nodejs /var/log/vip-suite /app

USER nodejs

EXPOSE 3098

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -q -O- http://127.0.0.1:${PORT:-3098}/ > /dev/null 2>&1 || exit 1

CMD ["node", "dist/index.js"]