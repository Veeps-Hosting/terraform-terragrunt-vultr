# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR KUBERNETES ENGINE (VKE) CLUSTER
# One cluster + a default node pool, with optional extra node pools.
# Kubeconfig / client credentials are exported for the k8s_baseline and
# keycloak modules to consume via terragrunt dependency outputs.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.19.0"
    }
  }
}
provider "vultr" {}

resource "vultr_kubernetes" "cluster" {
  label   = var.label
  region  = var.region
  version = var.k8s_version

  # HA control plane (billed extra) — true for production, false for staging.
  ha_controlplanes = var.ha_controlplanes
  enable_firewall  = var.enable_firewall

  node_pools {
    label         = "${var.label}-default"
    plan          = var.node_plan
    node_quantity = var.node_quantity
    auto_scaler   = var.auto_scaler
    min_nodes     = var.min_nodes
    max_nodes     = var.max_nodes
  }
}

# Optional additional node pools, keyed by pool label.
resource "vultr_kubernetes_node_pools" "extra" {
  for_each = var.extra_node_pools

  cluster_id    = vultr_kubernetes.cluster.id
  label         = each.key
  plan          = each.value.plan
  node_quantity = each.value.node_quantity
  auto_scaler   = try(each.value.auto_scaler, false)
  min_nodes     = try(each.value.min_nodes, each.value.node_quantity)
  max_nodes     = try(each.value.max_nodes, each.value.node_quantity)
}
