# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR VIRTUAL SERVER
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_version = ">= 1.12.0"
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "~> 2.32"
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
  reserved_ip_id         = local.reserved_ip_id
  script_id              = var.adopt_existing ? null : data.vultr_startup_script.script.id
  ssh_key_ids            = var.adopt_existing ? null : [data.vultr_ssh_key.key.id]
  vpc_ids                = var.vpc_ids

  lifecycle {
    ignore_changes = [reserved_ip_id]

    precondition {
      condition     = !(var.reserved_ip && var.reserved_ip_existing != "")
      error_message = "Set reserved_ip to make a new reserved IP, or reserved_ip_existing to use one that already exists. Not both."
    }
  }
}

# Which reserved IPv4 the instance boots on, if any.
#
# reserved_ip makes a new one for this server. reserved_ip_existing points at
# one that already exists, found by label - used when an existing server's
# address was converted out of band, and when a replacement server inherits the
# address of a decommissioned one.
#
# Vultr only accepts this in the instance CREATE call, so it decides the main IP
# of a server being built and can never move the main IP of a server already
# running. A replacement therefore has to be built AFTER the server it replaces
# is gone, or the lookup finds an address still attached to the old instance.
locals {
  reserved_ip_id = (
    var.reserved_ip ? vultr_reserved_ip.reserved_ip[0].id :
    var.reserved_ip_existing != "" ? data.vultr_reserved_ip.existing[0].id :
    null
  )
}

# An existing reserved IP, looked up by label the same way this module already
# looks up the ssh key, startup script and firewall group. Nothing about it is
# managed here: it is not in this leaf's state, so no apply can duplicate it and
# no destroy can delete it.
data "vultr_reserved_ip" "existing" {
  count = var.reserved_ip_existing != "" ? 1 : 0
  filter {
    name   = "label"
    values = [var.reserved_ip_existing]
  }
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

# Optionally, a reserved IPv4 used as the instance's MAIN IP.
#
# Deliberately carries no instance_id: the attachment is made by the instance
# itself via reserved_ip_id at create time, which is the only way Vultr will
# make a reserved address the main IP. Setting instance_id here instead would
# add the address as a secondary one that nothing points at.
resource "vultr_reserved_ip" "reserved_ip" {
    count   = var.reserved_ip ? 1 : 0
    label   = var.reserved_ip_label != "" ? var.reserved_ip_label : "${var.hostname}-reserved-ip"
    region  = var.region
    ip_type = var.reserved_ip_type

    lifecycle {
      prevent_destroy = true
    }
}

# Optionally, a reserved IPv6 /64 so the instance's IPv6 allocation survives a
# rebuild.
#
# This one is the mirror image of the v4 resource above. InstanceCreateReq has
# only reserved_ipv4, so a reserved /64 cannot be a main IP; attaching is the
# only mode Vultr offers, and the attachment therefore lives here. That is also
# what re-attaches the subnet after the instance is replaced.
#
# The instance keeps its own RA-assigned /64 as v6_main_ip and the reserved one
# arrives as a secondary_ip, so the IPv6 PTR above still follows the ephemeral
# address. The guest OS does NOT configure the reserved subnet by itself - the
# router only advertises the ephemeral prefix - so a static address out of this
# /64 has to be added to netplan for anything to use it.
resource "vultr_reserved_ip" "reserved_ipv6" {
    count       = var.reserved_ipv6 ? 1 : 0
    label       = var.reserved_ipv6_label != "" ? var.reserved_ipv6_label : "${var.hostname}-reserved-ipv6"
    region      = var.region
    ip_type     = "v6"
    instance_id = vultr_instance.server.id

    lifecycle {
      prevent_destroy = true
    }
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
