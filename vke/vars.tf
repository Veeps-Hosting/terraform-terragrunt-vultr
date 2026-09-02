variable "label" {
  type = string
}
variable "region" {
  default = "syd"
}
variable "k8s_version" {
  # VKE version slug, e.g. "v1.36.2+1". List current slugs with:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/kubernetes/versions
  # Pin explicitly per environment. Not ForceNew - a change is an in-place
  # upgrade performed by VKE - so upgrades are rehearsed on staging first.
  type = string
}
variable "ha_controlplanes" {
  # true = three managed control-plane nodes (billed extra). ForceNew, so it is
  # decided once per cluster. Defaults on: the platform exists to have no SPOF,
  # and staging keeps prod's shape so upgrades can be rehearsed there.
  default = true
  type    = bool
}
variable "enable_firewall" {
  # Have VKE manage a firewall group for the worker nodes (exported as
  # firewall_group_id so leaves can add rules to it). ForceNew.
  default = true
  type    = bool
}
variable "vpc_id" {
  # Existing VPC to place the cluster in. Empty = VKE creates a VPC for this
  # cluster, which the module then looks up (see main.tf). ForceNew either way:
  # a cluster cannot be moved between VPCs.
  #
  # Destroy behaviour differs: a leaf-supplied VPC (the tf-infra-live design,
  # one vpc leaf per environment) is that leaf's to destroy and nothing leaks.
  # A VKE-created VPC is only ever read here, never in state, so destroying
  # the cluster leaves it behind for an API delete. README "Destroy".
  default = ""
  type    = string
}
variable "node_plan" {
  # Worker node plan for the default pool. vc2-2c-4gb is the "minimally
  # specified" size for both environments; prod moves to vc2-4c-8gb before
  # cutover.
  #
  # Effectively immutable once applied: provider 2.32 sends neither plan nor
  # label on a node_pools update (the API has no call for it), so a change
  # here plans as an in-place update that does nothing to the live nodes. The
  # default pool block itself is required (min 1, max 1) and cannot be
  # dropped. Resizing is therefore: add an extra_node_pools entry with the new
  # plan, drain the default nodes, shrink this pool to node_quantity = 1 (the
  # API minimum) - or rebuild the cluster. README "Node pool sizing".
  default = "vc2-2c-4gb"
}
variable "node_quantity" {
  # Three workers so the two Keycloak pods and the two ingress pods can each
  # sit on different nodes with one node spare for a drain or a lost host.
  default = 3
  type    = number
}
variable "auto_scaler" {
  default = false
  type    = bool
}
variable "min_nodes" {
  # Autoscaler bounds for the default pool. Only meaningful with auto_scaler =
  # true; null = pinned to node_quantity, the same rule extra_node_pools use.
  default = null
  type    = number
}
variable "max_nodes" {
  default = null
  type    = number
}
variable "node_labels" {
  # Kubernetes labels applied to every node in the default pool.
  default = {}
  type    = map(string)
}
variable "extra_node_pools" {
  # map of pool label => { plan, node_quantity, [auto_scaler, min_nodes, max_nodes, labels] }
  default = {}
  type    = any
}
