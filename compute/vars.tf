variable "activation_email" {
  default = false
}
variable "backups" {
  default = "enabled"
}
variable "backups_schedule_hour" {
  default = 22
}
variable "backups_schedule_type" {
  default = "daily_alt_odd"
}
variable "ddos_protection" {
  default = false
}
variable "domain" {
}
variable "enable_ipv6" {
  default = true
}
variable "firewall_group" {
  default = "web_ssh_ping"
}
variable "hostname" {
}
variable "os_id" {
  description = "Ubuntu 26.04 LTS 64 Bit"
  default     = "2760"
}
variable "plan" {
  default = "vc2-1c-2gb"
}
variable "vpc_ids" {
  default = []
  type    = list
}
variable "region" {
  default = "syd"
}
variable "startup_script" {
  default = "openvox_client"
}
variable "ssh_key" {
}
variable "reserved_ip" {
  default = false
  type    = bool
}
variable "reserved_ip_type" {
  default = "v4"
  validation {
    condition     = var.reserved_ip_type == "v4"
    error_message = "Only v4 reserved IPs are supported: the instance reserved_ip_id create field is ReservedIPv4."
  }
}
variable "reserved_ip_label" {
  default = ""
  type    = string
}
variable "reserved_ip_existing" {
  # Label of a reserved IP that already exists. The instance boots on it.
  # Use for a server whose address was converted out of band, and for a
  # replacement server inheriting the address of a decommissioned one. Mutually
  # exclusive with reserved_ip.
  default = ""
  type    = string
}
variable "reserved_ipv6" {
  # Reserve the instance's IPv6 /64 so the allocation survives a rebuild. This
  # is NOT the v6 equivalent of reserved_ip: the instance create API has no
  # reserved_ipv6 field, so the subnet attaches as a secondary and the guest
  # OS needs a static address out of it in netplan before anything uses it.
  default = false
  type    = bool
}
variable "reserved_ipv6_label" {
  default = ""
  type    = string
}
variable "adopt_existing" {
  # Set true for instances that were created outside this module - in practice
  # ones migrated off compute_legacy. Those instances have no ssh key and no
  # startup script attached, and both ssh_key_ids and script_id are ForceNew,
  # so managing them would destroy and rebuild the server. Setting this leaves
  # both unmanaged, which lets the module adopt the instance with no diff.
  # It does not detach anything: the attributes are unmanaged, not emptied.
  default = false
  type    = bool
}
