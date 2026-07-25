variable "label" {
  type = string
}
variable "region" {
  default = "syd"
}
variable "k8s_version" {
  # VKE version slug, e.g. "v1.33.1+1". List current slugs with:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/kubernetes/versions
  # Pin explicitly per environment; VKE upgrades are rehearsed on staging first.
  type = string
}
variable "ha_controlplanes" {
  # true = 3-node managed control plane (extra cost). Production only.
  default = false
  type    = bool
}
variable "enable_firewall" {
  # Have VKE manage a firewall group for the worker nodes.
  default = true
  type    = bool
}
variable "node_plan" {
  # Worker node plan for the default pool.
  default = "vc2-2c-4gb"
}
variable "node_quantity" {
  default = 2
}
variable "auto_scaler" {
  default = false
  type    = bool
}
variable "min_nodes" {
  default = 2
}
variable "max_nodes" {
  default = 3
}
variable "extra_node_pools" {
  # map of pool label => { plan, node_quantity, [auto_scaler, min_nodes, max_nodes] }
  default = {}
  type    = any
}
