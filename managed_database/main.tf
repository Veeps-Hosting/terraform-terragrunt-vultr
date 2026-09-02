# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR MANAGED DATABASE (PostgreSQL)
# Managed PG per the Keycloak HA design decision (Monday 2801647539): the
# business plan (primary + standby, managed failover) in BOTH environments,
# attached to the VKE cluster's VPC and reachable only from a trusted list
# that the module refuses to plan without.
# Keeps the only hard-stateful component out of the Kubernetes cluster.
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

resource "vultr_database" "db" {
  label                   = var.label
  region                  = var.region
  plan                    = var.plan
  database_engine         = var.database_engine
  database_engine_version = var.database_engine_version

  # Attach to the VKE cluster's VPC so `host` resolves to a private address.
  # The provider passes vpc_id through to the API verbatim, so "not attached"
  # has to be null rather than "".
  vpc_id = var.vpc_id == "" ? null : var.vpc_id

  cluster_time_zone = var.cluster_time_zone
  maintenance_dow   = var.maintenance_dow
  maintenance_time  = var.maintenance_time

  # Vultr's own daily backup, on their side, UTC. Strings because that is the
  # provider's schema type.
  backup_hour   = var.backup_hour
  backup_minute = var.backup_minute

  # The only network control on a managed database. Vultr's default with
  # nothing set is reachable from anywhere with the password, so vars.tf
  # rejects an empty list (and a world route) at plan time: this can never be
  # applied open.
  trusted_ips = var.trusted_ips
}
