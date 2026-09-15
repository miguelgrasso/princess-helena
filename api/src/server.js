/**
 * Punto de entrada de la API del leaderboard de Princess Helena.
 *
 * Orden: configuracion -> plugins -> rutas -> escuchar -> apagado ordenado.
 */
import Fastify from 'fastify';
import cors from '@fastify/cors';
import rateLimit from '@fastify/rate-limit';

import { config } from './config.js';
import { cerrarPool } from './db.js';
import { instrumentar } from './metrics.js';
import rutasSalud from './routes/salud.js';
import rutasScores from './routes/scores.js';

const app = Fastify({
  // Logs en JSON a stdout: asi los recoge el runtime del contenedor y los
  // puede parsear Loki/Elastic. Nunca escribir logs a un archivo dentro del pod.
  logger: {
    level: config.logLevel,
    // El log de acceso por defecto incluye headers; los recortamos para no
    // filtrar cookies ni Authorization a los logs.
    serializers: {
      req: (peticion) => ({
        method: peticion.method,
        url: peticion.url,
        ip: peticion.ip
      })
    }
  },
  // Detras de un Ingress, la IP real viene en X-Forwarded-For. Pero esa cabecera
  // la escribe cualquiera: confiar en todas deja que un cliente invente su IP y
  // esquive el rate limit. Se confia SOLO en los proxies de TRUST_PROXY (IPs o
  // CIDR del Ingress). Sin configurar, se usa la IP del socket.
  trustProxy: config.trustProxy,
  // Cuerpo maximo: no necesitamos mas que un JSON de dos campos.
  bodyLimit: 1024
});

/**
 * Manejador de errores unico: al cliente le va un mensaje generico, al log le
 * va el detalle. Filtrar un stack trace o un mensaje de Postgres en la
 * respuesta HTTP es una fuga de informacion.
 *
 * OJO con el ORDEN: esto va ANTES de registrar las rutas. La instancia de
 * Fastify es "thenable", asi que hacer `await app.register(...)` dispara el
 * ready() del framework; despues de eso las rutas ya estan construidas y un
 * setErrorHandler tardio no se aplica (se ignora en silencio). Por eso los
 * register de abajo NO se esperan: Fastify los resuelve al hacer listen().
 */
app.setErrorHandler((error, peticion, respuesta) => {
  // Los errores de validacion del esquema ya son 400 y son seguros de mostrar.
  if (error.validation) {
    return respuesta.code(400).send({ error: error.message });
  }
  if (error.statusCode === 429) {
    return respuesta.code(429).send({ error: 'demasiadas peticiones, probá en un minuto' });
  }
  // Errores del cliente que Fastify detecta antes del handler: JSON mal formado
  // (400), body mayor que bodyLimit (413), content-type no soportado (415).
  // Responderlos como 500 ensucia la metrica de 5xx y dispara alertas falsas.
  // Mensaje propio: el de Fastify describe detalles internos del parser.
  if (error.statusCode >= 400 && error.statusCode < 500) {
    peticion.log.info({ codigo: error.code, status: error.statusCode }, 'peticion rechazada');
    const mensajes = { 413: 'body demasiado grande', 415: 'content-type no soportado' };
    return respuesta.code(error.statusCode).send({ error: mensajes[error.statusCode] ?? 'peticion invalida' });
  }

  peticion.log.error({ err: error }, 'error no controlado');
  return respuesta.code(500).send({ error: 'error interno' });
});

/**
 * 404 generico. El de Fastify responde "Route DELETE:/api/x not found": repite
 * metodo y URL, y le confirma a un escaner que esta hablando con Fastify.
 */
app.setNotFoundHandler((peticion, respuesta) => {
  respuesta.code(404).send({ error: 'no encontrado' });
});

// Plugins y rutas. Sin `await`: se resuelven al llamar a listen(), y asi el
// error handler de arriba queda vigente para todo lo que se registre debajo.
app.register(cors, { origin: config.cors.origen });

app.register(rateLimit, {
  global: false,            // solo donde se declara explicitamente
  max: config.rateLimit.max,
  timeWindow: config.rateLimit.ventana
});

instrumentar(app);

app.register(rutasSalud);
app.register(rutasScores);

/**
 * Apagado ordenado. Cuando Kubernetes va a terminar un pod manda SIGTERM y
 * espera (terminationGracePeriodSeconds) antes del SIGKILL. Ese margen se usa
 * para terminar las peticiones en vuelo y cerrar el pool: si no, el usuario
 * ve errores 502 en cada deploy.
 */
let apagando = false;
async function apagar(senal) {
  if (apagando) return;
  apagando = true;
  app.log.info({ senal }, 'apagando de forma ordenada');
  try {
    await app.close();     // deja de aceptar y drena lo que esta en curso
    await cerrarPool();
    process.exit(0);
  } catch (err) {
    app.log.error({ err }, 'fallo el apagado ordenado');
    process.exit(1);
  }
}
process.on('SIGTERM', () => apagar('SIGTERM'));
process.on('SIGINT', () => apagar('SIGINT'));

try {
  await app.listen({ port: config.puerto, host: config.host });
} catch (err) {
  app.log.error({ err }, 'no se pudo iniciar el servidor');
  process.exit(1);
}
