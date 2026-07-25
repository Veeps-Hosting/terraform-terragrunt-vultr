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

# --- ingress-nginx ---
variable "ingress_nginx_chart_version" {
  # Pin to the chart version validated on staging before any prod apply.
  default = "4.13.0"
}
variable "ingress_replicas" {
  default = 2
}

# --- cert-manager ---
variable "cert_manager_chart_version" {
  default = "v1.18.2"
}
variable "acme_email" {
  default = "admin@webqem.com"
}

# --- elastic agent ---
variable "elastic_agent_enabled" {
  # Off until the ELK endpoint + API key are supplied at deploy time.
  default = false
  type    = bool
}
variable "elastic_agent_chart_version" {
  default = "9.1.0"
}
variable "elasticsearch_url" {
  default = ""
}
variable "elasticsearch_api_key" {
  default   = ""
  sensitive = true
}
