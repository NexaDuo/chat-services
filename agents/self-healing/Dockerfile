FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
# Use ci if lockfile exists, otherwise install (more robust)
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi
COPY . .
RUN npm run build

FROM node:20-alpine
# Set environment to production
ENV NODE_ENV=production
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package*.json ./
# Versioned noise-filter rules (issue #131). filters.ts resolves this at
# /app/ignore-rules.json (../ from dist/); it must ship in the runtime image so
# a from-scratch build reproduces the filtering.
COPY --from=builder /app/ignore-rules.json ./ignore-rules.json
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

# Run as non-root user
USER node

# Healthcheck to ensure the process is alive
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD pgrep node || exit 1

# Preload OTel SDK before the app (CommonJS --require). Tracing is a safe no-op
# when OTEL_SDK_DISABLED=true or the collector is unreachable.
CMD ["node", "--require", "./dist/telemetry.js", "dist/index.js"]
