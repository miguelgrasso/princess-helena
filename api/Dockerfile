# Imagen de la API del leaderboard. Contexto de build: api/
#   docker build -f api/Dockerfile api/
# Requiere BuildKit (el builder por defecto en Docker moderno): usa el ignore
# por Dockerfile, COPY con heredoc y RUN --mount. Con el builder legacy el
# ignore no se aplica y el build falla en el COPY <<EOF.
# Sin "# syntax=": se usa el frontend integrado de BuildKit.
# ============================================================================
# Stage 1 — build: instala dependencias de producción desde el lockfile.
# Debian 13 (trixie) igual que el runtime distroless: misma glibc. Hoy no hay
# módulos nativos (pg es JS puro, sin pg-native), pero si alguno llega, el
# binario compilado aquí funciona en el runtime sin sorpresas de musl.
# Node LTS (sólo las majors pares llegan a LTS). El salto de major es manual y
# va en los DOS FROM: el runtime lleva la major en el nombre de la imagen.
# ============================================================================
FROM node:24.21.0-trixie-slim@sha256:db3ae80f5d8df06e04dabdf7b44cbf008d32de168205fa0294444aabbc08c590 AS build

WORKDIR /app
COPY package.json package-lock.json ./

# npm ci falla si package.json y el lockfile no coinciden: nada se resuelve
# "a ojo". --ignore-scripts: ninguna dependencia actual tiene install scripts
# (hasInstallScript no aparece en el lock) y así un paquete comprometido no
# ejecuta código durante el build. Si un día entra un módulo nativo, quitarlo.
# Sin "npm cache clean": este stage se descarta y su caché nunca llega al runtime.
RUN npm ci --omit=dev --ignore-scripts

COPY src/ ./src/
COPY migrations/ ./migrations/

# Gate de build (parte 1): árbol de dependencias íntegro y sintaxis válida en
# TODOS los .js/.mjs de src/, subcarpetas incluidas. Un archivo por invocación:
# "node --check a.js b.js" sólo revisa a.js y toma el resto como argumentos.
# El código propio se normaliza a sólo lectura porque el contexto puede llegar
# con modo 777 (checkout en Windows/WSL). node_modules no se toca (un chmod -R
# ahí tarda minutos por copy-up); en su lugar se exige que nada sea escribible
# por otros. El proceso final (uid 65532) sólo lee.
RUN set -eux; \
    npm ls --omit=dev --all > /dev/null; \
    archivos="$(find src -type f \( -name '*.js' -o -name '*.mjs' \))"; \
    test -n "$archivos"; \
    for f in $archivos; do node --check "$f"; done; \
    test -n "$(ls migrations/*.sql)"; \
    find package.json package-lock.json src migrations -type d -exec chmod 0555 {} +; \
    find package.json package-lock.json src migrations -type f -exec chmod 0444 {} +; \
    test -z "$(find node_modules ! -type l -perm -o+w -print -quit)"

# Script del gate (parte 2). Vive sólo en este stage: el runtime lo monta
# durante un RUN y nunca queda en la imagen final.
COPY <<'EOF' /gate/verificar-imagen.mjs
// Corre en la imagen FINAL, como uid 65532 y con el node de producción.
// Falla el build si:
//   1. src/ importa un paquete que no está en "dependencies" (en local anda
//      porque está instalado como transitiva, y en el cluster revienta), o un
//      archivo relativo que no existe o no es un archivo.
//   2. Alguna dependencia declarada o algún módulo de src/ no carga.
//   3. Un import con nombre ({ a, b as c }) pide algo que el destino no
//      exporta. Los puntos de entrada nunca se enlazan: sin esto, ese error
//      recién aparece al arrancar (SyntaxError de link).
// Los puntos de entrada NO se ejecutan (server.js haría listen() y migrate.js
// intentaría conectar): sus imports se validan sólo con los chequeos 1 y 3.
// NO cubre: imports dinámicos con variable o backticks, createRequire/require,
// comentarios con comillas o dentro de las llaves de una cláusula de import,
// ni archivos .cjs.
// La lista de dependencias sale de package.json: nada escrito a mano.
import { readFile, readdir } from 'node:fs/promises';
import { statSync } from 'node:fs';
import { builtinModules } from 'node:module';
import { dirname, join, resolve } from 'node:path';

// Un módulo que llama a process.exit() al importarse terminaría el gate con su
// código (build verde) y ocultaría los errores ya acumulados. Se reemplaza por
// un throw: ese import() falla y queda registrado. La salida real es salir().
const salir = process.exit.bind(process);
process.exit = (codigo) => { throw new Error(`llamó a process.exit(${codigo}) al importarse`); };

// Un await top-level que nunca resuelve colgaría el build hasta el timeout del CI.
setTimeout(() => { console.error('Gate de imagen FALLÓ: timeout de 60 s importando módulos'); salir(1); }, 60_000).unref();

// Placeholder sin credenciales: pg.Pool no conecta hasta la primera query.
process.env.DATABASE_URL ??= 'postgres://gate@127.0.0.1:1/gate';

const RAIZ = '/app';
const ENTRADAS = ['src/server.js', 'src/migrate.js'];
const deps = Object.keys(JSON.parse(await readFile(join(RAIZ, 'package.json'), 'utf8')).dependencies ?? {});

async function listar(dir) {
  const salida = [];
  for (const e of await readdir(join(RAIZ, dir), { withFileTypes: true })) {
    const rel = join(dir, e.name);
    if (e.isDirectory()) salida.push(...await listar(rel));
    else if (/\.m?js$/.test(e.name)) salida.push(rel);
  }
  return salida;
}

