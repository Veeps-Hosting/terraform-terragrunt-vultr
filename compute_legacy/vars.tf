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
  description = "Ubuntu 20.04 LTS 64 Bit"
  default     = "270"
}
variable "plan" {
  default = "vc2-1c-1gb"
}
variable "private_network_id" {
  default = []
  type    = list
}
variable "region" {
  default = "syd"
}
