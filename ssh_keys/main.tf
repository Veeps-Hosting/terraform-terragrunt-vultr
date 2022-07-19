# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR SSH KEY
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

resource "vultr_ssh_key" "ssh_key" {
  for_each = var.users_keys
  name     = each.key
  ssh_key  = each.value
}
