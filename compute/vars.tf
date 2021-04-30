variable "activation_email" {
  default = false
}
variable "backups" {
  default = "enabled"
}
variable "domain" {
}
variable "enable_ipv6" {
  default = true
}
variable "enable_private_network" {
  default = false
}
variable "firewall_group" {
  default = "web_ssh_ping"
}
variable "hostname" {
}
variable "os_id" {
  description = "Ubuntu 20.04 LTS 64 Bit"
  default     = "387"
}
variable "plan" {
  default = "vc2-1c-1gb"
}
variable "private_network_ids" {
  default = "null"
}
variable "region" {
  default = "syd"
}
variable "startup_script" {
  default = "bootstrap"
}
variable "ssh_key" {
}
