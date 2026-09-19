variable "cluster_name" {
  description = "Nombre del cluster kind. El contexto de kubectl queda como kind-<nombre>."
  type        = string
  default     = "princess-helena"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name: minúsculas, dígitos y guiones, sin empezar ni terminar en guión (lo exige kind)."
  }
}

variable "node_image" {
  description = "Imagen de los nodos. Tiene que ser una publicada para la versión de kind que trae el provider (tehcyx/kind 0.11 = kind v0.31.0) y quedar dentro del rango de kubectl (±1 versión menor)."
  type        = string
  default     = "kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48"

  validation {
    # Mismo criterio que las imágenes Docker del repo: el tag solo se puede mover.
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.node_image))
    error_message = "node_image tiene que ir pineada por digest (…@sha256:<64 hex>)."
  }
}

variable "workers" {
  description = "Cantidad de nodos worker además del control-plane."
  type        = number
  default     = 1

  validation {
    condition     = var.workers >= 0 && var.workers <= 3
    error_message = "Entre 0 y 3 workers: más no aporta nada en una laptop."
  }
}

variable "http_port" {
  description = "Puerto del host que llega al 80 del Ingress."
  type        = number
  default     = 80
}

variable "https_port" {
  description = "Puerto del host que llega al 443 del Ingress."
  type        = number
  default     = 443
}

variable "kubeconfig_path" {
  description = "Dónde escribir el kubeconfig del cluster. Por defecto, ~/.kube/kind-<cluster_name> (no toca ~/.kube/config). Cambiarlo con el cluster ya creado lo recrea."
  type        = string
  default     = null
}
