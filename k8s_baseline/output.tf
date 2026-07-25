output "ingress_namespace" {
  value = helm_release.ingress_nginx.namespace
}
output "cluster_issuer" {
  value = kubernetes_manifest.letsencrypt_issuer.manifest.metadata.name
}
