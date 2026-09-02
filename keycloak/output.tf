output "namespace" {
  value = kubernetes_namespace_v1.keycloak.metadata[0].name
}
output "hostname" {
  value = var.hostname
}
output "http_service" {
  # Chart-generated ClusterIP Service (release "keycloak" + chart "keycloakx").
  value = local.http_service
}
output "mgmt_service" {
  # Management interface (health/metrics) on port 9000.
  value = kubernetes_service_v1.keycloak_mgmt.metadata[0].name
}
output "bootstrap_admin_password" {
  # What KC_BOOTSTRAP_ADMIN_PASSWORD was seeded with: the leaf's value, or the
  # module-generated fallback (DESIGN §8). Only meaningful until the master
  # realm is imported; `terragrunt output -raw bootstrap_admin_password`.
  value     = local.admin_password
  sensitive = true
}

# --- Icinga check_vke_platform inputs (openvox profile::icinga2master) ---
output "monitor_api_url" {
  value = local.api_url
}
output "monitor_ca_pem" {
  # Cluster CA as PEM. The variable is sensitive because it travels with the
  # client key; the CA itself is public material, and nonsensitive() keeps
  # this readable in plain `terragrunt output` for the wqmon2 config.
  value = nonsensitive(base64decode(var.cluster_ca_certificate))
}
output "monitor_token" {
  # Long-lived token of the read-only icinga-monitor ServiceAccount; goes to
  # veeps/puppet/node/wqmon2... as veeps::secret::vke_monitor::<cluster>_token.
  value     = kubernetes_secret_v1.icinga_monitor_token.data["token"]
  sensitive = true
}
