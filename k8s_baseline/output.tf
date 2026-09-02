output "ingress_namespace" {
  value = helm_release.ingress_nginx.namespace
}
output "cluster_issuer" {
  value = kubectl_manifest.letsencrypt_issuer.name
}
# Public address of the Vultr LB; the Route53 leaf points the hostname at it.
# Empty until the CCM has built the LB (first plan/apply), hence try().
output "ingress_lb_ip" {
  value = try(data.kubernetes_service_v1.ingress_nginx.status[0].load_balancer[0].ingress[0].ip, "")
}
# In-cluster address of the mesh gateway (ports 5140/5141/5142). Empty when
# log shipping is disabled.
output "log_gateway_service" {
  value = var.log_shipping_enabled ? local.log_gateway_fqdn : ""
}
