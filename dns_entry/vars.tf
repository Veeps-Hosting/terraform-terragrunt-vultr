variable "data" {
  type = string
}
variable "domain" {
  type    = string
}
variable "name" {
  type = string
}
variable "ttl" {
  default = "120"
  type    = string
}
variable "type" {
  default = "A"
  type    = string
}
