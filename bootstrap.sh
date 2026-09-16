#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
# VERSIONES
# ══════════════════════════════════════════════════════════════
DOCKER_MIN="24.0"

KIND_VERSION="0.33.0";     KIND_MIN="0.20"
KUBECTL_VERSION="1.33.0";  KUBECTL_MIN="1.28"
HELM_VERSION="3.16.0";     HELM_MIN="3.12"
TERRAFORM_VERSION="1.9.8"; TERRAFORM_MIN="1.5"
TRIVY_VERSION="0.74.0";    TRIVY_MIN="0.70"

# ══════════════════════════════════════════════════════════════
# AUXILIARES
# ══════════════════════════════════════════════════════════════

# ¿$1 es una versión menor que $2?
version_menor_que() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]
}

# Traduce uname -m al nombre que usan los releases.
detectar_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             return 1 ;;
    esac
}

# Dónde instalar: /usr/local/bin si se puede, si no el directorio del usuario.
target_bin() {
    if [ -w /usr/local/bin ] || sudo -n true 2>/dev/null; then
        echo "/usr/local/bin"
    else
        echo "$HOME/.local/bin"
    fi
}

# Mueve un binario a su destino final, con sudo solo si hace falta.
install_bin() {
    local origen="$1" nombre="$2" destino
    destino=$(target_bin)
    mkdir -p "$destino" || return 1

    if [ -w "$destino" ]; then
        mv "$origen" "$destino/$nombre" || return 1
    else
        sudo mv "$origen" "$destino/$nombre" || return 1
    fi

    case ":$PATH:" in
        *":$destino:"*) ;;
        *) echo "   ⚠️  $destino no está en tu PATH. Agregá a tu ~/.bashrc:" >&2
           echo "      export PATH=\"\$PATH:$destino\"" >&2 ;;
    esac
}

# ══════════════════════════════════════════════════════════════
# INSTALADOR GENÉRICO
#   $1 nombre del comando
#   $2 versión a instalar (solo para los mensajes)
#   $3 URL de descarga
#   $4 ruta del binario DENTRO del paquete, o "" si la descarga
#      ya es el binario suelto
# ══════════════════════════════════════════════════════════════
install_desde_url() {
    local nombre="$1" version="$2" url="$3" ruta_interna="${4:-}"
    local tmp archivo binario

    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN   # se borra siempre, falle o no

    # El nombre del archivo local define cómo hay que tratarlo después.
    case "$url" in
        *.tar.gz|*.tgz) archivo="$tmp/paquete.tar.gz" ;;
        *.zip)          archivo="$tmp/paquete.zip" ;;
        *)              archivo="$tmp/$nombre" ;;
    esac

    echo "   Descargando $nombre v$version..."
    # -f: falla ante un 404 en vez de guardar la página de error como binario
    curl -fsSL -o "$archivo" "$url" || { echo "   Error al descargar $nombre ❌" >&2; return 1; }

    # Descomprimir si corresponde
    case "$archivo" in
        *.tar.gz) tar -xzf "$archivo" -C "$tmp" || { echo "   Error al descomprimir ❌" >&2; return 1; } ;;
        *.zip)    unzip -qo "$archivo" -d "$tmp" || { echo "   Error al descomprimir ❌" >&2; return 1; } ;;
    esac

    # Dónde quedó el binario: dentro del paquete o suelto
    if [ -n "$ruta_interna" ]; then
        binario="$tmp/$ruta_interna"
    else
        binario="$tmp/$nombre"
    fi

    [ -f "$binario" ] || { echo "   No se encontró el binario en el paquete ❌" >&2; return 1; }

    chmod +x "$binario" || { echo "   Error al dar permisos ❌" >&2; return 1; }
    install_bin "$binario" "$nombre" || { echo "   Error al instalar $nombre ❌" >&2; return 1; }

    hash -r                          # limpia la caché de rutas del shell
    command -v "$nombre" >/dev/null 2>&1 || { echo "   $nombre se instaló pero no responde ❌" >&2; return 1; }

    echo "   $nombre v$version instalado ✅"
}

# ══════════════════════════════════════════════════════════════
# CHECKS
# ══════════════════════════════════════════════════════════════

check_docker() {
    local ACTUAL

    if ! command -v docker >/dev/null 2>&1; then
        echo "docker NO está instalado ❌" >&2
        echo "   Instálalo desde: https://docs.docker.com/get-docker/" >&2
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "Docker está instalado pero el daemon no responde ❌" >&2
        grep -qi microsoft /proc/version 2>/dev/null \
            && echo "   ¿Está Docker Desktop abierto en Windows?" >&2
        return 1
    fi

    ACTUAL=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || ACTUAL=""
    [ -n "$ACTUAL" ] || { echo "No se pudo leer la versión de Docker ❌" >&2; return 1; }

    if version_menor_que "$ACTUAL" "$DOCKER_MIN"; then
        echo "Docker $ACTUAL (mínimo requerido: $DOCKER_MIN) ⚠️" >&2
        echo "   Considera actualizar Docker." >&2
        return 1
    fi

    echo "Docker $ACTUAL listo 🐳"
}

