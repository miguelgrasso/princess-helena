/**
 * Métricas para Prometheus.
 *
 * La idea rectora: exponer métricas de NEGOCIO, no sólo técnicas. Un dashboard
 * que muestra CPU y memoria lo da cualquier cosa; uno que muestra "puntajes
 * por minuto" y "distribución de puntajes" cuenta qué está haciendo la gente.
 *
 * Convención de nombres de Prometheus: prefijo de aplicación, unidad al final
 * y sufijo _total en los contadores.
 */
import client from '@prometheus-io/client';

export const registro = new client.Registry();

// CPU, memoria, event loop lag, handles abiertos. Gratis y muy útil para
// detectar fugas: si "nodejs_heap_size_used_bytes" sube en escalera y nunca
// baja, hay un leak.
client.collectDefaultMetrics({ register: registro, prefix: 'helena_' });

/** Cuántas partidas se registraron. El contador estrella del dashboard. */
export const puntajesEnviados = new client.Counter({
  name: 'helena_scores_submitted_total',
  help: 'Cantidad total de puntajes registrados en el leaderboard',
  registers: [registro]
});

/** Distribución de puntajes: dice si el juego está bien balanceado. */
export const valorPuntaje = new client.Histogram({
  name: 'helena_score_value',
  help: 'Distribución de los valores de puntaje enviados',
  buckets: [50, 100, 250, 500, 1000, 2500, 5000, 10000],
  registers: [registro]
});

/** Puntajes rechazados por validación, separados por motivo. */
export const puntajesRechazados = new client.Counter({
  name: 'helena_scores_rejected_total',
  help: 'Puntajes rechazados por validación',
  labelNames: ['motivo'],
  registers: [registro]
});

/**
 * Latencia HTTP por ruta y código: el método RED (Rate, Errors, Duration).
 * Se etiqueta por "route" (el patrón, ej. /api/scores) y NO por URL completa,
 * para no generar infinitas series temporales.
 */
export const duracionHttp = new client.Histogram({
  name: 'helena_http_request_duration_seconds',
  help: 'Duración de las peticiones HTTP en segundos',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
  registers: [registro]
});

/** 1 si la base responde, 0 si no. Ideal para una alerta. */
export const baseDisponible = new client.Gauge({
  name: 'helena_db_up',
  help: '1 si la base de datos responde, 0 si no',
  registers: [registro]
});

/**
 * Engancha la medición de latencia al ciclo de vida de Fastify.
 * Se usa el reloj monotónico de Fastify en vez de Date.now().
 */
export function instrumentar(app) {
  app.addHook('onResponse', (peticion, respuesta, listo) => {
    // routeOptions.url es el patrón de ruta; si no matcheó ninguna, agrupamos
    // todo bajo "unknown" para no explotar la cardinalidad con URLs basura.
    const ruta = peticion.routeOptions?.url || 'unknown';
    duracionHttp.observe(
      {
        method: peticion.method,
        route: ruta,
        status: String(respuesta.statusCode)
      },
      respuesta.elapsedTime / 1000   // Fastify lo da en milisegundos
    );
    listo();
  });
}
