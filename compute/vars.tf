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
  description = "Ubuntu 22.04 LTS 64 Bit"
  default     = "1743"
}
variable "plan" {
  default = "vc2-1c-1gb"
}
variable "vpc_ids" {
  default = []
  type    = list
}
variable "region" {
  default = "syd"
}
variable "startup_script" {
  default = "bootstrap_netplan"
}
variable "ssh_key" {
}
