# --- cluster connection (from vke module outputs, base64-encoded PEM) ---
variable "cluster_endpoint" {
  type = string
}
variable "client_certificate" {
  type      = string
  sensitive = true
}
variable "client_key" {
  type      = string
  sensitive = true
}
variable "cluster_ca_certificate" {
  type      = string
  sensitive = true
}

# --- keycloak ---
variable "namespace" {
  default = "keycloak"
}
variable "hostname" {
  # Public FQDN: identity.veepshosting.net (prod) / kc4.staging.webqem.net
  # (staging). Stand up under a temp hostname first; move DNS at cutover.
  type = string
}
variable "keycloak_version" {
  # Keycloak image tag. 26.4.x per sub-ticket 3 (passkeys); pin the exact
  # patch validated on staging.
  default = "26.4"
}
variable "keycloakx_chart_version" {
  # codecentric keycloakx chart version; pin the version validated on staging.
  default = "7.1.0"
}
variable "replicas" {
  default = 2
}
variable "cluster_issuer" {
  default = "letsencrypt-prod"
}
variable "admin_whitelist_cidrs" {
  # restricted_to_wq source ranges. Populate from the current wqkc3 nginx
  # whitelist at deploy time; empty default makes a forgotten value fail
  # loudly (admin console denied everywhere) rather than fail open.
  default = []
  type    = list(string)
}

# --- database (from managed_database module outputs) ---
variable "db_host" {
  type = string
}
variable "db_port" {
  type = string
}
variable "db_name" {
  type = string
}
variable "db_user" {
  type = string
}
variable "db_password" {
  type      = string
  sensitive = true
}

# --- bootstrap admin (SEC-02 rotation at first prod deploy; sops/env only) ---
variable "admin_user" {
  default = "admin"
}
variable "admin_password" {
  type      = string
  sensitive = true
}
