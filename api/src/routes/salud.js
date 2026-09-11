/**
 * Rutas operacionales: las consumen Kubernetes y Prometheus, no el juego.
 *
 * La distincion entre liveness y readiness es la clave de todo esto:
 *
 *  /healthz (liveness)  -> "el proceso esta vivo?" NO toca la base de datos.
 *      Si fallara cuando la base esta caida, Kubernetes reiniciaria todos los
 *      pods en loop durante una caida de la base. Reiniciar la API no arregla
 *      una base caida: solo agrega un CrashLoopBackOff al incendio.
 *
 *  /readyz (readiness)  -> "puedo atender trafico?" SI toca la base.
 *      Si la base no responde, el pod sale del Service y deja de recibir
 *      peticiones, pero sigue vivo y vuelve solo cuando la base vuelve.
 */
import { baseViva } from '../db.js';
import { registro, baseDisponible } from '../metrics.js';

export default async function rutasSalud(app) {
  app.get('/healthz', async () => ({ status: 'ok' }));

  app.get('/readyz', async (peticion, respuesta) => {
    const viva = await baseViva();

    // Aprovechamos el sondeo para alimentar la metrica: Prometheus se entera
    // del estado de la base sin necesidad de un exporter aparte.
    baseDisponible.set(viva ? 1 : 0);

    if (!viva) {
      return respuesta.code(503).send({ status: 'sin base de datos' });
    }
    return { status: 'ready' };
  });

  /** Formato de exposicion de Prometheus. */
  app.get('/metrics', async (peticion, respuesta) => {
    respuesta.header('Content-Type', registro.contentType);
    return registro.metrics();
  });
}
