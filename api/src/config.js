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

/**
 * trustProxy de Fastify a partir de TRUST_PROXY. Por defecto NO se confía en
 * ningún proxy: X-Forwarded-For lo puede escribir cualquier cliente, y
 * confiar en todos le permite inventar su IP y esquivar el rate limit.
 *   (vacío)             -> false: la IP es la del socket (local, docker run)
 *   "10.244.0.0/16,..." -> confía sólo en proxies con esas IPs/CIDR (el Ingress)
 * Se rechazan a propósito:
 *   "true"  -> es exactamente el agujero que se cerró.
 *   números -> Fastify 5 ignora el conteo de saltos (siempre "no confiar")
 *              porque no puede validar quién se conecta directo. Aceptarlo
 *              dejaría el rate limit compartido entre todos sin ningún aviso.
 */
function proxyConfiable() {
  const bruto = (process.env.TRUST_PROXY || '').trim();
  if (bruto === '' || bruto === 'false') return false;
  if (bruto === 'true') {
    throw new Error('TRUST_PROXY=true confía en cualquier X-Forwarded-For y permite esquivar el rate limit: usá las IPs o CIDR del Ingress (ej. 10.244.0.0/16)');
  }
  if (/^\d+$/.test(bruto)) {
    throw new Error(`TRUST_PROXY=${bruto}: Fastify no admite conteo de saltos y lo ignoraría; usá las IPs o CIDR del Ingress (ej. 10.244.0.0/16)`);
  }
  return bruto.split(',').map((d) => d.trim()).filter(Boolean);
}

export const config = {
  puerto:   entero('PORT', 3000),
  host:     process.env.HOST || '0.0.0.0',   // 0.0.0.0 para que el contenedor sea alcanzable
  logLevel: process.env.LOG_LEVEL || 'info',
  trustProxy: proxyConfiable(),

  db: {
    // Única variable obligatoria: sin base de datos no hay leaderboard.
    url:     requerida('DATABASE_URL'),
    poolMax: entero('DB_POOL_MAX', 10)
  },

  cors: {
    // Orígenes permitidos, separados por coma. VACÍO = sin CORS, y es el valor
    // por defecto: el Ingress sirve juego y API bajo el mismo dominio, así que
    // el juego no lo necesita. Abierto por defecto, un sitio ajeno podría hacer
    // que los navegadores de sus visitantes envíen puntajes (y el rate limit se
    // repartiría entre IPs de víctimas). "*" = cualquier origen: sólo para
    // desarrollo y siempre explícito.
    origen: (() => {
      const bruto = (process.env.CORS_ORIGIN || '').trim();
      if (bruto === '') return false;
      if (bruto === '*') return true;
      return bruto.split(',').map((o) => o.trim()).filter(Boolean);
    })()
  },

  rateLimit: {
    max:      entero('RATE_LIMIT_MAX', 20),
    // Lecturas del leaderboard. El juego lo pide al terminar cada partida, así
    // que 60/min por IP sobra; sin tope, es la forma más barata de agotar el
    // pool de Postgres (DB_POOL_MAX × réplicas).
    lecturaMax: entero('RATE_LIMIT_READ_MAX', 60),
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
