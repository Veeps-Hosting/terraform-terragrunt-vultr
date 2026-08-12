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
