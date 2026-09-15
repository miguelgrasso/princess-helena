/**
 * Servidor de desarrollo: replica en local lo que hará el Ingress en producción.
 *
 * ¿Por qué existe? El juego pide el leaderboard a `/api` — ruta relativa, mismo
 * origen. En producción eso funciona porque el Ingress sirve todo bajo un mismo
 * dominio: `/` al nginx del juego y `/api` directo a la API (nginx no hace de
 * proxy). En local, sin algo que haga lo mismo, el juego quedaría en
 * un puerto y la API en otro: orígenes distintos, CORS de por medio y una
 * constante que habría que editar según dónde corras. Todo eso desaparece con
 * un único origen.
 *
 *        navegador → :8080 ┬── /        → archivos de app/
 *                          └── /api/*   → proxy a la API (:3000)
 *
 * Es una herramienta de DESARROLLO: cero dependencias, no se empaqueta en
 * ninguna imagen y no la usa producción. Ahí el trabajo lo hace el Ingress.
 *
 * Uso:  npm run dev:serve      (con la API ya corriendo en otra terminal)
 */
import http from 'node:http';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { dirname, extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));
const RAIZ_APP = join(AQUI, '..', 'app');     // el juego vive fuera de api/

const PUERTO = Number.parseInt(process.env.DEV_PORT || '8080', 10);
const API_HOST = process.env.API_HOST || '127.0.0.1';
const API_PORT = Number.parseInt(process.env.API_PORT || '3000', 10);

const TIPOS = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml'
};

/** Reenvía la petición a la API, como hace el Ingress en producción. */
function proxiar(peticion, respuesta) {
  const upstream = http.request(
    {
      host: API_HOST,
      port: API_PORT,
      path: peticion.url,
      method: peticion.method,
      headers: {
        ...peticion.headers,
        host: `${API_HOST}:${API_PORT}`,
        // nginx manda esto y la API lo usa (trustProxy) para ver la IP real
        // en vez de la del proxy. Sin esto el rate limit contaría a todos juntos.
        'x-forwarded-for': peticion.socket.remoteAddress || ''
      }
    },
    (respuestaApi) => {
      respuesta.writeHead(respuestaApi.statusCode || 502, respuestaApi.headers);
      respuestaApi.pipe(respuesta);
    }
  );

  // Si la API no está levantada, devolvemos 502 en vez de dejar colgada la
  // petición. El juego lo interpreta como "no hay leaderboard" y sigue igual.
  upstream.on('error', (err) => {
    console.error(`  ✗ la API no responde en ${API_HOST}:${API_PORT} (${err.code})`);
    if (!respuesta.headersSent) {
      respuesta.writeHead(502, { 'content-type': 'application/json' });
    }
    respuesta.end(JSON.stringify({ error: 'API no disponible' }));
  });

  peticion.pipe(upstream);   // reenvía el body del POST
}

/** Sirve un archivo de app/, sin permitir salir de ese directorio. */
async function servirEstatico(peticion, respuesta) {
  // Quitamos la query y normalizamos para que "../../etc/passwd" no escape.
  const ruta = decodeURIComponent((peticion.url || '/').split('?')[0]);
  const relativa = normalize(ruta === '/' ? '/index.html' : ruta).replace(/^(\.\.[/\\])+/, '');
  const archivo = join(RAIZ_APP, relativa);

  if (!archivo.startsWith(RAIZ_APP)) {
    respuesta.writeHead(403).end('Prohibido');
    return;
  }

  try {
    const info = await stat(archivo);
    if (!info.isFile()) throw new Error('no es un archivo');

    respuesta.writeHead(200, {
      'content-type': TIPOS[extname(archivo)] || 'application/octet-stream',
      'content-length': info.size,
      // Sin caché: en desarrollo querés ver tus cambios al recargar.
      'cache-control': 'no-store'
    });
    createReadStream(archivo).pipe(respuesta);
  } catch {
    respuesta.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    respuesta.end('No encontrado');
  }
}

const servidor = http.createServer((peticion, respuesta) => {
  if ((peticion.url || '').startsWith('/api/')) {
    proxiar(peticion, respuesta);
  } else {
    servirEstatico(peticion, respuesta);
  }
});

servidor.listen(PUERTO, () => {
  console.log(`
  👑 Princess Helena — servidor de desarrollo

     Juego:   http://localhost:${PUERTO}
     /api/*   →  http://${API_HOST}:${API_PORT}

  Un solo origen, igual que en producción: el juego no necesita CORS
  y API_BASE se queda en "/api".

  Ctrl+C para salir.
`);
});

// Apagado ordenado, para no dejar el puerto tomado entre reinicios.
for (const senal of ['SIGINT', 'SIGTERM']) {
  process.on(senal, () => servidor.close(() => process.exit(0)));
}
