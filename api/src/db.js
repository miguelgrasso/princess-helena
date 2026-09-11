/**
 * Acceso a Postgres mediante un pool de conexiones.
 *
 * Nunca se abre una conexión por request: el pool las reutiliza. Con varias
 * réplicas detrás de un HPA esto importa, porque cada pod multiplica su
 * "poolMax" contra el límite max_connections del servidor de base de datos.
 */
import pg from 'pg';
import { config } from './config.js';

// Postgres devuelve BIGINT como string para no perder precisión en JS.
// Nuestros conteos entran de sobra en un number, así que lo convertimos.
pg.types.setTypeParser(20, (valor) => Number.parseInt(valor, 10));

export const pool = new pg.Pool({
  connectionString: config.db.url,
  max: config.db.poolMax,
  // Si la base no responde al conectar, fallamos rápido en vez de colgar
  // el request (y con él, la readiness probe).
  connectionTimeoutMillis: 3000,
  idleTimeoutMillis: 30000
});

// Un error en una conexión ociosa (la base se reinició, un failover) emite
// 'error' en el pool. Sin este listener, Node mata el proceso entero.
pool.on('error', (err) => {
  console.error(JSON.stringify({
    level: 'error',
    msg: 'error en una conexión ociosa del pool',
    err: err.message
  }));
});

/** Ping barato para la readiness probe. */
export async function baseViva() {
  try {
    await pool.query('SELECT 1');
    return true;
  } catch {
    return false;
  }
}

/**
 * Inserta un puntaje y devuelve su posición global.
 *
 * Va en una transacción para que el rank corresponda al mismo instante que
 * la inserción: sin ella, entre el INSERT y el COUNT podrían colarse otras
 * partidas y devolveríamos una posición que nunca existió.
 */
export async function guardarPuntaje(player, score) {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    const insercion = await cliente.query(
      'INSERT INTO scores (player, score) VALUES ($1, $2) RETURNING id, created_at',
      [player, score]
    );

    // Posición = cuántos puntajes estrictamente mejores hay, más uno.
    const posicion = await cliente.query(
      'SELECT COUNT(*) + 1 AS rank FROM scores WHERE score > $1',
      [score]
    );

    const mejor = await cliente.query('SELECT MAX(score) AS best FROM scores');

    await cliente.query('COMMIT');

    return {
      id: insercion.rows[0].id,
      at: insercion.rows[0].created_at,
      rank: posicion.rows[0].rank,
      best: mejor.rows[0].best ?? score
    };
  } catch (err) {
    await cliente.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    cliente.release();   // SIEMPRE devolver la conexión al pool
  }
}

/** Top N del leaderboard, ya numerado. */
export async function obtenerTop(limite) {
  const { rows } = await pool.query(
    `SELECT player, score, created_at
       FROM scores
      ORDER BY score DESC, created_at ASC
      LIMIT $1`,
    [limite]
  );
  return rows.map((fila, indice) => ({
    rank: indice + 1,
    player: fila.player,
    score: fila.score,
    at: fila.created_at.toISOString()
  }));
}

/** Cierre ordenado: se llama al recibir SIGTERM. */
export async function cerrarPool() {
  await pool.end();
}
