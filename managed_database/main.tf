# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR MANAGED DATABASE (PostgreSQL)
# Managed PG per the Keycloak HA design decision (Monday 2801647539):
# production = HA plan (primary + standby), staging = single-node plan.
# Keeps the only hard-stateful component out of the Kubernetes cluster.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_version = ">= 1.12.0"
  required_providers {
    vultr = {
      source = "vultr/vultr"
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

  cluster_time_zone = var.cluster_time_zone
  maintenance_dow   = var.maintenance_dow
  maintenance_time  = var.maintenance_time

  # Restrict reachability to the VKE cluster (and admin sources) only.
  trusted_ips = var.trusted_ips
}
