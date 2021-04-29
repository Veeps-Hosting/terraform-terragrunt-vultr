variable "resource_domain" {
  description = "Domain for resource lookups"
  type        = string
}

variable "resource_domain_apex_ip" {
  description = "Vultr mandated Apex record"
  default     = "127.0.0.1"
  type        = string
}
