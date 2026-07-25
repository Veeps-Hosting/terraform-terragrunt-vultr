output "id" {
  value = vultr_object_storage.bucket.id
}
output "s3_hostname" {
  value = vultr_object_storage.bucket.s3_hostname
}
output "s3_access_key" {
  value     = vultr_object_storage.bucket.s3_access_key
  sensitive = true
}
output "s3_secret_key" {
  value     = vultr_object_storage.bucket.s3_secret_key
  sensitive = true
}
