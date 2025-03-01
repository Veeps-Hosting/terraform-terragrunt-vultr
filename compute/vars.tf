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
  description = "Ubuntu 24.04 LTS 64 Bit"
  default     = "2284"
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
  default = "client_v1"
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
