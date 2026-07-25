variable "label" {
  type = string
}
variable "cluster_id" {
  # Vultr object-storage cluster id (an integer, NOT a region code). List with:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/object-storage/clusters
  # Confirm whether a Sydney cluster exists before first apply; otherwise pick
  # the nearest cluster and record the choice in the design doc.
  type = number
}
