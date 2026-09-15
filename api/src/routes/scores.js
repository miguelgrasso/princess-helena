/**
 * Rutas de negocio: enviar un puntaje y leer el leaderboard.
 *
 * Este endpoint es PÚBLICO y anónimo, así que se asume tráfico hostil:
 * validación estricta, tope de puntaje y rate limit por IP.
 */
import { config } from '../config.js';
import { guardarPuntaje, obtenerTop } from '../db.js';
import { puntajesEnviados, puntajesRechazados, valorPuntaje } from '../metrics.js';

// El esquema JSON valida la FORMA del body (tipos, campos de más, tamaños).
// Fastify lo compila a código nativo, así que además es muy rápido.
const esquemaPostScore = {
  body: {
    type: 'object',
    required: ['player', 'score'],
    // Fastify configura ajv con removeAdditional, asi que un campo desconocido
    // NO da 400: se descarta silenciosamente y nunca llega al handler. Sirve
    // igual como defensa (no hay forma de colar un campo de mas), pero la
    // peticion se acepta.
    additionalProperties: false,
    properties: {
      player: { type: 'string', minLength: 1, maxLength: 3 },
      score:  { type: 'integer' }
    }
  }
};

const esquemaGetTop = {
  querystring: {
    type: 'object',
    properties: {
      limit: { type: 'integer', minimum: 1, maximum: config.reglas.topMax, default: 10 }
    }
  }
};

export default async function rutasScores(app) {
  /**
   * POST /api/scores -> registra una partida.
   * Responde 201 con { rank, best }:
   *   rank = posicion global de ESTE puntaje
   *   best = mejor puntaje del leaderboard entero
   */
  app.post('/api/scores', {
    schema: esquemaPostScore,
    // Fastify configura ajv con coerceTypes: un "99" (texto) pasaría el esquema
    // convertido en 99. El contrato pide un entero, y un tipo equivocado no es
    // un error de formato del jugador: es un cliente que no es el juego. Por eso
    // se mira el body CRUDO, antes de que la validación lo convierta. Si falta
    // un campo, lo sigue reportando el esquema (required).
    preValidation: async (peticion, respuesta) => {
      const { player, score } = peticion.body ?? {};
      if ((player !== undefined && typeof player !== 'string') ||
          (score !== undefined && typeof score !== 'number')) {
        puntajesRechazados.inc({ motivo: 'tipo_invalido' });
        return respuesta.code(400).send({
          error: 'player debe ser texto y score un número entero'
        });
      }
    },
    config: {
      // Rate limit solo aca: es el unico endpoint que escribe.
      rateLimit: { max: config.rateLimit.max, timeWindow: config.rateLimit.ventana }
    }
  }, async (peticion, respuesta) => {
    // Normalizamos antes de validar: que el cliente mande "myk" no es un error
    // del usuario, es una diferencia de formato.
    const player = String(peticion.body.player).trim().toUpperCase();
    const score = peticion.body.score;

    if (!config.reglas.playerRegex.test(player)) {
      puntajesRechazados.inc({ motivo: 'player_invalido' });
      return respuesta.code(400).send({
        error: 'player debe tener 1 a 3 caracteres A-Z o 0-9'
      });
    }

    // El tope existe porque un cliente manipulado puede mandar cualquier cosa:
    // el juego corre en la maquina del jugador y no es una fuente confiable.
    if (score < config.reglas.scoreMin || score > config.reglas.scoreMax) {
      puntajesRechazados.inc({ motivo: 'score_fuera_de_rango' });
      return respuesta.code(400).send({
        error: `score debe estar entre ${config.reglas.scoreMin} y ${config.reglas.scoreMax}`
      });
    }

    const resultado = await guardarPuntaje(player, score);

    puntajesEnviados.inc();
    valorPuntaje.observe(score);

    peticion.log.info({ player, score, rank: resultado.rank }, 'puntaje registrado');

    return respuesta.code(201).send({
      rank: resultado.rank,
      best: resultado.best
    });
  });

  /** GET /api/leaderboard?limit=10 -> top N. */
  app.get('/api/leaderboard', {
    schema: esquemaGetTop,
    config: {
      // Cada lectura es una query a Postgres: sin tope por IP, martillar este
      // endpoint agota el pool. Contador propio, separado del de escritura.
      rateLimit: { max: config.rateLimit.lecturaMax, timeWindow: config.rateLimit.ventana }
    }
  }, async (peticion) => {
    const entries = await obtenerTop(peticion.query.limit ?? 10);
    return { entries };
  });

  /**
   * 405 para métodos que no existen sobre rutas que SÍ existen (RFC 9110, con
   * Allow). Un 404 le diría al cliente que la URL está mal cuando lo que está
   * mal es el método. HEAD no se lista: Fastify lo crea solo para cada GET.
   */
  const metodoNoPermitido = (permitidos) => async (peticion, respuesta) =>
    respuesta.code(405).header('Allow', permitidos).send({ error: 'método no permitido' });

  app.route({ method: ['GET', 'PUT', 'PATCH', 'DELETE'], url: '/api/scores', handler: metodoNoPermitido('POST') });
  app.route({ method: ['POST', 'PUT', 'PATCH', 'DELETE'], url: '/api/leaderboard', handler: metodoNoPermitido('GET, HEAD') });
}
