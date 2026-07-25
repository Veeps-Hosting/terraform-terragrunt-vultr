output "namespace" {
  value = kubernetes_namespace.keycloak.metadata[0].name
}
output "hostname" {
  value = var.hostname
}
