# helena-api — leaderboard global

Backend del leaderboard de Princess Helena. Node + Fastify + Postgres.

Existe para que el pipeline tenga **algo real que observar, escalar y romper**:
con sólo un estático servido por nginx, Prometheus/Grafana, HPA, secrets, PVC y
NetworkPolicy quedan decorativos.

## Contrato

Prefijo `/api` para lo que consume el juego. Las rutas operacionales van sin
prefijo, porque las consumen Kubernetes y Prometheus.

| Método | Ruta | Respuesta |
|---|---|---|
| `POST` | `/api/scores` | `201 {rank, best}` |
| `GET` | `/api/leaderboard?limit=10` | `200 {entries:[{rank, player, score, at}]}` |
| `GET` | `/healthz` | `200` — liveness, **no toca la base** |
| `GET` | `/readyz` | `200` / `503` — readiness, **sí toca la base** |
| `GET` | `/metrics` | formato Prometheus |

`POST /api/scores` espera `{"player": "MYK", "score": 1234}`:

- `player`: 1 a 3 caracteres `[A-Z0-9]`. Se normaliza a mayúsculas antes de validar.
- `score`: entero entre 0 y 1.000.000.
- `rank` es la posición global de **ese** puntaje; `best` es el mejor puntaje
  de todo el leaderboard.

Un `player` o un `score` inválidos devuelven `400`. Un campo desconocido en el
body **no** da error: Fastify lo descarta antes de llegar al handler (ajv con
`removeAdditional`), así que la petición se acepta sin ese campo.

El endpoint es público y anónimo, así que asume tráfico hostil: validación
estricta, tope de puntaje y rate limit por IP (por réplica: ver notas del pipeline).

## Variables de entorno

Todo se configura por entorno, nada quemado en el código. Ver `.env.example`.
La única obligatoria es `DATABASE_URL` — si falta, el proceso **no arranca**.
Eso es a propósito: un pod que arranca a medias con config inválida es peor que
uno que no arranca, porque el `CrashLoopBackOff` se ve y el bug silencioso no.

| Variable | Default | Para qué |
|---|---|---|
| `DATABASE_URL` | — (obligatoria) | conexión a Postgres |
| `PORT` / `HOST` | `3000` / `0.0.0.0` | dónde escucha |
| `LOG_LEVEL` | `info` | verbosidad |
| `DB_POOL_MAX` | `10` | conexiones por réplica (ojo con `max_connections`) |
| `CORS_ORIGIN` | vacío (sin CORS) | orígenes permitidos, separados por coma; con Ingress al mismo dominio no hace falta; `*` sólo para desarrollo |
| `RATE_LIMIT_MAX` | `20` | puntajes por IP por ventana |
| `RATE_LIMIT_READ_MAX` | `60` | lecturas del leaderboard por IP por ventana |
| `RATE_LIMIT_WINDOW` | `1 minute` | ventana del rate limit |
| `TRUST_PROXY` | vacío (no confía) | IPs o CIDR del Ingress, separadas por coma; `true` y números de saltos se rechazan |

## Correr en local

```bash
npm install

# Postgres descartable
docker run -d --rm --name helena-pg \
  -e POSTGRES_USER=helena -e POSTGRES_PASSWORD=helena -e POSTGRES_DB=helena \
  -p 5432:5432 postgres:17-alpine

export DATABASE_URL=postgres://helena:helena@localhost:5432/helena
npm run migrate     # crea el esquema
npm start
```

Prueba rápida:

```bash
curl -s localhost:3000/healthz
curl -s -X POST localhost:3000/api/scores \
     -H 'content-type: application/json' \
     -d '{"player":"MYK","score":1234}'
curl -s 'localhost:3000/api/leaderboard?limit=5'
curl -s localhost:3000/metrics | grep helena_scores
```

## Integración con el juego (desarrollo)

El juego pide el leaderboard a `/api` — ruta relativa, mismo origen. En
producción eso funciona porque el **Ingress** sirve todo bajo un mismo dominio:

```
navegador → Ingress ┬── /        → nginx (el juego)
                    └── /api/*   → la API (:3000), directo
```

nginx **no** hace de proxy hacia la API, y no debe hacerlo: su config rechaza
todo lo que no sea GET/HEAD a nivel `server`, así que un `POST /api/scores` que
pasara por nginx recibiría 405 y nunca llegaría a la API (el juego lo tomaría
como "API caída" y ocultaría el leaderboard sin ningún error visible).

