variable "label" {
  type = string
}
variable "region" {
  default = "syd"
}
variable "plan" {
  # Confirm exact slugs/pricing for the Sydney region before first apply:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" "https://api.vultr.com/v2/databases/plans?engine=pg&region=syd"
  # Convention: vultr-dbaas-startup-* = single node (staging),
  #             vultr-dbaas-business-* = primary + standby HA (production).
  default = "vultr-dbaas-startup-cc-1-55-2"
}
variable "database_engine" {
  default = "pg"
}
variable "database_engine_version" {
  # Confirm the PG major versions Vultr currently offers before first apply;
  # Keycloak 26.4 supports PostgreSQL 13+.
  default = "17"
}
variable "cluster_time_zone" {
  default = "Australia/Sydney"
}
variable "maintenance_dow" {
  default = "sunday"
}
variable "maintenance_time" {
  # UTC, HH:MM — keep clear of the 22:00 fleet backup window.
  default = "18:00"
}
variable "trusted_ips" {
  # CIDRs allowed to reach the database. Populate with the VKE cluster egress
  # and admin ranges at deploy time; empty list = Vultr default (open) — do
  # NOT apply with this empty.
  default = []
  type    = list(string)
}
