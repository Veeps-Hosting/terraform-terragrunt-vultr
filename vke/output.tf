output "cluster_id" {
  value = vultr_kubernetes.cluster.id
}
output "endpoint" {
  value = vultr_kubernetes.cluster.endpoint
}
output "ip" {
  value = vultr_kubernetes.cluster.ip
}
output "firewall_group_id" {
  value = vultr_kubernetes.cluster.firewall_group_id
}
# Base64-encoded kubeconfig and client credentials, as returned by the VKE API.
# Consumed by k8s_baseline / keycloak modules through terragrunt dependencies.
output "kube_config" {
  value     = vultr_kubernetes.cluster.kube_config
  sensitive = true
}
output "client_certificate" {
  value     = vultr_kubernetes.cluster.client_certificate
  sensitive = true
}
output "client_key" {
  value     = vultr_kubernetes.cluster.client_key
  sensitive = true
}
output "cluster_ca_certificate" {
  value     = vultr_kubernetes.cluster.cluster_ca_certificate
  sensitive = true
}
