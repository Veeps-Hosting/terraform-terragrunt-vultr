# --- cluster connection (from vke module outputs, base64-encoded PEM) ---
variable "cluster_endpoint" {
  # vke's `endpoint` output: bare host/IP (becomes https://<host>:6443) or a
  # full https:// URL; both are accepted (local.api_url).
  type = string
}
variable "client_certificate" {
  type      = string
  sensitive = true
}
variable "client_key" {
  type      = string
  sensitive = true
}
variable "cluster_ca_certificate" {
  type      = string
  sensitive = true
}

# --- keycloak ---
variable "namespace" {
  default = "keycloak"
}
variable "hostname" {
  # Public FQDN and the ONLY name baked into KC_HOSTNAME (issuer, redirect and
  # admin-console URLs). Staging: keycloak.staging.webqem.net. Prod stands up
  # as identity-k8s.veepshosting.net and only becomes identity.veepshosting.net
  # at the approved cutover.
  type = string
}
variable "extra_hostnames" {
  # Additional names the ingresses answer on and the certificate covers
  # (e.g. the kc4.staging alias later). NOT used for KC_HOSTNAME - Keycloak
  # keeps generating URLs on var.hostname. Only add a name once its DNS
  # already points at the LB: cert-manager orders one certificate for the
  # whole host list, so one failing HTTP-01 blocks them all.
  default = []
  type    = list(string)
}
variable "keycloak_version" {
  # quay.io/keycloak/keycloak image tag. 26.7.3 = chart 7.3.1 appVersion;
  # wqkc3/wqkc4 run 26.7.2, so the realm export imports cleanly.
  default = "26.7.3"
}
variable "keycloakx_chart_version" {
  # codecentric keycloakx chart. Templates/values verified against tag
  # keycloakx-7.3.1 (service names, selector labels, tpl'd extra* strings).
  default = "7.3.1"
}
variable "replicas" {
  default = 2
}
variable "cluster_issuer" {
  # cert-manager ClusterIssuer created by k8s_baseline.
  default = "letsencrypt-prod"
}
variable "admin_whitelist_cidrs" {
  # restricted_to_wq carry-forward: sources allowed to reach /auth/admin,
  # /auth/welcome and the master realm. An empty list FAILS CLOSED - the
  # ingress whitelist collapses to 127.0.0.1/32, so a forgotten value denies
  # the admin console everywhere rather than opening it.
  default = []
  type    = list(string)
}
variable "monitor_cidrs" {
  # Icinga masters (wqmon1/wqmon2) allowed to reach /auth/health and
  # /auth/metrics via the mgmt ingress, in addition to admin_whitelist_cidrs.
  # Same fail-closed rule as above.
  default = []
  type    = list(string)
}
variable "scope_fix_realms" {
  # Realms whose /protocol/openid-connect/auth endpoint gets `scope=openid`
  # appended when a client omits it (carry-forward of the nginx_keycloak
  # raw_prepend on wqkc3/wqkc4). "master" is handled on the admin ingress
  # because its whole realm path sits behind the whitelist; a separate
  # longer-path ingress for it would bypass that whitelist.
  default = ["webqem", "master"]
  type    = list(string)
}

# --- database (from managed_database module outputs) ---
variable "db_host" {
  type = string
}
variable "db_port" {
  type = string
}
variable "db_name" {
  type = string
}
variable "db_user" {
  type = string
}
variable "db_password" {
  type      = string
  sensitive = true
}
variable "db_sslmode" {
  # libpq/JDBC sslmode. Vultr managed PG requires TLS; "require" without CA
  # pinning matches how the fleet connects today. Ignored (forced to
  # verify-full) once db_ca_certificate is set.
  default = "require"
}
variable "db_ca_certificate" {
  # CA that signs the managed database's server certificate: the PEM itself
  # or base64 of the PEM (how it travels through a JSON secret). Empty = no
  # pinning, db_sslmode as today. Set = KC_DB_URL and PG* switch to
  # sslmode=verify-full with this CA for Keycloak and both backup jobs.
  # verify-full also checks db_host against the certificate's SAN, so prove
  # it first from jenkci1: psql "host=<db_host> sslmode=verify-full
  # sslrootcert=ca.crt ...". Not sensitive: a CA is public material.
  default   = ""
  type      = string
  sensitive = false
  validation {
    condition     = var.db_ca_certificate == "" || startswith(trimspace(var.db_ca_certificate), "-----BEGIN") || can(regex("^\\s*-----BEGIN", base64decode(var.db_ca_certificate)))
    error_message = "db_ca_certificate must be empty, a PEM (-----BEGIN ...), or the base64 of a PEM."
  }
}
variable "db_pool_max_size" {
  # Per-pod Agroal pool cap (KC_DB_POOL_MAX_SIZE). Keycloak's default is 100
  # per pod; the business-cc-1-55-2 plan allows 97 connections in total, so
  # two pods at the default could exhaust the cluster. 40 x 2 leaves room for
  # the backup jobs, the migration tools pod and an admin psql session.
  default = 40
  type    = number
}

