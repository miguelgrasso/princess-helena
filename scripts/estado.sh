#!/usr/bin/env bash
#
# estado.sh — foto del proyecto: qué está levantado, qué falta y qué no coincide
# con el código. Pensado para retomar después de días sin tocar nada.
#
# Sólo lee: no crea, no borra y no arranca nada.
#
# Uso:
#   ./scripts/estado.sh             # foto rápida
#   ./scripts/estado.sh --drift     # además compara Terraform con la realidad (lento)
#
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG_PH="${KUBECONFIG_PH:-$HOME/.kube/kind-princess-helena}"
CLUSTER="princess-helena"
DRIFT=false
[ "${1:-}" = "--drift" ] && DRIFT=true

FALTANTES=0
ok()      { printf '  \033[32m✔\033[0m %-22s %s\n' "$1" "${2:-}"; }
falta()   { printf '  \033[33m•\033[0m %-22s %s\n' "$1" "${2:-}"; FALTANTES=$((FALTANTES+1)); }
mal()     { printf '  \033[31m✖\033[0m %-22s %s\n' "$1" "${2:-}"; FALTANTES=$((FALTANTES+1)); }
titulo()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
hay()     { command -v "$1" >/dev/null 2>&1; }

k() { kubectl --kubeconfig "$KUBECONFIG_PH" "$@" 2>/dev/null; }

# ── Docker ────────────────────────────────────────────────────
titulo "Docker"
if ! hay docker; then mal "docker" "no está instalado"
elif ! docker info >/dev/null 2>&1; then mal "daemon" "no responde (¿Docker Desktop abierto?)"
else ok "daemon" "$(docker version --format '{{.Server.Version}}'), cgroup v$(docker info --format '{{.CgroupVersion}}')"
fi

# ── Cluster ───────────────────────────────────────────────────
titulo "Cluster kind"
if ! hay kind; then falta "kind" "no está instalado"
elif ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then falta "$CLUSTER" "no existe (cd terraform/cluster && terraform apply)"
else
  ok "$CLUSTER" "creado"
  for n in control-plane worker; do
    c="$CLUSTER-$n"
    estado=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) || continue
    [ "$estado" = running ] && ok "nodo $n" "$(docker inspect -f '{{.State.Status}}, desde {{.State.StartedAt}}' "$c" | cut -c1-30)" || mal "nodo $n" "$estado"
  done
  PUERTOS=$(docker port "$CLUSTER-control-plane" 2>/dev/null | awk -F'-> ' '/^(80|443)\//{print $2}' | paste -sd' ')
  [ -n "$PUERTOS" ] && ok "puertos publicados" "$PUERTOS" || falta "puertos publicados" "el nodo no expone 80/443"
fi

# ── Kubernetes ────────────────────────────────────────────────
titulo "Kubernetes"
if [ ! -r "$KUBECONFIG_PH" ]; then falta "kubeconfig" "no existe $KUBECONFIG_PH"
elif ! k version >/dev/null; then mal "API server" "no responde"
else
  ok "API server" "$(k version -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null)"
  NODOS=$(k get nodes --no-headers | awk '{print $2}' | sort | uniq -c | tr -s ' ' | paste -sd', ')
  echo "$NODOS" | grep -q NotReady && mal "nodos" "$NODOS" || ok "nodos" "$NODOS"
  ROTOS=$(k get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | wc -l)
  [ "$ROTOS" -eq 0 ] && ok "pods" "todos Running" || mal "pods" "$ROTOS fuera de Running (kubectl get pods -A)"
  CLASE=$(k get ingressclass --no-headers | awk '{print $1}' | paste -sd' ')
  [ -n "$CLASE" ] && ok "ingressclass" "$CLASE" || falta "ingressclass" "sin controlador de entrada instalado"
  if hay helm; then
    # -o json y no --no-headers: con cero releases, helm igual imprime una línea.
    REL=$(helm list -A --kubeconfig "$KUBECONFIG_PH" -o json 2>/dev/null \
          | python3 -c 'import sys,json; print(" ".join(f"{r[\"name\"]}({r[\"status\"]})" for r in json.load(sys.stdin)))' 2>/dev/null)
    [ -n "$REL" ] && ok "releases helm" "$REL" || falta "releases helm" "ninguno"
  fi
  APPS=$(k get deploy -A --no-headers | grep -vE '^(kube-system|local-path-storage|ingress-nginx) ' | awk '{print $2"("$3")"}' | paste -sd' ')
  [ -n "$APPS" ] && ok "apps del proyecto" "$APPS" || falta "apps del proyecto" "todavía no desplegadas"
