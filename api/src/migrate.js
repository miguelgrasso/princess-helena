/**
 * Runner de migraciones.
 *
 * Aplica en orden los archivos .sql de migrations/ que todavía no se hayan
 * aplicado, y deja registro en la tabla schema_migrations.
 *
 * En Kubernetes esto corre como Job (o initContainer) ANTES de que arranque
 * la API — nunca desde el proceso del servidor. Si migrara al arrancar, N
 * réplicas intentarían migrar a la vez y tendrías una carrera.
 *
 * Uso: npm run migrate
 */
import { readdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool } from './db.js';

const DIRECTORIO = join(dirname(fileURLToPath(import.meta.url)), '..', 'migrations');

function log(nivel, msg, extra = {}) {
  console.log(JSON.stringify({ level: nivel, msg, ...extra }));
}

async function migrar() {
  // La tabla de control se crea sola la primera vez.
  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      nombre      TEXT PRIMARY KEY,
      aplicada_en TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);

  const archivos = (await readdir(DIRECTORIO))
    .filter((n) => n.endsWith('.sql'))
    .sort();   // el orden lo da el prefijo numérico: 001_, 002_, ...

  const { rows } = await pool.query('SELECT nombre FROM schema_migrations');
  const yaAplicadas = new Set(rows.map((f) => f.nombre));

  let aplicadas = 0;
  for (const archivo of archivos) {
    if (yaAplicadas.has(archivo)) {
      log('debug', 'migración ya aplicada, se omite', { archivo });
      continue;
    }

    const sql = await readFile(join(DIRECTORIO, archivo), 'utf8');
    const cliente = await pool.connect();
    try {
      // Cada migración es atómica: si algo falla a la mitad, no queda a medias.
      await cliente.query('BEGIN');
      await cliente.query(sql);
      await cliente.query('INSERT INTO schema_migrations (nombre) VALUES ($1)', [archivo]);
      await cliente.query('COMMIT');
      log('info', 'migración aplicada', { archivo });
      aplicadas++;
    } catch (err) {
      await cliente.query('ROLLBACK').catch(() => {});
      throw new Error(`Falló la migración ${archivo}: ${err.message}`);
    } finally {
      cliente.release();
    }
  }

  log('info', 'migraciones al día', { aplicadas, total: archivos.length });
}

migrar()
  .then(() => pool.end())
  .then(() => process.exit(0))
  .catch(async (err) => {
    log('error', 'fallaron las migraciones', { err: err.message });
    await pool.end().catch(() => {});
    process.exit(1);   // código != 0 hace fallar el Job de Kubernetes
  });
