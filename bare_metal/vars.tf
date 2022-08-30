variable "activation_email" {
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
  default = "vbm-6c-32gb"
}
variable "region" {
  default = "syd"
}
variable "startup_script" {
  default = "bootstrap"
}
variable "ssh_key" {
}
