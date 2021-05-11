# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR BLOCK STORAGE, NOT VAILABLE IN ALL REGIONS!
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.3.0"
    }
  }
}
provider "vultr" {}

resource "vultr_block_storage" "block_storage" {
  attached_to_instance = data.vultr_instance.server.id
  label                = var.label
  live                 = var.live
  region               = var.region
  size_gb              = var.size_gb
}

# Find the Server ID to attach the Block Storage to
data "vultr_instance" "server" {
  filter {
    name   = "label"
    values = [var.attach_to]
  }
}
