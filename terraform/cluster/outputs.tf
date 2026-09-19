output "cluster_name" {
  value = kind_cluster.this.name
}

output "kubectl_context" {
  description = "Contexto a usar: kubectl --context <este> ..."
  value       = "kind-${kind_cluster.this.name}"
}

output "kubeconfig_path" {
  description = "Archivo con las credenciales del cluster (fuera del repo, en ~/.kube por defecto)."
  value       = kind_cluster.this.kubeconfig_path
}

output "endpoint" {
  value = kind_cluster.this.endpoint
}
