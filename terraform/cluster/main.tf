locals {
  # Por defecto va a ~/.kube/kind-<nombre>: disco de Linux (respeta el 0600 de
  # un archivo con la clave de admin) y la ruta no cambia si se mueve el repo,
  # lo que importa porque kubeconfig_path es ForceNew y cambiarlo recrea el
  # cluster. No toca ~/.kube/config. pathexpand + abspath también se aplican a
  # un valor que venga de tfvars (con ~ o relativo).
  kubeconfig_path = abspath(pathexpand(coalesce(var.kubeconfig_path, "~/.kube/kind-${var.cluster_name}")))
}

resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = var.node_image
  kubeconfig_path = local.kubeconfig_path
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      # Explícito aunque sea el default de kind: TRUST_PROXY de la API se
      # configura con esta CIDR (la de los pods del Ingress).
      pod_subnet = "10.244.0.0/16"
    }

    # El control-plane recibe el tráfico del host. El Ingress controller para
    # kind se programa en el nodo con la etiqueta ingress-ready=true.
    node {
      role   = "control-plane"
      labels = { "ingress-ready" = "true" }

      # Sólo en localhost: sin listen_address, kind los publica en 0.0.0.0 y el
      # cluster queda alcanzable desde la red.
      extra_port_mappings {
        container_port = 80
        host_port      = var.http_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = var.https_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
    }

    dynamic "node" {
      for_each = range(var.workers)
      content {
        role = "worker"
      }
    }
  }

  lifecycle {
    # precondition y no validation: comparar dos variables en una validation requiere Terraform 1.9 y el módulo acepta >= 1.5.
    precondition {
      condition     = var.http_port != var.https_port
      error_message = "http_port y https_port tienen que ser distintos."
    }
  }
}
