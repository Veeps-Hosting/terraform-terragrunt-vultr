output "cluster_id" {
  value = vultr_kubernetes.cluster.id
}
output "endpoint" {
  value = vultr_kubernetes.cluster.endpoint
}
output "ip" {
  value = vultr_kubernetes.cluster.ip
}
output "version" {
  value = vultr_kubernetes.cluster.version
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
# Pod and service CIDRs. Exported for firewall / trust decisions downstream;
# note the managed database trusts vpc_cidr, not these, because pod egress
# leaves the node on its VPC address.
output "cluster_subnet" {
  value = vultr_kubernetes.cluster.cluster_subnet
}
output "service_subnet" {
  value = vultr_kubernetes.cluster.service_subnet
}
# The VPC the cluster lives in: the one the leaf supplied, else the one VKE
# created (looked up in main.tf). try() only covers the count = 0 index - a
# lookup that finds nothing fails the apply rather than falling through.
output "vpc_id" {
  value = var.vpc_id != "" ? var.vpc_id : try(data.vultr_vpc.cluster[0].id, "")
}
# "<v4_subnet>/<v4_subnet_mask>" from whichever lookup exists, "" if neither.
# This is what the managed_database leaf puts in trusted_ips.
output "vpc_cidr" {
  value = try(
    "${data.vultr_vpc.cluster[0].v4_subnet}/${data.vultr_vpc.cluster[0].v4_subnet_mask}",
    "${data.vultr_vpc.given[0].v4_subnet}/${data.vultr_vpc.given[0].v4_subnet_mask}",
    "",
  )
}
output "default_node_pool_id" {
  value = try(vultr_kubernetes.cluster.node_pools[0].id, "")
}
