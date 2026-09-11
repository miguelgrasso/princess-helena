# princess-helena 👑🎤

Juego de plataformas 2D en HTML5 Canvas. Protagonista: **Princesa Helena**, guerrera con estética K-pop idol (diseño 100% original — NO usar personajes, nombres, paletas distintivas ni assets de ninguna IP existente: nada de Nintendo, ni de películas/series de idols).

## Personaje
- Helena: pixel art dibujado programáticamente en Canvas (sin imágenes externas)
- Trenza larga color **castaño claro** (#A67B5B aprox), que se mueve con la inercia del salto
- Outfit de escenario: top/falda moderna con paleta alegre propia
- Ítem característico: **micrófono-espada** 🎤⚔️ (visual, sin mecánica de ataque en v1)
- **Animaciones por frames**: idle (2-3 frames de respiración), correr (4 frames de ciclo), salto (frame subida + frame caída). Dibujadas con rects/shapes por frame — estilo pixel art 16x24 aprox escalado.

## Gameplay v1
- Vista lateral, scroll horizontal simple o pantalla única (lo más simple que funcione bien)
- Controles: ← → mover, ESPACIO/↑ saltar + botones táctiles simples en móvil
- Física: gravedad + salto con velocidad Y, colisiones AABB sólidas (sin atravesar plataformas)
- **Game feel (obligatorio — es lo que lo hace sentir pro):**
  - *Salto variable*: soltar la tecla temprano = salto más corto
  - *Coyote time* (~100ms): puede saltar justo después de salir de una plataforma
  - *Jump buffering* (~100ms): si aprieta salto justo antes de aterrizar, salta al tocar suelo
- Coleccionables: estrellas ⭐ (+10) y notas musicales 🎵 (+25, más raras). Combo: 3 seguidas en <2s = puntos x2 con texto flotante "COMBO!"
- Enemigos (temática DevOps, shapes): bug 🐛 (patrulla horizontal) y llama CrashLoop 🔥 (estática en plataformas)
- Tocar enemigo = -1 vida + invulnerabilidad parpadeante 1.5s + knockback pequeño. 3 vidas (corazones en HUD)
- Game over → pantalla con puntaje, high score y "presiona ESPACIO para reiniciar"
- High score EN MEMORIA de sesión (variable JS — NUNCA localStorage/sessionStorage)
- Leaderboard global opcional vía la API (ver sección Backend): iniciales de 3 letras en game over + top 5. Si la API no responde, esa UI no se muestra y el juego sigue idéntico
- Pantalla de inicio: título "PRINCESS HELENA" con estilo neón K-pop + "presiona ESPACIO"

## Juice visual (lo que separa un demo de un juego)
- **Parallax de 3 capas** en el fondo: cielo nocturno con estrellas (lenta) → siluetas de ciudad/escenario (media) → luces de escenario/reflectores (rápida). Colores noche + neón
- **Partículas**: burst de estrellitas al recoger coleccionable, chispas al recibir daño, polvillo al aterrizar de un salto
- **Screen shake** sutil (3-4px, 150ms) al recibir daño
- Texto flotante de puntos (+10 sube y se desvanece)
- La trenza y la falda con leve física de seguimiento (1-2 segmentos)

## Sonido (WebAudio API — generado por código, sin archivos)
- Tono corto ascendente al recoger ⭐, acorde brillante en 🎵
- "Boing" grave al saltar, buzz al recibir daño
- (Opcional si sale limpio: loop chiptune simple de fondo con osciladores, con botón mute 🔇)
- El audio se inicializa en la primera interacción del usuario (requisito de los navegadores)

## Restricciones técnicas (NO negociables)
- **UN solo archivo: `app/index.html`** — HTML + CSS + JS vanilla. Cero frameworks, cero librerías, cero assets externos
- **Red: sólo mejora progresiva.** El juego DEBE ser 100% jugable sin red y abierto con `file://`. La única excepción permitida es el leaderboard (`/api/*`): todo `fetch` va en try/catch con timeout, y si falla el juego se comporta EXACTAMENTE igual que hoy (high score en memoria de sesión). Nada del gameplay puede depender de una respuesta del servidor
- Game loop con requestAnimationFrame (~60fps), update() y draw() separados; deltaTime para consistencia
- Constantes de configuración al inicio (colores, gravedad, velocidades, tuning del game feel) — para que cambiar el color de la trenza sea UNA línea (y UN deploy 😄)
- Código comentado en español, claro y legible (el dueño lo leerá para aprender)
- Corre abriendo el archivo directo en navegador Y servido por nginx en contenedor
- Rendimiento: pool de partículas (sin crear objetos cada frame), sin memory leaks — debe correr fluido 10+ minutos

## Contexto del proyecto (para decisiones)
Demo app de un portafolio DevOps: será dockerizado (multistage, non-root, Trivy limpio), desplegado en Kubernetes (kind) con Kustomize, CI en GitHub Actions con gates (Gitleaks/Trivy), GitOps con ArgoCD, observabilidad con Prometheus/Grafana y el cluster nacerá de Terraform. El dueño (Myke) construye TODO el pipeline a mano; el agente solo construye/mantiene el juego. Mantenerlo autocontenido y estable — cambios visuales pequeños (un color) servirán para demostrar deploys automáticos.

## Estructura del repo (el juego vive en app/)
```
princess-helena/
├── app/index.html        ← el juego (responsabilidad del agente)
├── api/                  ← backend del leaderboard (responsabilidad del agente)
├── Dockerfile            ← responsabilidad de Myke
├── k8s/                  ← responsabilidad de Myke
├── .github/workflows/    ← responsabilidad de Myke
└── CLAUDE.md
```
El agente construye y mantiene el CÓDIGO de las aplicaciones (`app/` y `api/`).
El agente NO toca Dockerfiles, k8s/, workflows, Terraform ni nada de infraestructura: eso es de Myke.

## Backend del leaderboard (`api/`)
Existe para que el pipeline tenga algo real que observar, escalar y romper: con
sólo un estático, Prometheus/Grafana, HPA, secrets, PVC y NetworkPolicy quedan
decorativos.

- **Stack**: Node + Fastify + Postgres. Sin ORM pesado; SQL directo con `pg`
- **Contrato** (prefijo `/api`):
  - `POST /api/scores` → body `{player, score}`; responde `{rank, best}`
  - `GET  /api/leaderboard?limit=10` → `{entries:[{rank, player, score, at}]}`
  - `GET  /healthz` → liveness: 200 si el proceso vive (NO toca la DB)
  - `GET  /readyz`  → readiness: 200 sólo si la DB responde
  - `GET  /metrics` → formato Prometheus
- **Validación estricta**: `player` = 1-3 caracteres `[A-Z0-9]`; `score` = entero
  0..1000000. Rate limit por IP. El endpoint es público: asumir tráfico hostil
- **Métricas de negocio, no sólo técnicas**: contador de puntajes enviados,
  histograma de valores de puntaje, histograma de latencia por ruta y código
- **12-factor**: toda la config por variables de entorno, sin valores quemados.
  Nunca loguear credenciales. Apagado ordenado (SIGTERM → drenar → cerrar pool)
- **Sin estado en el proceso**: debe poder correr con N réplicas detrás de un HPA

## Plan de construcción sugerido (iterativo — un paso estable a la vez)
1. Esqueleto: canvas + loop + Helena rectángulo moviéndose y saltando (física + colisiones sólidas)
2. Game feel: coyote time, jump buffering, salto variable
3. Plataformas + coleccionables + enemigos + vidas + HUD
4. Sprites animados de Helena (frames) + parallax
5. Partículas + screen shake + textos flotantes
6. Sonido WebAudio + pantallas de inicio/game over
Cada paso debe dejar el juego FUNCIONANDO antes de pasar al siguiente.
