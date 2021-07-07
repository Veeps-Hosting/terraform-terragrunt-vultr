# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR DNS ENTRY
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_providers {
    vultr = {
      source = "vultr/vultr"
      version = "2.3.3"
    }
  }
}
provider "vultr" {
  # In your .bashrc you need to set
  # export VULTR_API_KEY="Your Vultr API Key"
}

resource "vultr_dns_record" "dns_entry" {
  domain = var.domain
  name   = var.name
  type   = var.type
  data   = var.data
  ttl    = var.ttl
}
