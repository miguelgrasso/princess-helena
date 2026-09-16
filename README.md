# 👑 Princess Helena

> Un juego de plataformas construido desde cero... y toda la plataforma DevOps que lo sostiene.

![Estado](https://img.shields.io/badge/estado-en%20construcción-yellow)
![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-339933?logo=nodedotjs&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?logo=postgresql&logoColor=white)
![Licencia](https://img.shields.io/badge/licencia-MIT-green)

---

## ¿Qué es esto?

**Princess Helena** es un juego de plataformas 2D en HTML5 Canvas — una guerrera con estética K-pop que esquiva bugs 🐛 y llamas de CrashLoopBackOff 🔥 mientras recolecta estrellas.

Pero el juego es solo la mitad del proyecto.

La otra mitad es **la plataforma completa que lo despliega y lo opera**: contenedores, Kubernetes, CI/CD con security gates, GitOps, observabilidad e infraestructura como código. Todo open-source, todo reproducible en una laptop.


---

## Arquitectura

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│   Juego     │────▶│     API      │────▶│  PostgreSQL  │
│  (nginx)    │     │   (Fastify)  │     │              │
│  Canvas/JS  │◀────│  leaderboard │◀────│   scores     │
└─────────────┘     └──────────────┘     └──────────────┘
       ▲                    │
       │                    ├──▶ /healthz  (liveness, sin BD)
   Ingress                  ├──▶ /readyz   (readiness, con BD)
   / → juego                └──▶ /metrics  (Prometheus)
   /api → API
```

**Decisiones de diseño que vale la pena señalar:**

- El juego **degrada con elegancia**: si la API no responde en 2s, se sigue jugando sin leaderboard. La funcionalidad opcional no tumba la principal.
- `/healthz` **no toca la base de datos** a propósito: si Postgres cae, reiniciar los pods en bucle solo agrega un CrashLoopBackOff al incendio. `/readyz` sí la consulta, y saca el pod del Service hasta que vuelva.
- Configuración **12-factor con fail-fast**: si falta una variable, el proceso no arranca. Un pod que arranca a medias es peor que uno que no arranca.
- El puntaje llega desde el navegador del jugador, así que **el servidor no confía en él**: validación por esquema, topes por rango y rate limiting en escritura.

---

## Stack

| Capa | Tecnología |
|---|---|
| Juego | HTML5 Canvas + JavaScript vanilla (sin frameworks, sin dependencias) |
| API | Node.js 24 + Fastify |
| Base de datos | PostgreSQL 16 |
| Contenedores | Docker (multistage, non-root) |
| Orquestación | Kubernetes (kind) + Kustomize |
| CI/CD | GitHub Actions con gates de seguridad (Gitleaks, Trivy) |
| GitOps | Argo CD |
| Observabilidad | Prometheus + Grafana |
| IaC | Terraform |
| Portal de desarrollo | Backstage (catálogo + software templates) |

---

## Hoja de ruta

- [x] **Fase 1** — El juego: Canvas, física, animaciones, parallax, partículas, audio
- [x] **Fase 1b** — API de leaderboard: Fastify + PostgreSQL, métricas y health checks
- [x] **Fase 2** — Contenerización: Dockerfiles multistage non-root + Docker Compose
- [ ] **Fase 3a** — IaC: el cluster kind nace de `terraform apply`
- [ ] **Fase 3b** — Kubernetes: Deployments, StatefulSet, Job de migración, Ingress, Kustomize (dev/prod)
- [ ] **Fase 4** — CI: GitHub Actions con escaneo de secretos y vulnerabilidades
- [ ] **Fase 5** — GitOps: Argo CD sincronizando el cluster desde este repo
- [ ] **Fase 6** — Observabilidad: Prometheus + Grafana (dashboards técnico y de negocio)
- [ ] **Fase 7** — Plataforma como código: ingress-controller, Argo CD y observabilidad provisionados con Terraform
- [ ] **Fase 8** — IDP: Backstage con catálogo de servicios y una *golden path* que genera un microservicio completo (repo, pipeline, manifiestos y despliegue) a partir de este proyecto
- [ ] **Fase 9** — Migración a AWS: el mismo stack sobre EKS (Terraform con módulo EKS, ALB Controller con IRSA, EBS CSI, ECR). Sesiones efímeras con `terraform destroy` al cerrar.

---

## Cómo correrlo

Sólo hace falta Docker con BuildKit (el de Docker Desktop o cualquier Docker Engine reciente).

```bash
git clone https://github.com/miguelgrasso/princess-helena.git
cd princess-helena

cp .env.example .env                            # editar POSTGRES_PASSWORD
docker compose up -d --build
docker compose run --rm api src/migrate.js      # crea las tablas (una sola vez)
```

| URL | Qué es |
|---|---|
| http://localhost:8080 | el juego, servido por nginx igual que en el cluster |
| http://localhost:3000 | la API: `/api/leaderboard`, `/healthz`, `/readyz`, `/metrics` |

En `:8080` el juego anda completo pero **sin leaderboard**: nginx sirve el HTML y no
hace de proxy a `/api`, porque en el cluster ese enrutado lo hace el Ingress. Para
verlo integrado en local hay un perfil que levanta el equivalente:

```bash
docker compose --profile dev up -d              # http://localhost:8081 — juego + API, mismo origen
```

Para apagar:

```bash
docker compose down                             # los datos sobreviven en el volumen pgdata
docker compose down -v                          # borra también los datos
```

---

## Sobre el desarrollo

El juego fue construido con un agente de Claude Code, dirigido por una especificación técnica que escribí para este proyecto (`CLAUDE.md`) y un subagente con permisos acotados (`.claude/agents/`). La frontera fue explícita desde el inicio: el agente construye el juego, la plataforma la construyo yo.

---

## Licencia

MIT — Miguel Ángel Grasso Aguinaga

*Princess Helena es un personaje original. Cualquier parecido con otras princesas de videojuegos es puramente arquetípico.* 👑
