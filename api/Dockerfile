# Imagen de la API. Build: docker build -f api/Dockerfile api/   (requiere BuildKit)

FROM node:24.21.0-trixie-slim@sha256:db3ae80f5d8df06e04dabdf7b44cbf008d32de168205fa0294444aabbc08c590 AS build
WORKDIR /app
COPY package.json package-lock.json ./
# --ignore-scripts: ninguna dependencia necesita install scripts, y uno comprometido no corre en el build.
RUN npm ci --omit=dev --ignore-scripts
COPY src/ ./src/
COPY migrations/ ./migrations/
# Falla si el árbol de dependencias o la sintaxis están rotos (node --check revisa un solo
# archivo por invocación). Deja el código de sólo lectura: desde WSL llega con modo 777.
RUN set -eu; \
    npm ls --omit=dev --all > /dev/null; \
    for f in $(find src -name '*.js'); do node --check "$f"; done; \
    chmod -R a=r,a+X package.json src migrations

# Distroless: sin shell ni gestor de paquetes. Los parches del SO y de Node llegan sólo
# cambiando el digest, y Trivy no ve la versión del binario de node: vigilarla en CI.
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:bb6b03d81066993293a10feda7250e8e1cc034035fe9b61cfceededa7c8bf04d

LABEL org.opencontainers.image.title="helena-api" \
      org.opencontainers.image.source="https://github.com/miguelgrasso/princess-helena" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production

# La base ya es uid 65532: root sólo para que /app sea de root y el proceso no pueda escribir ahí.
USER 0:0
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/src ./src
COPY --from=build /app/migrations ./migrations
USER 65532:65532

EXPOSE 3000
# Sin wget/curl en distroless: el healthcheck usa el propio node. Kubernetes lo ignora.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:'+Number.parseInt(process.env.PORT||'3000',10)+'/healthz',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]

# node como PID 1 (npm start no reenvía señales). Migraciones: misma imagen con args ["src/migrate.js"].
STOPSIGNAL SIGTERM
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["src/server.js"]