const archivos = await listar('src');
const errores = [];
const IMPORTS = /\b(?:import|export)\s[^'"]*?\bfrom\s*['"]([^'"]+)['"]|\bimport\s*\(\s*['"]([^'"]+)['"]|\bimport\s+['"]([^'"]+)['"]/g;
// Cláusulas con llaves (con o sin default delante), para el chequeo 3.
const NOMBRADOS = /\b(?:import|export)\s+(?:[\w$]+\s*,\s*)?\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/g;
const nombrados = [];

for (const archivo of archivos) {
  const codigo = await readFile(join(RAIZ, archivo), 'utf8');
  for (const m of codigo.matchAll(NOMBRADOS)) {
    // "a as b" importa "a": lo que se valida es el nombre del lado del destino.
    const nombres = m[1].split(',').map((n) => n.trim().split(/\s+as\s+/)[0].trim()).filter(Boolean);
    nombrados.push({ archivo, spec: m[2], nombres });
  }
  for (const m of codigo.matchAll(IMPORTS)) {
    const spec = m[1] ?? m[2] ?? m[3];
    if (spec.startsWith('.') || spec.startsWith('/')) {
      // Tiene que ser un ARCHIVO: existsSync da true con un directorio y ESM no
      // resuelve índices de directorio (ERR_UNSUPPORTED_DIR_IMPORT al arrancar).
      const info = statSync(resolve(RAIZ, dirname(archivo), spec), { throwIfNoEntry: false });
      if (!info) errores.push(`${archivo}: no existe "${spec}"`);
      else if (!info.isFile()) errores.push(`${archivo}: "${spec}" no es un archivo (ESM no resuelve directorios)`);
      continue;
    }
    const paquete = spec.startsWith('@') ? spec.split('/').slice(0, 2).join('/') : spec.split('/')[0];
    if (spec.startsWith('node:') || builtinModules.includes(paquete)) continue;
    if (!deps.includes(paquete)) errores.push(`${archivo}: importa "${spec}" y "${paquete}" no está en dependencies`);
  }
}

for (const modulo of [...deps, ...archivos.filter((a) => !ENTRADAS.includes(a)).map((a) => join(RAIZ, a))]) {
  try { await import(modulo); } catch (err) { errores.push(`no carga ${modulo}: ${err.code ? err.code + ': ' : ''}${err.message}`); }
}

// Chequeo 3: después de cargar todo, así un destino roto no se reporta dos
// veces. Si el destino es un punto de entrada se salta: importarlo lo ejecutaría.
const entradasAbs = ENTRADAS.map((e) => join(RAIZ, e));
for (const { archivo, spec, nombres } of nombrados) {
  const destino = spec.startsWith('.') || spec.startsWith('/') ? resolve(RAIZ, dirname(archivo), spec) : spec;
  if (entradasAbs.includes(destino)) continue;
  let ns;
  try { ns = await import(destino); } catch { continue; }
  for (const nombre of nombres) {
    if (!(nombre in ns)) errores.push(`${archivo}: "${nombre}" no es un export de "${spec}"`);
  }
}

if (errores.length) {
  console.error('Gate de imagen FALLÓ:\n  ' + errores.join('\n  '));
  salir(1);
}
console.log(`Gate de imagen OK: ${deps.length} dependencias, ${archivos.length} módulos`);
salir(0);
EOF

# ============================================================================
# Stage 2 — runtime: distroless Node sobre Debian 13, variante nonroot.
# Sin shell, sin npm y sin gestor de paquetes: menos superficie y menos CVEs
# que alpine o slim, que además cargan npm/yarn/corepack que la app no usa.
# Distroless no publica tags con versión de Node: el digest es el único pin, y
# no hay apk/apt upgrade posible. Los parches del SO y de Node llegan SÓLO
# cambiando el digest; si nadie lo actualiza, la imagen envejece.
# OJO: Trivy analiza los paquetes Debian y node_modules, NO el binario de node.
# Un security release de Node no pone el gate de Trivy en rojo: vigilarlo aparte.
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

# Gate de build (parte 2): ver el script en el stage build. Se monta dentro de
# /app sólo durante este RUN, para que los paquetes se resuelvan desde
# /app/node_modules. Exec form porque no hay shell.
# Sin red: un módulo que intente salir a la red al importarse falla de forma
# determinista y no depende del runner de CI.
RUN --network=none --mount=type=bind,from=build,source=/gate/verificar-imagen.mjs,target=/app/verificar-imagen.mjs \
    ["/nodejs/bin/node", "/app/verificar-imagen.mjs"]

EXPOSE 3000

# Sólo Docker/Compose; Kubernetes lo ignora. Sin wget/curl en distroless: se
# usa el propio node (fetch nativo), nada instalado sólo para esto.
# PORT se interpreta igual que en config.js (parseInt): "3000 " es 3000 en los
# dos lados. Asume que la app escucha en loopback (HOST 0.0.0.0, el default):
# con HOST en una IP concreta, el healthcheck falla aunque la app esté sana.
# /healthz no toca la base: una DB caída no marca el contenedor unhealthy.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:'+Number.parseInt(process.env.PORT||'3000',10)+'/healthz',{signal:AbortSignal.timeout(2000)}).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]

# La app atiende SIGTERM: app.close() drena y luego cierra el pool.
# migrate.js también la atiende y sale con 143.
STOPSIGNAL SIGTERM

# node como PID 1 directo (nunca npm start: no reenvía señales).
# Migraciones con la MISMA imagen cambiando sólo el argumento:
#   docker run ... <imagen> src/migrate.js    (k8s: args: ["src/migrate.js"])
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["src/server.js"]
