# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR FIREWALL GROUPS & RULE(S)
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

resource "vultr_firewall_group" "fwgroup" {
  for_each    = var.fwgroup
  description = each.key
}

## Setup null values for optional parameters so they're
## not created if absent, whilst providing sensible defaults
## for required parameters that can be overridden from variables

resource "vultr_firewall_rule" "fwrule" {
  depends_on        = [vultr_firewall_group.fwgroup]
  for_each          = var.fwrule

  firewall_group_id = vultr_firewall_group.fwgroup[each.value.fwgroup].id
  protocol          = tostring(try(each.value.proto, "tcp"))
  ip_type           = tostring(try(each.value.ip_type, "v4"))
  source            = tostring(try(each.value.source, null))
  subnet            = tostring(try(each.value.subnet, "0.0.0.0"))
  subnet_size       = tonumber(try(each.value.subnet_size, 0))
  port              = tostring(try(each.value.port, null))
  notes             = tostring(try(each.value.notes, null))

  # The Vultr provider stores `source` as a computed CIDR (e.g. "0.0.0.0/0")
  # derived from subnet/subnet_size, but only accepts "" or "cloudflare" as
  # input. Because `source` is ForceNew, that mismatch makes every plan want to
  # destroy/recreate existing rules. Ignore drift on it so rules stay in place.
  lifecycle {
    ignore_changes = [source]
  }
}
