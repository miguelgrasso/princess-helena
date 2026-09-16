#!/usr/bin/env bash
#
# limpiar-entorno.sh — desinstala las herramientas que bootstrap.sh instala,
# para poder probar el bootstrap desde cero en una máquina que ya las tenía.
#
# NUNCA toca Docker: es prerequisito del entorno, no dependencia del proyecto.
#
# Uso:
#   ./limpiar-entorno.sh              # pide confirmación
#   ./limpiar-entorno.sh --si         # sin preguntar
#   ./limpiar-entorno.sh --dry-run    # solo muestra qué haría
#
set -euo pipefail

HERRAMIENTAS=(kind kubectl helm terraform trivy)
RESPALDO="/tmp/backup-herramientas-$(date +%Y%m%d-%H%M%S)"

DRY_RUN=false
SIN_PREGUNTAR=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --si|-y)   SIN_PREGUNTAR=true ;;
        *) echo "Opción desconocida: $arg" >&2; exit 1 ;;
    esac
done

# ── Inventario: qué hay realmente instalado ───────────────────
echo "Herramientas encontradas:"
ENCONTRADAS=()
for h in "${HERRAMIENTAS[@]}"; do
    # -a lista TODAS las copias en el PATH, no solo la primera:
    # es común tener una de apt y otra manual peleándose.
    while IFS= read -r ruta; do
        [ -n "$ruta" ] || continue
        echo "   $h → $ruta"
        ENCONTRADAS+=("$ruta")
    done < <(command -v -a "$h" 2>/dev/null || true)
done

if [ ${#ENCONTRADAS[@]} -eq 0 ]; then
    echo "   (ninguna) — el entorno ya está limpio ✅"
    exit 0
fi

# ── Clusters kind: son contenedores, el binario no se los lleva ──
CLUSTERS=""
if command -v kind >/dev/null 2>&1; then
    CLUSTERS=$(kind get clusters 2>/dev/null || true)
    if [ -n "$CLUSTERS" ]; then
        echo
        echo "Clusters kind activos (se van a eliminar):"
        echo "$CLUSTERS" | sed 's/^/   /'
    fi
fi

# ── Confirmación ──────────────────────────────────────────────
echo
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: no se elimina nada."
    exit 0
fi

if [ "$SIN_PREGUNTAR" = false ]; then
    read -r -p "¿Eliminar todo esto? Se respalda en $RESPALDO [s/N] " respuesta
    case "$respuesta" in
        s|S|si|SI|Si) ;;
        *) echo "Cancelado."; exit 0 ;;
    esac
fi

# ── Borrar clusters primero (mientras kind todavía existe) ────
if [ -n "$CLUSTERS" ]; then
    echo
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        echo "Eliminando cluster $c..."
        kind delete cluster --name "$c" || echo "   no se pudo eliminar $c ⚠️"
    done <<< "$CLUSTERS"
fi

# ── Respaldar y eliminar binarios ─────────────────────────────
mkdir -p "$RESPALDO"
echo
for ruta in "${ENCONTRADAS[@]}"; do
    nombre=$(basename "$ruta")

    # Respaldo: si algo sale mal, se restaura con un mv
    if [ -r "$ruta" ]; then
        cp "$ruta" "$RESPALDO/$nombre" 2>/dev/null \
            || sudo cp "$ruta" "$RESPALDO/$nombre" 2>/dev/null \
            || echo "   no se pudo respaldar $nombre ⚠️"
    fi

    # Eliminar, con sudo solo si hace falta
    if [ -w "$(dirname "$ruta")" ]; then
        rm -f "$ruta"
    else
        sudo rm -f "$ruta"
    fi
    echo "Eliminado: $ruta"
done

# ── Paquetes de apt, por si alguna vino de ahí ────────────────
if command -v apt >/dev/null 2>&1; then
    for h in "${HERRAMIENTAS[@]}"; do
        if dpkg -l "$h" >/dev/null 2>&1; then
            echo "$h también está instalado vía apt. Para eliminarlo:"
            echo "   sudo apt remove $h"
        fi
    done
fi

# El shell cachea dónde encontró cada comando: sin esto, los binarios
# recién borrados "siguen existiendo" en esta sesión.
hash -r

echo
echo "Entorno limpio ✅"
echo "Respaldo en: $RESPALDO"
echo "Para restaurar algo:  sudo mv $RESPALDO/<nombre> /usr/local/bin/"
echo
echo "Ahora probá:  bash ./bootstrap.sh"