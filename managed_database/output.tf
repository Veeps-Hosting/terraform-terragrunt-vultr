output "id" {
  value = vultr_database.db.id
}
# Private address when VPC-attached, otherwise the same as public_host.
output "host" {
  value = vultr_database.db.host
}
output "public_host" {
  value = vultr_database.db.public_host
}
# A string, as the provider exports it; fine for a JDBC URL.
output "port" {
  value = vultr_database.db.port
}
# Vultr's default logical database and admin user - the keycloak leaf uses
# these directly rather than creating its own.
output "dbname" {
  value = vultr_database.db.dbname
}
output "user" {
  value = vultr_database.db.user
}
# Sensitive here because the provider does not mark it so; without this it
# prints in plan output and terragrunt dependency listings.
output "password" {
  value     = vultr_database.db.password
  sensitive = true
}
output "status" {
  value = vultr_database.db.status
}
# PEM of the CA that signed the server certificate. Not sensitive: it is the
# public half, and the keycloak leaf needs it in a ConfigMap for
# sslmode=verify-full (require would accept any certificate on the way to a
# private host; verify-full pins the CA and checks the hostname).
output "ca_certificate" {
  value = vultr_database.db.ca_certificate
}
output "vpc_id" {
  value = vultr_database.db.vpc_id
}
