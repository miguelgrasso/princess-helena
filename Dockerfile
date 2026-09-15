# Imagen del juego: nginx sin root sirviendo un único HTML.
# Requiere BuildKit (usa Dockerfile.dockerignore y COPY --chmod).

FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:adf5042a17f4ecdd200c595fa9ffd1be37efb18f89a830bd1a00e4ab4d59d42c AS build
USER root
WORKDIR /build
COPY app/index.html ./
# Falla si el juego llega vacío o roto. mtime fijo: mismo HTML, misma capa.
RUN set -eu; \
    test -s index.html; \
    grep -q '<canvas' index.html; \
    gzip -9 -k index.html; \
    touch -d @0 index.html index.html.gz

FROM nginxinc/nginx-unprivileged:1.30.4-alpine@sha256:adf5042a17f4ecdd200c595fa9ffd1be37efb18f89a830bd1a00e4ab4d59d42c

LABEL org.opencontainers.image.title="princess-helena" \
      org.opencontainers.image.source="https://github.com/miguelgrasso/princess-helena" \
      org.opencontainers.image.licenses="MIT"

USER root
# Parches de Alpine entre bumps de la base. No actualiza nginx: eso llega cambiando el FROM.
RUN apk upgrade --no-cache \
 && rm -f /etc/nginx/conf.d/default.conf /usr/share/nginx/html/*.html

COPY --chmod=0644 nginx/nginx.conf   /etc/nginx/nginx.conf
COPY --chmod=0644 nginx/default.conf /etc/nginx/conf.d/default.conf
# Contenido de root y de sólo lectura: el proceso (uid 101) no puede modificarlo.
COPY --from=build --chmod=0444 /build/index.html /build/index.html.gz /usr/share/nginx/html/

USER 101
# Valida la config en el build y borra el pid y los temporales que nginx -t deja en /tmp.
RUN nginx -t && rm -rf /tmp/*

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

# SIGQUIT = apagado ordenado. ENTRYPOINT propio: el de la base modifica la config al arrancar.
STOPSIGNAL SIGQUIT
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
