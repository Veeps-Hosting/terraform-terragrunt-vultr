variable "label" {
  type = string
}
variable "region" {
  default = "syd"
}
variable "plan" {
  # List slugs/pricing for the region with:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/databases/plans?engine=pg&region=syd"
  # vultr-dbaas-business-cc-1-55-2 = primary + standby with managed failover,
  # 1 vCPU / 2 GB / 55 GB, 97 connections, US$50/mo in syd (2026-09-02). Used
  # for BOTH environments: the single-node startup plan (US$30) would be the
  # one SPOF in a platform built to have none, and a 6-9 MB Keycloak database
  # gains nothing from a bigger box. Not ForceNew - a plan change is an
  # in-place resize.
  default = "vultr-dbaas-business-cc-1-55-2"
}
variable "database_engine" {
  # ForceNew: a different engine is a different database. Migrate, don't edit.
  default = "pg"
}
variable "database_engine_version" {
  # Major version. Not ForceNew - a change asks Vultr for an in-place major
  # upgrade - so treat it like a k8s upgrade and rehearse on staging first.
  # Keycloak 26.x supports PostgreSQL 13+.
  default = "17"
}
variable "cluster_time_zone" {
  default = "Australia/Sydney"
}
variable "maintenance_dow" {
  default = "sunday"
}
variable "maintenance_time" {
  # UTC, HH:MM. 18:00 UTC Sunday = 04:00/05:00 Sydney, after the 15:00 UTC
  # kc-pgdump CronJob, the 16:00 UTC Vultr backup and the 17:10 UTC bak3 pull
  # have all had their turn, and clear of the 22:00 UTC fleet backup window.
  default = "18:00"
}
variable "backup_hour" {
  # Vultr-side daily backup, UTC, as strings (the provider's schema type).
  # 16:00 UTC = 02:00/03:00 Sydney: an hour after the in-cluster kc-pgdump so
  # the two are not contending, and before bak3 pulls the bucket at 17:10.
  default = "16"
  type    = string
}
variable "backup_minute" {
  default = "00"
  type    = string
}
variable "vpc_id" {
  # VPC to attach to - the VKE cluster's, from the vke leaf's vpc_id output.
  # Attachment is what makes `host` a private address. Empty = not attached:
  # the database is then reachable only via public_host, and trusted_ips would
  # have to carry the cluster's public egress addresses instead of its subnet.
  default = ""
  type    = string
}
variable "trusted_ips" {
  # CIDRs allowed to reach the database: the cluster VPC subnet (vke leaf's
  # vpc_cidr output) plus the deploy host. Vultr's default with nothing set is
  # reachable from anywhere, so the list is validated rather than defaulted -
  # a plan with it empty, with a bare address, or with a world route fails
  # before anything is created or changed. Mock outputs for the vke dependency
  # therefore need a real CIDR in vpc_cidr.
  default = []
  type    = list(string)
  validation {
    condition     = length(var.trusted_ips) > 0
    error_message = "trusted_ips must not be empty: an empty list leaves the managed database reachable from anywhere. Pass the cluster VPC subnet and the deploy host, e.g. [the environment VPC CIDR from the vpc leaf, \"104.156.233.90/32\"]."
  }
  validation {
    condition = alltrue([
      for c in var.trusted_ips : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]), 0) > 0
    ])
    error_message = "Every trusted_ips entry must be CIDR notation (use /32 for a single host) and none may be a /0 world route."
  }
}
