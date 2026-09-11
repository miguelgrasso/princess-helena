-- Tabla de puntajes del leaderboard global.
--
-- Decisiones:
--  * "player" son iniciales estilo arcade (1-3 caracteres A-Z0-9). El CHECK
--    repite la validación que ya hace la API: la base es la última línea de
--    defensa, no confiamos sólo en la capa de aplicación.
--  * "score" tiene tope. Sin él, un cliente manipulado mete 2^53 y arruina
--    el leaderboard para siempre.
--  * Guardamos TODAS las partidas (no un registro por jugador): las iniciales
--    no son una identidad, son una firma. Dos "MYK" pueden ser personas
--    distintas.
CREATE TABLE IF NOT EXISTS scores (
    id         BIGSERIAL   PRIMARY KEY,
    player     TEXT        NOT NULL CHECK (player ~ '^[A-Z0-9]{1,3}$'),
    score      INTEGER     NOT NULL CHECK (score >= 0 AND score <= 1000000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Índice que sostiene la consulta caliente: "top N ordenado por puntaje".
-- El desempate por created_at ascendente hace que, ante igual puntaje, gane
-- quien lo logró primero.
CREATE INDEX IF NOT EXISTS scores_ranking_idx ON scores (score DESC, created_at ASC);
