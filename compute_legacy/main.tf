# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR VIRTUAL SERVER
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.11.3"
    }
  }
}
provider "vultr" {}

# Server
resource "vultr_instance" "server" {
  activation_email       = var.activation_email
  backups                = var.backups
  backups_schedule {
    hour = var.backups_schedule_hour
    type = var.backups_schedule_type
  }
  enable_ipv6            = var.enable_ipv6
  firewall_group_id      = data.vultr_firewall_group.group.id
  hostname               = "${var.hostname}.${var.domain}"
  label                  = var.hostname
  os_id                  = var.os_id
  plan                   = var.plan
  private_network_ids    = var.private_network_id
  region                 = var.region
}

# Forward IPv4 Hostname FQDN DNS Entry
resource "vultr_dns_record" "hostname_dns_entry" {
  domain = var.domain
  name   = var.hostname
  data   = vultr_instance.server.main_ip
  type   = "A"
  ttl    = 120
}

# Reverse IPv4 Hostname FQDN PTR DNS Entry
resource "vultr_reverse_ipv4" "ipv4_ptr_entry" {
  instance_id = vultr_instance.server.id
  ip          = vultr_instance.server.main_ip
  reverse     = "${var.hostname}.${var.domain}"
}

# Reverse IPv6 Hostname FQDN PTR DNS Entry
resource "vultr_reverse_ipv6" "ipv6_ptr_entry" {
  instance_id = vultr_instance.server.id
  ip          = vultr_instance.server.v6_main_ip
  reverse     = "${var.hostname}.${var.domain}"
}

# Find the ID of an existing Firewall Group
data "vultr_firewall_group" "group" {
  filter {
    name   = "description"
    values = [var.firewall_group]
  }
}
