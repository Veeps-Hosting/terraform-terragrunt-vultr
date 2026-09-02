# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR KUBERNETES ENGINE (VKE) CLUSTER
# One cluster with an HA control plane, a managed firewall group and a default
# node pool, plus optional extra node pools. Kubeconfig / client credentials
# are exported for the k8s_baseline and keycloak modules to consume via
# terragrunt dependency outputs, and the cluster's VPC is resolved so the
# managed_database leaf can attach to it and trust its subnet.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_version = ">= 1.12.0"
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.32"
    }
  }
}
provider "vultr" {}

resource "vultr_kubernetes" "cluster" {
  label   = var.label
  region  = var.region
  version = var.k8s_version

  # Both ForceNew: flipping either on a live cluster is a rebuild, so they are
  # decided once per environment. HA control plane (billed extra) defaults on
  # in staging as well as prod - the platform exists to have no SPOF, and
  # staging keeps prod's shape so upgrades can be rehearsed there first.
  ha_controlplanes = var.ha_controlplanes
  enable_firewall  = var.enable_firewall

  # Empty string means "let VKE create a VPC for this cluster". The provider
  # passes vpc_id through to the API verbatim, so it has to become null rather
  # than "" for the API default to apply. ForceNew as well.
  vpc_id = var.vpc_id == "" ? null : var.vpc_id

  node_pools {
    label         = "${var.label}-default"
    plan          = var.node_plan
    node_quantity = var.node_quantity
    auto_scaler   = var.auto_scaler
    # Pinned to node_quantity unless the leaf sets them, the same rule the
    # extra pools use below: with the autoscaler off they are inert, and with
    # it on the leaf is expected to set all three deliberately.
    min_nodes = coalesce(var.min_nodes, var.node_quantity)
    max_nodes = coalesce(var.max_nodes, var.node_quantity)

    # Provider schema v1 models labels as a set of {key, value} blocks (the v0
    # map form is gone), hence a dynamic block rather than a map argument.
    dynamic "labels" {
      for_each = var.node_labels
      content {
        key   = labels.key
        value = labels.value
      }
    }
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

  dynamic "labels" {
    for_each = try(each.value.labels, {})
    content {
      key   = labels.key
      value = labels.value
    }
  }
}

# The VPC this cluster lives in, when VKE created it.
#
# The provider never reads vpc_id back - resourceVultrKubernetesRead sets every
# other attribute but that one - so the id of a VKE-created VPC can only be
# learned by looking it up. VKE names the VPC after the cluster id and the
# description filter is an exact string match, so this cannot pick up the
# orphan VKE-Network-* VPCs left in the account by earlier experiments.
#
# The cluster id in the filter already defers this read until the cluster
# exists; depends_on states that ordering explicitly so a later edit to the
# filter cannot quietly turn it into a plan-time read that fails with
# "no results were found" on a fresh environment.
data "vultr_vpc" "cluster" {
  count = var.vpc_id == "" ? 1 : 0
  filter {
    name   = "description"
    values = ["VKE-Network-${vultr_kubernetes.cluster.id}"]
  }
  depends_on = [vultr_kubernetes.cluster]
}

# The VPC this cluster lives in, when the leaf supplied one.
#
# Only here so vpc_cidr is populated in both cases: the managed_database leaf
# trusts the whole cluster subnet, and its CIDR validation would reject the
# blank that an unknown subnet would otherwise produce.
data "vultr_vpc" "given" {
  count = var.vpc_id != "" ? 1 : 0
  filter {
    name   = "id"
    values = [var.vpc_id]
  }
}
