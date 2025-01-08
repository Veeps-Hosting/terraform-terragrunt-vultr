# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR VIRTUAL SERVER
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.19.0"
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
  ddos_protection        = var.ddos_protection
  enable_ipv6            = var.enable_ipv6
  firewall_group_id      = data.vultr_firewall_group.group.id
  hostname               = "${var.hostname}.${var.domain}"
  label                  = var.hostname
  os_id                  = var.os_id
  plan                   = var.plan
  region                 = var.region
  script_id              = data.vultr_startup_script.script.id
  ssh_key_ids            = [data.vultr_ssh_key.key.id]
  vpc_ids                = var.vpc_ids
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

# Optionally, add a Reserved IPv4
resource "vultr_reserved_ip" "reserved_ipv4" {
    count       = var.reserved_ipv4 ? 1 : 0
    label       = "${var.hostname}-reserved-ipv4"
    region      = var.region
    ip_type     = "v4"
    instance_id = vultr_instance.server.id
}

# Optionally, add a Reserved IPv6
resource "vultr_reserved_ip" "reserved_ipv4" {
    count       = var.reserved_ipv6 ? 1 : 0
    label       = "${var.hostname}-reserved-ipv6"
    region      = var.region
    ip_type     = "v6"
    instance_id = vultr_instance.server.id
}

# Find the ID of an existing SSH key.
data "vultr_ssh_key" "key" {
  filter {
    name   = "name"
    values = [var.ssh_key]
  }
}

# Find the ID of an existing Startup Script
data "vultr_startup_script" "script" {
  filter {
    name   = "name"
    values = [var.startup_script]
  }
}

# Find the ID of an existing Firewall Group
data "vultr_firewall_group" "group" {
  filter {
    name   = "description"
    values = [var.firewall_group]
  }
}
