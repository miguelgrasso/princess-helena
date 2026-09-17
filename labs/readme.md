# 🧪 Labs — romper para entender

Escenarios rotos a propósito sobre la plataforma de este proyecto. Cada uno
presenta un **síntoma**, como llegaría un ticket real: sin la causa, sin la
solución, y sin decir dónde mirar.

No son tutoriales. Montar algo que funciona enseña a montar; arreglar algo que
se rompió enseña a operar.

---

## Cómo se juega

```bash
cd labs/02-crashloop-liveness
cat README.md              # el síntoma y el contexto
kubectl apply -k .         # romper el entorno
# ...diagnosticar y arreglar...
cat SOLUCION.md            # recién al final, para contrastar
```

**Reglas:**

1. Leer `SOLUCION.md` antes de intentarlo arruina el ejercicio.
2. El objetivo no es que vuelva a funcionar: es **explicar la causa raíz**.
3. Si el arreglo esconde el problema en vez de resolverlo, el lab no está superado.
4. Cada lab trae un tiempo objetivo. Pasarse no es fallar; rendirse sin diagnóstico, sí.

---

## Catálogo

### Kubernetes

| # | Síntoma | Tiempo |
|---|---|---|
| 01 | El pod se queda en `Pending` indefinidamente | 10 min |
| 02 | Los pods reinician en bucle cuando la base de datos tarda en responder | 15 min |
| 03 | El Service existe, pero las peticiones dan *connection refused* | 10 min |
| 04 | El Ingress responde en `/` pero devuelve 404 en `/api` | 15 min |
| 05 | La base perdió todos los datos tras reiniciarse el pod | 20 min |
| 06 | La aplicación arranca pero ignora su configuración | 10 min |
| 07 | Tres réplicas ejecutaron la migración de base de datos a la vez | 20 min |

### CI/CD

| # | Síntoma | Tiempo |
|---|---|---|
| 08 | El pipeline termina en verde y la imagen publicada tiene un CVE crítico | 15 min |
| 09 | Se subió un archivo con credenciales y el pipeline no lo detectó | 10 min |

### GitOps y observabilidad

| # | Síntoma | Tiempo |
|---|---|---|
| 10 | Argo CD reporta *Synced*, pero en el cluster sigue corriendo la versión anterior | 15 min |
| 11 | Grafana no muestra las métricas de negocio de la API | 15 min |

### Migraciones (no hay nada roto: hay que cambiar sin romper)

| # | Escenario | Tiempo |
|---|---|---|
| 12 | Migrar la base de Deployment a StatefulSet sin perder datos | 30 min |
| 13 | Rotar la contraseña de la base sin downtime | 25 min |

### Experimentos con agentes

| # | Escenario |
|---|---|
| AG-01 | Entregarle a un agente **solo los síntomas** de cada lab y medir en cuáles acierta el diagnóstico, en cuáles inventa y en cuáles arregla de más. Los resultados se documentan en `AG-01/RESULTADOS.md`. |

---

## Estructura de un lab

```
NN-nombre/
├── README.md      el síntoma, el contexto y las pistas (colapsadas)
├── roto.yaml      el manifiesto o configuración con el defecto
└── SOLUCION.md    diagnóstico, causa raíz y por qué el arreglo es correcto
```

Las pistas van dentro de bloques `<details>`: están disponibles, pero hay que
decidir abrirlas.