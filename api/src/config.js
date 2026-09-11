/**
 * Configuración 12-factor: TODO viene de variables de entorno, nada quemado
 * en el código. Se valida al arrancar y, si algo falta o es inválido, el
 * proceso muere de inmediato con un mensaje claro.
 *
 * Por qué fallar rápido: en Kubernetes, un pod que arranca "a medias" con
 * config inválida es mucho peor que uno que no arranca. El CrashLoopBackOff
 * es visible; un bug silencioso de configuración, no.
 */

function requerida(nombre) {
  const valor = process.env[nombre];
  if (!valor) {
    throw new Error(`Falta la variable de entorno obligatoria: ${nombre}`);
  }
  return valor;
}

function entero(nombre, porDefecto) {
  const bruto = process.env[nombre];
  if (bruto === undefined || bruto === '') return porDefecto;
  const valor = Number.parseInt(bruto, 10);
  if (!Number.isInteger(valor)) {
    throw new Error(`La variable ${nombre} debe ser un entero, llegó: "${bruto}"`);
  }
  return valor;
}

export const config = {
  puerto:   entero('PORT', 3000),
  host:     process.env.HOST || '0.0.0.0',   // 0.0.0.0 para que el contenedor sea alcanzable
  logLevel: process.env.LOG_LEVEL || 'info',

  db: {
    // Única variable obligatoria: sin base de datos no hay leaderboard.
    url:     requerida('DATABASE_URL'),
    poolMax: entero('DB_POOL_MAX', 10)
  },

  cors: {
    // Lista separada por comas. "*" permite cualquier origen (sólo desarrollo).
    origen: (process.env.CORS_ORIGIN || '*') === '*'
      ? true
      : (process.env.CORS_ORIGIN || '').split(',').map((o) => o.trim()).filter(Boolean)
  },

  rateLimit: {
    max:      entero('RATE_LIMIT_MAX', 20),
    ventana:  process.env.RATE_LIMIT_WINDOW || '1 minute'
  },

  // Reglas de validación compartidas entre la API y el esquema SQL.
  reglas: {
    playerRegex: /^[A-Z0-9]{1,3}$/,
    scoreMin: 0,
    scoreMax: 1000000,
    topMax: 50          // tope duro del parámetro ?limit
  }
};