En local hace falta algo equivalente, si no el juego queda en un puerto y la API
en otro: orígenes distintos, CORS de por medio y una constante que habría que
editar según dónde corras.

`dev-server.js` replica esa topología con cero dependencias:

```
navegador → :8080 ┬── /        → archivos de app/
                  └── /api/*   → proxy a la API (:3000)
```

Dos terminales:

```bash
npm start           # terminal 1 — la API en :3000
npm run dev:serve   # terminal 2 — el juego en :8080
```

Y abrís http://localhost:8080. `API_BASE` se queda en `/api` sin tocar nada.

Variables: `DEV_PORT` (8080), `API_HOST` (127.0.0.1), `API_PORT` (3000).

Sólo reenvía `/api/*`, igual que nginx: `/metrics` no se expone por ahí, lo
scrapea Prometheus dentro del cluster.

Es una herramienta de desarrollo — no se empaqueta en ninguna imagen.

## Migraciones

```bash
npm run migrate
```

Aplica en orden los `.sql` de `migrations/` que falten y los registra en
`schema_migrations`. Cada una corre en su propia transacción.

**En Kubernetes esto va como Job o initContainer, nunca desde el servidor.** Si
la API migrara al arrancar, N réplicas competirían por migrar a la vez. El
runner sale con código distinto de 0 si algo falla, así el Job falla visiblemente.

## Métricas expuestas

Además de las de Node (CPU, memoria, heap, event loop lag) con prefijo `helena_`:

| Métrica | Tipo | Para qué sirve |
|---|---|---|
| `helena_scores_submitted_total` | counter | partidas registradas — el número estrella del dashboard |
| `helena_score_value` | histogram | distribución de puntajes: dice si el juego está balanceado |
| `helena_scores_rejected_total{motivo}` | counter | rechazos por validación; un pico = alguien manipulando el cliente |
| `helena_http_request_duration_seconds{method,route,status}` | histogram | método RED: tasa, errores y latencia |
| `helena_db_up` | gauge | 1/0 según responda la base — buena base para una alerta |

`helena_nodejs_heap_size_used_bytes` subiendo en escalera y sin bajar nunca es
la firma de un memory leak.

## Notas para el pipeline

Lo de abajo es responsabilidad de Myke; queda anotado lo que la app espera.

- **Liveness ≠ readiness.** `/healthz` no toca la base a propósito: si fallara
  durante una caída de Postgres, Kubernetes reiniciaría todos los pods en loop.
  Reiniciar la API no arregla una base caída, sólo suma un CrashLoopBackOff al
  incendio. `/readyz` sí la toca, así el pod sale del Service mientras dure la
  caída y vuelve solo.
- **Apagado ordenado**: la app atiende `SIGTERM`, drena las peticiones en vuelo
  y cierra el pool. Dale margen con `terminationGracePeriodSeconds` o vas a ver
  502 en cada deploy.
- **Sin estado en el proceso**: escala horizontalmente sin pegajosidad de sesión.
- **Logs JSON a stdout**, listos para Loki/Elastic. No escribe archivos.
- **`TRUST_PROXY` explícito**: detrás de un Ingress la IP real llega por
  `X-Forwarded-For`, pero esa cabecera la puede escribir cualquiera. Configurá
  `TRUST_PROXY` con las IPs o CIDR de los pods del Ingress (en kind, por defecto
  `10.244.0.0/16`). Un número de saltos no sirve: Fastify 5 lo ignora. Sin
  configurar, la API ve sólo la IP del proxy y todos comparten un mismo límite.
- **El rate limit es por réplica**: los contadores viven en la memoria de cada
  proceso. Con N réplicas, una IP puede hacer hasta N veces el límite, y si el
  HPA escala durante un abuso, cada réplica nueva le da más margen al atacante.
  El límite que cuenta hay que aplicarlo en el **Ingress** (ingress-nginx lo
  soporta con anotaciones); el de la app queda como segunda barrera.
- El `DATABASE_URL` lleva credenciales: va en un **Secret**, no en un ConfigMap.
  La app nunca lo loguea.
- Corre bien como usuario no-root: no escribe en disco ni necesita puertos < 1024.
