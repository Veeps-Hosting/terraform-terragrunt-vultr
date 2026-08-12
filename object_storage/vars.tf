variable "label" {
  type = string
}
variable "cluster_id" {
  # Vultr object-storage cluster id (an integer, NOT a region code). List with:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/object-storage/clusters
  # A Sydney cluster does exist: id 13, syd1.vultrobjects.com (verified 2026-08-12).
  type = number
}
variable "tier_id" {
  # Required by the vultr provider from 2.32 onwards - object storage is tiered
  # and the tier must be set explicitly. Deliberately has no default: the tiers
  # differ threefold in per-GB price, so this is a billing decision that belongs
  # in the leaf rather than a silent module default. List with:
  #   curl -s -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/object-storage/tiers
  # As at 2026-08-12: 1=Legacy, 2=Standard, 3=Premium, 4=Performance,
  # 5=Accelerated, 6=Archival. Standard stores at $0.018/GB and Archival at
  # $0.006/GB, both at the same 600 MB/s op rate limit.
  type = number
}
