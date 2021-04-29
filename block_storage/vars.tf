variable "attach_to" {
  description = "Server to attach to"
  type        = string
}

variable "label" {
  description = "Description for Label"
  type        = string
}

variable "live" {
  default     = true
  description = "Allow attachment to instance without a restart"
  type        = bool
}

variable "region" {}

variable "size_gb" {
  type    = number
  default = 1000
}
