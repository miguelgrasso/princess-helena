# syntax=docker/dockerfile:1.7

# ============================================================================
# Stage 1 — build: valida el artefacto y lo precomprime.
# Misma base que runtime: un solo digest que seguir y actualizar.
# ============================================================================
FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:adf5042a17f4ecdd200c595fa9ffd1be37efb18f89a830bd1a00e4ab4d59d42c AS build

# La base corre como uid 101; para crear /build hace falta root.
# Da igual: este stage no se publica.
USER root
WORKDIR /build
COPY app/index.html ./index.html

# Gate de build: si el juego está vacío o le falta el canvas, la imagen no se
# construye. Barato, y evita publicar un artefacto roto por un mal copy.
# mtime fijo en ambos archivos: el mismo index.html produce siempre la misma
# capa. (La imagen completa NO es reproducible mientras exista el apk upgrade
# del stage 2.) nginx no usa este mtime: ETag y Last-Modified están apagados.
RUN set -eux; \
    test -s index.html; \
    grep -q '<canvas' index.html; \
    gzip -9 -k index.html; \
    touch -d @0 index.html index.html.gz

# ============================================================================
# Stage 2 — runtime: nginx unprivileged (ya corre como uid 101, sin root).
# Tag + digest: el tag es para humanos, el digest garantiza los bytes exactos.
# Rama stable de nginx. Para actualizar, cambiar AMBOS FROM (idealmente vía
# PR automático de Dependabot/Renovate).
# ============================================================================
FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:adf5042a17f4ecdd200c595fa9ffd1be37efb18f89a830bd1a00e4ab4d59d42c AS runtime

# Metadatos OCI: Trivy/Syft y los escáneres del registry los leen.
LABEL org.opencontainers.image.title="princess-helena" \
      org.opencontainers.image.description="Juego de plataformas 2D en HTML5 Canvas" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/miguelgrasso/princess-helena"

# Parches de Alpine (openssl, musl, busybox) entre bumps del digest.
# NO actualiza nginx: ese paquete viene del repo de nginx.org, que no queda
# configurado en la imagen. nginx sólo sube cambiando el FROM.
# NO quitar aunque exista Dependabot: no está confirmado que proponga PRs
# cuando nginx republica el MISMO tag con digest nuevo (rebuild por parches
# de Alpine). Quitar sólo después de ver llegar un PR que cambie únicamente
# el digest. Si se quita antes, la imagen queda sin parches y nadie se entera
# hasta que Trivy falle en CI.
USER root
RUN apk upgrade --no-cache \
 && rm -f /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*.html

COPY --chown=root:root --chmod=0644 nginx/nginx.conf   /etc/nginx/nginx.conf
COPY --chown=root:root --chmod=0644 nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build --chown=root:root --chmod=0444 /build/index.html    /usr/share/nginx/html/index.html
COPY --from=build --chown=root:root --chmod=0444 /build/index.html.gz /usr/share/nginx/html/index.html.gz

# El contenido es root:root y sólo lectura: el proceso nginx (uid 101) puede
# leerlo pero no modificarlo. Ojo: root sí podría, por eso importa que el
# proceso NO sea root. Número y no nombre: runAsNonRoot de k8s lo valida sin
# abrir la imagen. Requiere readOnlyRootFilesystem + emptyDir en /tmp desde k8s.
USER 101

EXPOSE 8080

# Sólo aplica en Docker/Compose: Kubernetes lo ignora y usa sus probes.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

# Redundante con la base, pero explícito: SIGQUIT = apagado ordenado en nginx
# (termina las respuestas en curso). SIGTERM las cortaría.
STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
