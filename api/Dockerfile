# Imagen de la API del leaderboard. Contexto de build: api/
#   docker build -f api/Dockerfile api/
# Sin "# syntax=": se usa el frontend integrado de BuildKit.
# ============================================================================
# Stage 1 — build: instala dependencias de producción desde el lockfile.
# Debian 13 (trixie) igual que el runtime distroless: misma glibc. Hoy no hay
# módulos nativos (pg es JS puro, sin pg-native), pero si alguno llega, el
# binario compilado aquí funciona en el runtime sin sorpresas de musl.
# Node 24 = LTS "Krypton" con soporte vigente. 26 aún no es LTS.
# ============================================================================
FROM node:24.21.0-trixie-slim@sha256:db3ae80f5d8df06e04dabdf7b44cbf008d32de168205fa0294444aabbc08c590 AS build

WORKDIR /app
COPY package.json package-lock.json ./

# npm ci falla si package.json y el lockfile no coinciden: nada se resuelve
# "a ojo". --ignore-scripts: ninguna dependencia actual tiene install scripts
# (hasInstallScript no aparece en el lock) y así un paquete comprometido no
# ejecuta código durante el build. Si un día entra un módulo nativo, quitarlo.
RUN npm ci --omit=dev --ignore-scripts \
 && npm cache clean --force

COPY src/ ./src/
COPY migrations/ ./migrations/

# Gate de build (parte 1): árbol de dependencias íntegro y sintaxis válida en
# cada archivo. El código propio se normaliza a sólo lectura porque el
# contexto puede llegar con modo 777 (checkout en Windows/WSL). node_modules
# no se toca (un chmod -R ahí tarda minutos por copy-up); en su lugar se exige
# que nada sea escribible por otros. El proceso final (uid 65532) sólo lee.
RUN set -eux; \
    npm ls --omit=dev --all > /dev/null; \
    for f in src/*.js src/routes/*.js; do node --check "$f"; done; \
    test -n "$(ls migrations/*.sql)"; \
    find package.json package-lock.json src migrations -type d -exec chmod 0555 {} +; \
    find package.json package-lock.json src migrations -type f -exec chmod 0444 {} +; \
    test -z "$(find node_modules ! -type l -perm -o+w -print -quit)"

# ============================================================================
# Stage 2 — runtime: distroless Node 24 sobre Debian 13, variante nonroot.
# Sin shell, sin npm, sin gestor de paquetes: Trivy HIGH/CRITICAL en 0 el
# 2026-09-15 (node:24-alpine tenía ese día 2 HIGH en OpenSSL y además carga
# npm/yarn/corepack que la app no usa).
# Distroless no publica tags con versión de Node: el digest es el único pin
# real. Node 24.21.0 verificado dentro de este digest.
# Tampoco hay apk/apt upgrade posible: los parches del SO llegan SÓLO
# cambiando el digest. Si nadie lo actualiza, la imagen envejece con CVEs.
# ============================================================================
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:bb6b03d81066993293a10feda7250e8e1cc034035fe9b61cfceededa7c8bf04d AS runtime

LABEL org.opencontainers.image.title="helena-api" \
      org.opencontainers.image.description="API del leaderboard global de Princess Helena (Fastify + Postgres)" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/miguelgrasso/princess-helena"

ENV NODE_ENV=production

# La base ya trae USER 65532: sin esto WORKDIR crea /app con dueño 65532 y el
# proceso podría escribir ahí (verificado). root sólo en build, sin shell.
USER 0:0
WORKDIR /app
# Sólo lo que corre: node_modules, código y migraciones. package.json también
# hace falta: "type": "module" vive ahí y sin él Node trata src/*.js como
# CommonJS y no arranca.
COPY --from=build --chown=0:0 /app/package.json ./package.json
COPY --from=build --chown=0:0 /app/node_modules ./node_modules
COPY --from=build --chown=0:0 /app/src ./src
COPY --from=build --chown=0:0 /app/migrations ./migrations

# Número y no nombre: runAsNonRoot de k8s lo valida sin abrir la imagen.
# (La base ya es 65532; se repite para que no dependa de ella.)
USER 65532:65532

# Gate de build (parte 2), dentro de la imagen final y como uid 65532: el node
# de esta base carga todas las dependencias y todos los módulos de la app.
# Exec form porque no hay shell. DATABASE_URL es un placeholder sin
# credenciales: pg.Pool no conecta hasta la primera query.
RUN ["/nodejs/bin/node", "--input-type=module", "-e", "process.env.DATABASE_URL = 'postgres://gate@127.0.0.1:1/gate'; for (const m of ['fastify', '@fastify/cors', '@fastify/rate-limit', '@prometheus-io/client', 'pg', '/app/src/routes/salud.js', '/app/src/routes/scores.js']) await import(m); process.exit(0);"]

EXPOSE 3000

# Sólo Docker/Compose; Kubernetes lo ignora. Sin wget/curl en distroless: se
# usa el propio node (fetch nativo), nada instalado sólo para esto.
# /healthz no toca la base: una DB caída no marca el contenedor unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]

# La app atiende SIGTERM: app.close() drena y luego cierra el pool.
STOPSIGNAL SIGTERM

# node como PID 1 directo (nunca npm start: no reenvía señales).
# Migraciones con la MISMA imagen cambiando sólo el argumento:
#   docker run ... <imagen> src/migrate.js    (k8s: args: ["src/migrate.js"])
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["src/server.js"]
