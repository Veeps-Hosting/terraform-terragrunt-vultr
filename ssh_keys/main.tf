# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CONFIGURE VULTR DNS ENTRY
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend var.backend_remotestate {}
  required_providers {
    vultr = {
      source = "vultr/vultr"
<<<<<<< HEAD
      version = "2.8.1"
=======
      version = "2.3.3"
>>>>>>> 8095ca569d75fab994e729d9c9f826ddb575f854
    }
  }
}
provider "vultr" {
  # In your .bashrc you need to set
  # export VULTR_API_KEY="Your Vultr API Key"
}

resource "vultr_ssh_key" "ssh_key" {
  for_each = var.users_keys
  name     = each.key
  ssh_key  = each.value
}
