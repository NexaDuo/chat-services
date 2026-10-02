# syntax=docker/dockerfile:1.7
# =============================================================================
# NexaDuo middleware — Chatwoot ⇄ Dify adapter
# Multi-stage build: deps → build → runtime (non-root, dumb-init as PID 1)
# =============================================================================

# ---------- Stage 1: deps ----------------------------------------------------
FROM node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then npm ci; else npm install; fi

# ---------- Stage 2: build ---------------------------------------------------
FROM node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json tsconfig.json vite.config.ts ./
COPY src ./src
COPY admin-ui ./admin-ui
RUN npm run build

# ---------- Stage 3: prod deps only -----------------------------------------
FROM node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS prod-deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN --mount=type=cache,target=/root/.npm \
    if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

# ---------- Stage 4: runtime -------------------------------------------------
FROM node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS runtime
RUN apk add --no-cache dumb-init wget
ENV NODE_ENV=production
WORKDIR /app

# Non-root user
RUN addgroup -S app && adduser -S -G app app

COPY --from=prod-deps --chown=app:app /app/node_modules ./node_modules
COPY --from=build     --chown=app:app /app/dist         ./dist
COPY --chown=app:app package.json ./

USER app
EXPOSE 4000
ENTRYPOINT ["dumb-init", "--"]
# Preload OTel SDK before the app (ESM --import). Tracing is a safe no-op when
# OTEL_SDK_DISABLED=true or the collector is unreachable.
CMD ["node", "--import", "./dist/telemetry.js", "dist/index.js"]