# --- bootstrap admin (SEC-02 rotation at first prod deploy; SM only) ---
variable "admin_user" {
  default = "admin"
}
variable "admin_password" {
  # Only consulted on the very first start of an empty master realm. After the
  # realm import the admin user from the source instance wins, and the value
  # here is rotated onto it with kcadm (migration step 5). Empty = the module
  # generates one (random_password, DESIGN §8) and exposes it as the
  # bootstrap_admin_password output, so a missing SM secret never fails the
  # plan. The leaves pass veeps/tf/keycloak-k8s/<env>.keycloak_admin_password.
  default   = ""
  type      = string
  sensitive = true
}

# --- runtime ---
variable "passkeys_enabled" {
  # passkeys:v1 is supported and on by default from Keycloak 26.4; this keeps
  # the explicit KC_FEATURES / KC_FEATURES_DISABLED pair the compose template
  # on wqkc3/wqkc4 uses so the two platforms cannot silently differ.
  default = true
  type    = bool
}
variable "log_level" {
  # KC_LOG_LEVEL root level. Login/admin events are logged at info/warn via
  # the jboss-logging events listener regardless.
  default = "INFO"
}
variable "resources" {
  # Keycloak container requests/limits. No CPU limit on purpose: JVM startup
  # (the auto-build on `kc.sh start`) is bursty and a CPU cap turns it into
  # startup-probe failures. Heap is sized by MaxRAMPercentage from the memory
  # limit.
  type = object({
    requests = optional(map(string), { cpu = "500m", memory = "1Gi" })
    limits   = optional(map(string), { memory = "1536Mi" })
  })
  default = {}
}
variable "java_opts_append" {
  # Extra JVM flags (JAVA_OPTS_APPEND). Empty = not set.
  default = ""
}

# --- login theme ---
variable "theme_enabled" {
  default = true
  type    = bool
}
variable "theme_tarball_path" {
  # Path to the theme tarball. Empty = the copy shipped in this module,
  # files/keycloak_themes_23_kc26.tgz (variable defaults cannot reference
  # path.module, hence the empty sentinel). Must extract to a top-level
  # <theme_name>/ directory.
  default = ""
}
variable "theme_name" {
  # Directory the tarball extracts to; the init container asserts
  # /opt/keycloak/themes/<theme_name> exists so a repacked tarball with a
  # different layout fails the pod instead of silently serving the stock
  # theme.
  default = "webqemveeps"
}
variable "theme_init_image" {
  # Untars the theme ConfigMap. Same busybox the chart's dbchecker uses.
  default = "docker.io/busybox:1.37"
}

# --- backups (Vultr object storage, pulled nightly by bak3) ---
variable "backups_enabled" {
  # Off by default so the module plans without an object_storage dependency;
  # the staging/prod leaves turn it on and wire the ../../backups outputs in.
  default = false
  type    = bool
}
variable "backup_s3_hostname" {
  # object_storage module s3_hostname output, e.g. syd1.vultrobjects.com.
  default = ""
}
variable "backup_s3_access_key" {
  default   = ""
  sensitive = true
}
variable "backup_s3_secret_key" {
  default   = ""
  sensitive = true
}
variable "backup_bucket" {
  # Created through the S3 API on first run if missing (object_storage only
  # provisions the subscription). The leaves pass one bucket per environment
  # (kck8s-backups-stg / kck8s-backups-prod); this default is only a
  # stand-in for ad-hoc plans.
  default = "kck8s-backups"
}
variable "backup_prefix" {
  # Top-level key prefix inside the bucket. Empty = var.hostname, which also
  # keeps two hostnames apart should they ever share a bucket.
  default = ""
}
variable "backup_pgdump_schedule" {
  # CronJob schedules are UTC. 15:00 UTC = 01:00/02:00 Sydney, ahead of the
  # 17:10 UTC bak3 rclone pull.
  default = "0 15 * * *"
}
variable "backup_realm_export_schedule" {
  # Weekly, Sunday 15:30 UTC. The export is the migration-format artefact
  # (realm JSON incl. users and client secrets), not the disaster-recovery one.
  default = "30 15 * * 0"
}
variable "backup_retention_days" {
  # Objects older than this under <prefix>/<kind>/ are deleted by upload.sh.
  # bak3's rsnapshot rotation holds the long tail.
  default = 35
  type    = number
}
variable "backup_postgres_image" {
  # pg_dump major must be >= the server major (managed PG 17).
  default = "docker.io/library/postgres:17-alpine"
}
variable "backup_awscli_image" {
  default = "docker.io/amazon/aws-cli:2.27.0"
}