check_kind() {
    local arch ACTUAL

    if ! command -v kind >/dev/null 2>&1; then
        echo "kind no está instalado, instalando..."
        arch=$(detectar_arch) || { echo "   Arquitectura no soportada ❌" >&2; return 1; }
        install_desde_url "kind" "$KIND_VERSION" \
            "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${arch}" || return 1
    fi

    ACTUAL=$(kind version 2>/dev/null | awk '{print $2}' | sed 's/^v//')
    [ -n "$ACTUAL" ] || { echo "No se pudo leer la versión de kind ❌" >&2; return 1; }

    if version_menor_que "$ACTUAL" "$KIND_MIN"; then
        echo "kind $ACTUAL (mínimo: $KIND_MIN) ⚠️" >&2
        return 1
    fi

    echo "kind $ACTUAL listo 🔧"
}

check_kubectl() {
    local arch ACTUAL

    if ! command -v kubectl >/dev/null 2>&1; then
        echo "kubectl no está instalado, instalando..."
        arch=$(detectar_arch) || { echo "   Arquitectura no soportada ❌" >&2; return 1; }
        install_desde_url "kubectl" "$KUBECTL_VERSION" \
            "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" || return 1
    fi

    # --client: sin esto intenta contactar al cluster y falla en bootstrap
    ACTUAL=$(kubectl version --client 2>/dev/null | grep '^Client' | awk '{print $3}' | sed 's/^v//')
    [ -n "$ACTUAL" ] || { echo "No se pudo leer la versión de kubectl ❌" >&2; return 1; }

    if version_menor_que "$ACTUAL" "$KUBECTL_MIN"; then
        echo "kubectl $ACTUAL (mínimo: $KUBECTL_MIN) ⚠️" >&2
        return 1
    fi

    echo "kubectl $ACTUAL listo ☸️"
}

check_helm() {
    local arch ACTUAL

    if ! command -v helm >/dev/null 2>&1; then
        echo "helm no está instalado, instalando..."
        arch=$(detectar_arch) || { echo "   Arquitectura no soportada ❌" >&2; return 1; }
        # el tarball trae el binario dentro de linux-<arch>/
        install_desde_url "helm" "$HELM_VERSION" \
            "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" \
            "linux-${arch}/helm" || return 1
    fi

    # --short devuelve v3.16.0+g9c9e5a4: hay que quitar la v y el sufijo del commit
    ACTUAL=$(helm version --short 2>/dev/null | sed 's/^v//' | cut -d'+' -f1)
    [ -n "$ACTUAL" ] || { echo "No se pudo leer la versión de helm ❌" >&2; return 1; }

    if version_menor_que "$ACTUAL" "$HELM_MIN"; then
        echo "helm $ACTUAL (mínimo: $HELM_MIN) ⚠️" >&2
        return 1
    fi

    echo "helm $ACTUAL listo ⎈"
}

check_terraform() {
    local arch ACTUAL

    if ! command -v terraform >/dev/null 2>&1; then
        echo "terraform no está instalado, instalando..."
        arch=$(detectar_arch) || { echo "   Arquitectura no soportada ❌" >&2; return 1; }
        command -v unzip >/dev/null 2>&1 || { echo "   Falta 'unzip' (sudo apt install unzip) ❌" >&2; return 1; }
        # el zip trae el binario suelto en la raíz
        install_desde_url "terraform" "$TERRAFORM_VERSION" \
            "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" || return 1
    fi

    ACTUAL=$(terraform version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
    [ -n "$ACTUAL" ] || { echo "No se pudo leer la versión de terraform ❌" >&2; return 1; }

    if version_menor_que "$ACTUAL" "$TERRAFORM_MIN"; then
        echo "terraform $ACTUAL (mínimo: $TERRAFORM_MIN) ⚠️" >&2
        return 1
    fi

    echo "terraform $ACTUAL listo 🏗️"
}

check_trivy() {
    local arch arch_trivy ACTUAL

    if ! command -v trivy >/dev/null 2>&1; then
        echo "trivy no está instalado, instalando..."
        arch=$(detectar_arch) || { echo "   Arquitectura no soportada ❌" >&2; return 1; }
        # trivy nombra sus releases distinto: 64bit / ARM64
        case "$arch" in
            amd64) arch_trivy="64bit" ;;
            arm64) arch_trivy="ARM64" ;;
        esac
        install_desde_url "trivy" "$TRIVY_VERSION" \
            "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${arch_trivy}.tar.gz" \
            "trivy" || return 1
    fi

    ACTUAL=$(trivy --version 2>/dev/null | head -1 | awk '{print $2}' | sed 's/^v//')
    [ -n "$ACTUAL" ] || { echo "No se pudo leer la versión de trivy ❌" >&2; return 1; }

    if version_menor_que "$ACTUAL" "$TRIVY_MIN"; then
        echo "trivy $ACTUAL (mínimo: $TRIVY_MIN) ⚠️" >&2
        return 1
    fi

    echo "trivy $ACTUAL listo 🔍"
}

# ══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════
main() {
    local fallos=0

    check_docker    || fallos=$((fallos + 1))
    check_kind      || fallos=$((fallos + 1))
    check_kubectl   || fallos=$((fallos + 1))
    check_helm      || fallos=$((fallos + 1))
    check_terraform || fallos=$((fallos + 1))
    check_trivy     || fallos=$((fallos + 1))

    echo
    if [ "$fallos" -eq 0 ]; then
        echo "Entorno listo ✅"
    else
        echo "$fallos herramienta(s) con problemas ❌"
        return 1
    fi
}

main "$@"