fi

# ── Entrada HTTP ──────────────────────────────────────────────
titulo "Entrada HTTP"
for hp in ${PUERTOS:-}; do
  # El 443 habla TLS: con http:// siempre fallaría. -k porque el certificado
  # por defecto del ingress es autofirmado.
  case "$hp" in *:443) url="https://$hp/"; insecure="-k" ;; *) url="http://$hp/"; insecure="" ;; esac
  codigo=$(curl -s -o /dev/null -m 3 $insecure -w '%{http_code}' "$url" 2>/dev/null)
  case "$codigo" in
    000) falta "$url" "sin respuesta (falta el ingress o no hay nada detrás)" ;;
    404) ok "$url" "responde 404 (ingress vivo, sin ruta que matchee)" ;;
    *)   ok "$url" "responde $codigo" ;;
  esac
done
[ -z "${PUERTOS:-}" ] && falta "entrada HTTP" "sin puertos publicados"

# ── Terraform ─────────────────────────────────────────────────
titulo "Terraform"
for dir in "$RAIZ"/terraform/*/; do
  [ -d "$dir" ] || continue
  nombre=$(basename "$dir")
  if [ ! -f "$dir/terraform.tfstate" ]; then falta "$nombre" "sin state (nunca se aplicó)"; continue; fi
  recursos=$(cd "$dir" && terraform state list 2>/dev/null | wc -l)
  if $DRIFT; then
    (cd "$dir" && terraform plan -input=false -detailed-exitcode >/dev/null 2>&1); rc=$?
    case $rc in
      0) ok "$nombre" "$recursos recurso(s), sin cambios" ;;
      2) mal "$nombre" "$recursos recurso(s), HAY CAMBIOS (terraform plan)" ;;
      *) mal "$nombre" "no se pudo planificar" ;;
    esac
  else
    ok "$nombre" "$recursos recurso(s) en el state (--drift para comparar)"
  fi
done

# ── Compose local ─────────────────────────────────────────────
titulo "Docker Compose (entorno local)"
if [ -f "$RAIZ/compose.yaml" ]; then
  SERV=$(cd "$RAIZ" && docker compose ps --format '{{.Service}}:{{.State}}' 2>/dev/null | paste -sd' ')
  [ -n "$SERV" ] && ok "servicios" "$SERV" || falta "servicios" "apagado (docker compose up -d)"
else falta "compose.yaml" "no existe"; fi

# ── Git ───────────────────────────────────────────────────────
titulo "Git"
cd "$RAIZ"
RAMA=$(git branch --show-current 2>/dev/null)
SUCIOS=$(git status --porcelain 2>/dev/null | wc -l)
[ "$SUCIOS" -eq 0 ] && ok "árbol" "limpio en $RAMA" || falta "árbol" "$SUCIOS archivo(s) sin commitear en $RAMA"
git fetch -q origin 2>/dev/null
ADELANTE=$(git rev-list --count "origin/$RAMA..HEAD" 2>/dev/null || echo 0)
[ "${ADELANTE:-0}" -eq 0 ] && ok "remoto" "al día" || falta "remoto" "$ADELANTE commit(s) sin pushear"

# ── Resumen ───────────────────────────────────────────────────
titulo "Resumen"
[ "$FALTANTES" -eq 0 ] && echo "  Todo en su lugar." || echo "  $FALTANTES cosa(s) pendientes o caídas (ver arriba)."
