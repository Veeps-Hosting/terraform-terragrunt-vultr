output "id" {
  value = vultr_database.db.id
}
output "host" {
  value = vultr_database.db.host
}
output "port" {
  value = vultr_database.db.port
}
output "dbname" {
  value = vultr_database.db.dbname
}
output "user" {
  value = vultr_database.db.user
}
output "password" {
  value     = vultr_database.db.password
  sensitive = true
}
