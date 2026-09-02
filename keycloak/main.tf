# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# KEYCLOAK ON VKE — HA Keycloak 26.7 via the codecentric keycloakx chart.
# Design decisions carried in from Monday 2801647539 (build contract 2026-09-02):
#   * KC_HTTP_RELATIVE_PATH=/auth kept at migration (zero client changes).
#   * 2 replicas, Infinispan over jdbc-ping (chart default, no RBAC/DNS
#     discovery needed), PDB minAvailable 1, required anti-affinity per node.
#   * TLS at ingress-nginx. Four Ingress objects on the same host: public
#     /auth; admin paths behind the restricted_to_wq whitelist; per-realm
#     scope fix; management (health/metrics) behind monitor + admin CIDRs.
#     Whitelists fail CLOSED (127.0.0.1/32) when a list is empty.
#   * DB is Vultr Managed PostgreSQL (managed_database module outputs).
#   * Login theme from the openvox tarball, untarred into an emptyDir by an
#     init container so the stock image is never rebuilt.
#   * Backups: nightly pg_dump + weekly realm export to Vultr object storage,
#     pruned by age; bak3 pulls the bucket into rsnapshot rotation.
#   * Secrets arrive as sensitive TF vars (AWS SM via terragrunt) — never in git.
#     An empty admin_password falls back to a module-generated one (DESIGN §8)
#     so a missing SM secret degrades to "bootstrap admin lives in TF state",
#     never to a failed plan.
#   * Read-only icinga-monitor ServiceAccount + long-lived token for
#     check_vke_platform on the Icinga masters (nodes, statefulsets, certs).
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
terraform {
  backend "s3" {}
  required_version = ">= 1.12.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # Kept in lock-step with k8s_baseline so both modules share one plugin
    # cache and one set of version constraints; also the provider to reach
    # for if a CRD-typed object (Certificate, etc.) is ever needed here.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    # Fallback bootstrap admin password when the leaf passes none (DESIGN §8).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  # vke's `endpoint` output is the bare host/IP of the API server; the
  # providers need a URL. Accept either form so a leaf that already passes
  # https://... keeps working.
  api_url = can(regex("^https?://", var.cluster_endpoint)) ? var.cluster_endpoint : "https://${var.cluster_endpoint}:6443"
}

provider "kubernetes" {
  host                   = local.api_url
  client_certificate     = base64decode(var.client_certificate)
  client_key             = base64decode(var.client_key)
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = local.api_url
    client_certificate     = base64decode(var.client_certificate)
    client_key             = base64decode(var.client_key)
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = local.api_url
  client_certificate     = base64decode(var.client_certificate)
  client_key             = base64decode(var.client_key)
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  load_config_file       = false
}

locals {
  # Every ingress carries every host: if the alias only existed on the public
  # ingress, /auth/admin on the alias would fall through to the unrestricted
  # /auth rule and bypass the whitelist.
  all_hosts = distinct(concat([var.hostname], var.extra_hostnames))

  # Release "keycloak" + chart "keycloakx" => fullname keycloak-keycloakx
  # (chart _helpers.tpl), so the chart's Service is keycloak-keycloakx-http.
  http_service = "keycloak-keycloakx-http"
  mgmt_service = "keycloak-mgmt"
  tls_secret   = "keycloak-tls"

  # Whitelists fail closed: an empty list becomes loopback-only, which denies
  # everything at the edge instead of silently opening the admin console.
  admin_whitelist = length(var.admin_whitelist_cidrs) > 0 ? join(",", var.admin_whitelist_cidrs) : "127.0.0.1/32"
  mgmt_cidrs      = distinct(concat(var.monitor_cidrs, var.admin_whitelist_cidrs))
  mgmt_whitelist  = length(local.mgmt_cidrs) > 0 ? join(",", local.mgmt_cidrs) : "127.0.0.1/32"

  # nginx_keycloak raw_prepend carry-forward. `set $args` clears nginx's
  # valid_unparsed_uri so proxy_pass rebuilds the query string. $${args} is
  # the HCL escape for a literal ${args}.
  scope_fix_snippet = "if ($args !~ \"scope=\") { set $args \"$${args}&scope=openid\"; }"
  scope_fix_realms  = toset([for r in var.scope_fix_realms : r if r != "master"])

  # Same per-location proxy settings the fleet nginx uses in front of wqkc3/4.
  # proxy-buffer-size: Keycloak's cookie-laden responses overflow the 4k
  # default and surface as 502s (documented in the chart's values.yaml).
  proxy_annotations = {
    "nginx.ingress.kubernetes.io/proxy-read-timeout" = "600"
    "nginx.ingress.kubernetes.io/proxy-send-timeout" = "600"
    "nginx.ingress.kubernetes.io/proxy-body-size"    = "16m"
    "nginx.ingress.kubernetes.io/proxy-buffer-size"  = "128k"
  }

  theme_tarball = var.theme_tarball_path != "" ? var.theme_tarball_path : "${path.module}/files/keycloak_themes_23_kc26.tgz"

  # Keycloak image runs as uid 1000 (chart securityContext) and the chart's
  # podSecurityContext fsGroup 1000 makes the emptyDir group-writable — but
  # the mount root itself stays root-owned, so any chmod/chown that touches
  # the root is EPERM for uid 1000 and kills the script under set -e. Extract
  # into the mount, then fix modes ONLY on the extracted top-level entries so
  # whatever modes the tarball carries, the server can read the theme.
  theme_init_script = <<-EOT
    set -eu
    tar -xzf /theme/themes.tgz -C /opt/keycloak/themes
    test -d /opt/keycloak/themes/${var.theme_name} || { echo "theme ${var.theme_name}/ not found in tarball" >&2; exit 1; }
    for d in /opt/keycloak/themes/*; do chmod -R u+rwX,go+rX "$d"; done
    ls -la /opt/keycloak/themes /opt/keycloak/themes/${var.theme_name}
  EOT

  # DESIGN §8: an empty admin_password means "generate one". It only ever
  # seeds an empty master realm and is superseded by the imported admin.
  admin_password = var.admin_password != "" ? var.admin_password : random_password.admin[0].result

  # DB CA pinning. Accept the PEM itself or its base64 (how a CA usually
  # travels through a JSON secret); anything else fails the plan in vars.tf.
  db_ca_enabled = var.db_ca_certificate != ""
  db_ca_pem     = local.db_ca_enabled ? (startswith(trimspace(var.db_ca_certificate), "-----BEGIN") ? var.db_ca_certificate : base64decode(var.db_ca_certificate)) : ""
  db_ca_dir     = "/etc/keycloak/db-ca"
  db_ca_file    = "${local.db_ca_dir}/ca.crt"
  # verify-full (CA + hostname) once a CA is pinned; otherwise today's
  # unpinned var.db_sslmode. One URL feeds Keycloak and the realm export.
  db_sslmode = local.db_ca_enabled ? "verify-full" : var.db_sslmode
  kc_db_url  = "jdbc:postgresql://${var.db_host}:${var.db_port}/${var.db_name}?sslmode=${local.db_sslmode}${local.db_ca_enabled ? "&sslrootcert=${local.db_ca_file}" : ""}"

  # The chart takes extraVolumes/extraVolumeMounts as ONE string each, so
  # the theme and the DB CA (independently optional) are composed here as a
  # filter over a tuple literal. NOT concat()/conditionals of differing
  # shapes: those unify the element types, and objects that differ only by a
  # bool attribute collapse to map(string) — readOnly = true became the
  # string "true", which the API server rejects.
  extra_volumes = [for v in [
    { on = var.theme_enabled, spec = { name = "theme-archive", configMap = { name = try(kubernetes_config_map_v1.keycloak_theme[0].metadata[0].name, "keycloak-theme") } } },
    { on = var.theme_enabled, spec = { name = "themes", emptyDir = {} } },
    # Only the CA key is projected: the same Secret carries the DB password,
    # which must never land on disk in the pod.
    { on = local.db_ca_enabled, spec = { name = "db-ca", secret = { secretName = kubernetes_secret_v1.keycloak_db.metadata[0].name, items = [{ key = "ca.crt", path = "ca.crt" }] } } },
  ] : v.spec if v.on]
  # /opt/keycloak/themes is empty in the stock image (built-in themes live
  # in the jar), so masking it with the emptyDir loses nothing. Same volume
  # name and path as the theme init container, which is what makes the
  # extracted theme visible to the server. The CA mounts as a directory
  # (not subPath) so a rotated Secret propagates without a pod restart.
  extra_volume_mounts = [for v in [
    { on = var.theme_enabled, spec = { name = "themes", mountPath = "/opt/keycloak/themes" } },
    { on = local.db_ca_enabled, spec = { name = "db-ca", mountPath = local.db_ca_dir, readOnly = true } },
  ] : v.spec if v.on]

  # Everything the chart does NOT already set from values. proxy/http/health/
  # metrics/cache/KC_DB come from chart values (see helm_release) so no env
  # name is emitted twice. SPI options use the 26.x double-dash form
  # (spi-<spi>--<provider>--<option> => KC_SPI_<SPI>__<PROVIDER>__<OPTION>).
  keycloak_env = concat(
    [
      # hostname:v2 full URL: the path here overrides KC_HTTP_RELATIVE_PATH
      # in every generated link, so /auth must be included.
      { name = "KC_HOSTNAME", value = "https://${var.hostname}/auth" },
      { name = "KC_DB_POOL_MAX_SIZE", value = tostring(var.db_pool_max_size) },
      { name = "KC_LOG_CONSOLE_OUTPUT", value = "json" },
      { name = "KC_LOG_LEVEL", value = var.log_level },
      { name = "KC_SPI_EVENTS_LISTENER__JBOSS_LOGGING__SUCCESS_LEVEL", value = "info" },
      { name = "KC_SPI_EVENTS_LISTENER__JBOSS_LOGGING__ERROR_LEVEL", value = "warn" },
      { name = var.passkeys_enabled ? "KC_FEATURES" : "KC_FEATURES_DISABLED", value = "passkeys" },
    ],
    var.java_opts_append != "" ? [{ name = "JAVA_OPTS_APPEND", value = var.java_opts_append }] : [],
  )

  backup_prefix = var.backup_prefix != "" ? var.backup_prefix : var.hostname

  # aws-cli >= 2.23 sends CRC trailers that Ceph-based S3 stores reject;
  # when_required restores the pre-2.23 behaviour (harmless on AWS). Region is
  # mandatory for SigV4 even with --endpoint-url: on AWS it must match the
  # bucket's region (ap-southeast-2 for the veeps-kck8s-backups-* buckets);
  # Vultr ignores its value.
  awscli_env = {
    AWS_DEFAULT_REGION               = var.backup_s3_region
    AWS_EC2_METADATA_DISABLED        = "true"
    AWS_REQUEST_CHECKSUM_CALCULATION = "when_required"
    AWS_RESPONSE_CHECKSUM_VALIDATION = "when_required"
    RETENTION_DAYS                   = tostring(var.backup_retention_days)
  }
}

resource "kubernetes_namespace_v1" "keycloak" {
  metadata {
    name = var.namespace
  }
}

# ---------------------------------------------------------------------------
# Secrets / ConfigMaps consumed by the chart and the backup jobs
# ---------------------------------------------------------------------------

# DB connection — host/port/user/password come from the managed_database leaf.
# KC_* feed Keycloak via envFrom; PG* feed pg_dump from the very same values so
# the backup can never point at a different database than the server. With a
# CA pinned, the same Secret also carries it as "ca.crt", which the pods
# mount at the path KC_DB_URL/PGSSLROOTCERT name — one Secret, one truth.
# (envFrom surfaces "ca.crt" as an env var too; harmless, it is public.)
resource "kubernetes_secret_v1" "keycloak_db" {
  metadata {
    name      = "keycloak-db"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = merge(
    {
      KC_DB_URL      = local.kc_db_url
      KC_DB_USERNAME = var.db_user
      KC_DB_PASSWORD = var.db_password
      PGHOST         = var.db_host
      PGPORT         = var.db_port
      PGDATABASE     = var.db_name
      PGUSER         = var.db_user
      PGPASSWORD     = var.db_password
      PGSSLMODE      = local.db_sslmode
    },
    local.db_ca_enabled ? {
      PGSSLROOTCERT = local.db_ca_file
      "ca.crt"      = local.db_ca_pem
    } : {},
  )
}

# Bootstrap admin credential — only used on the first start of an empty
# master realm; rotated onto the imported admin user afterwards (SEC-02).
resource "kubernetes_secret_v1" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = {
    KC_BOOTSTRAP_ADMIN_USERNAME = var.admin_user
    KC_BOOTSTRAP_ADMIN_PASSWORD = local.admin_password
  }
}

# DESIGN §8 fallback: with no admin_password from the leaf (SM secret absent
# or unreadable), generate one here. It exists in TF state and the Secret
# above only; read it back with `terragrunt output -raw bootstrap_admin_password`.
# count may depend on a sensitive value (unlike for_each) — nothing about the
# password is disclosed by whether it is empty.
resource "random_password" "admin" {
  count = var.admin_password == "" ? 1 : 0

  length  = 32
  special = false
}

# Login theme tarball (168 KB, well under the 1 MiB ConfigMap ceiling). The
# init container untars it; the pod annotation below rolls the StatefulSet
# when the tarball changes.
resource "kubernetes_config_map_v1" "keycloak_theme" {
  count = var.theme_enabled ? 1 : 0

  metadata {
    name      = "keycloak-theme"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  binary_data = {
    "themes.tgz" = filebase64(local.theme_tarball)
  }
}

# ---------------------------------------------------------------------------
# Keycloak — codecentric keycloakx chart
# ---------------------------------------------------------------------------
resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://codecentric.github.io/helm-charts"
  chart      = "keycloakx"
  version    = var.keycloakx_chart_version
  namespace  = kubernetes_namespace_v1.keycloak.metadata[0].name

  # First start runs the Quarkus auto-build before the startup probe passes;
  # the helm default of 300s is too tight for two ordered replicas.
  timeout = 600

  values = [yamlencode({
    image = {
      repository = "quay.io/keycloak/keycloak"
      tag        = var.keycloak_version
    }
    replicas = var.replicas
    # The image has no default args; without this the pod prints kc.sh help.
    command = ["/opt/keycloak/bin/kc.sh", "start"]

    # /auth relative path kept at migration (decouples any later path change
    # from the platform migration). Probes follow it on the management port.
    http = {
      relativePath = "/auth"
    }

    # These render as KC_PROXY_HEADERS, KC_HTTP_ENABLED, KC_HEALTH_ENABLED and
    # KC_METRICS_ENABLED in the chart's env list.
    proxy = {
      enabled = true
      mode    = "xforwarded"
      http    = { enabled = true }
    }
    health  = { enabled = true }
    metrics = { enabled = true }

    # KC_CACHE=ispn + KC_CACHE_STACK=jdbc-ping: discovery through the DB, no
    # pod-list RBAC and no headless-DNS query needed.
    cache = { stack = "default" }

    # vendor => KC_DB=postgres; hostname/port are what dbchecker probes with
    # nc before Keycloak starts. KC_DB_URL from the secret takes precedence
    # over the KC_DB_URL_HOST/PORT the chart also emits from these.
    database = {
      vendor   = "postgres"
      hostname = var.db_host
      port     = var.db_port
    }
    dbchecker = { enabled = true }

    # extraEnv / extraEnvFrom / extraInitContainers / extraVolumes /
    # extraVolumeMounts are STRINGS the chart passes through tpl, hence the
    # nested yamlencode.
    extraEnv = yamlencode(local.keycloak_env)
    extraEnvFrom = yamlencode([
      { secretRef = { name = kubernetes_secret_v1.keycloak_db.metadata[0].name } },
      { secretRef = { name = kubernetes_secret_v1.keycloak_admin.metadata[0].name } },
    ])

    extraInitContainers = var.theme_enabled ? yamlencode([{
      name    = "theme"
      image   = var.theme_init_image
      command = ["sh", "-c", local.theme_init_script]
      securityContext = {
        runAsUser                = 1000
        runAsGroup               = 1000
        runAsNonRoot             = true
        allowPrivilegeEscalation = false
      }
      resources = {
        requests = { cpu = "20m", memory = "32Mi" }
        limits   = { cpu = "200m", memory = "64Mi" }
      }
      volumeMounts = [
        { name = "theme-archive", mountPath = "/theme", readOnly = true },
        { name = "themes", mountPath = "/opt/keycloak/themes" },
      ]
    }]) : ""
    # Composed in locals (theme emptyDir + optional DB CA); "" keeps the
    # chart's own `with` guard from rendering an empty list.
    extraVolumes      = length(local.extra_volumes) > 0 ? yamlencode(local.extra_volumes) : ""
    extraVolumeMounts = length(local.extra_volume_mounts) > 0 ? yamlencode(local.extra_volume_mounts) : ""
    # Secret changes never roll a StatefulSet by themselves; hashing the
    # non-secret connection URL + CA rolls the pods when TLS pinning is
    # switched on/off or the CA is rotated.
    podAnnotations = merge(
      var.theme_enabled ? { "checksum/theme" = filesha256(local.theme_tarball) } : {},
      { "checksum/db-tls" = sha256("${local.kc_db_url}\n${local.db_ca_pem}") },
    )

    podDisruptionBudget = {
      minAvailable = 1
    }
    resources = var.resources

    # Chart default affinity (verified in 7.3.1 values.yaml) is a REQUIRED
    # podAntiAffinity on kubernetes.io/hostname over the selector labels plus
    # a preferred zone spread — exactly what is wanted, so it is not
    # overridden here.

    # Ingress is managed below (four objects), not by the chart, so the admin
    # whitelist and the scope fix cannot drift with chart moves.
    ingress        = { enabled = false }
    serviceMonitor = { enabled = false }
  })]

  depends_on = [
    kubernetes_secret_v1.keycloak_db,
    kubernetes_secret_v1.keycloak_admin,
    kubernetes_config_map_v1.keycloak_theme,
  ]
}

# Management interface (health + metrics, port 9000) under a name that does
# not depend on chart naming; Icinga's mgmt ingress and any in-cluster
# scraper point here.
resource "kubernetes_service_v1" "keycloak_mgmt" {
  metadata {
    name      = local.mgmt_service
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name"     = "keycloakx"
      "app.kubernetes.io/instance" = helm_release.keycloak.name
    }
    port {
      name        = "http-internal"
      port        = 9000
      target_port = 9000
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# Ingress — four objects on the same host(s). ingress-nginx merges them into
# one server block and nginx picks the longest matching location, so the
# whitelisted /auth/admin etc. win over the public /auth. Only the public
# ingress carries the cert-manager annotation; the others reference the
# same TLS secret so cert-manager orders exactly one certificate.
# ---------------------------------------------------------------------------

# Public: everything under /auth (login, tokens, account console, realms).
resource "kubernetes_ingress_v1" "keycloak" {
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = merge(local.proxy_annotations, {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer
    })
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = local.all_hosts
      secret_name = local.tls_secret
    }
    dynamic "rule" {
      for_each = local.all_hosts
      content {
        host = rule.value
        http {
          path {
            path      = "/auth"
            path_type = "Prefix"
            backend {
              service {
                name = local.http_service
                port {
                  number = 80
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.keycloak]
}

# Admin: console, the welcome page (static admin HTML residual from the old
# prod deployment) and the whole master realm, restricted_to_wq. The scope
# fix rides here for master because a separate longer-path ingress for
# /auth/realms/master/protocol/openid-connect/auth would sit outside this
# whitelist.
resource "kubernetes_ingress_v1" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = merge(local.proxy_annotations, {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.admin_whitelist
      "nginx.ingress.kubernetes.io/configuration-snippet"  = local.scope_fix_snippet
    })
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = local.all_hosts
      secret_name = local.tls_secret
    }
    dynamic "rule" {
      for_each = local.all_hosts
      content {
        host = rule.value
        http {
          dynamic "path" {
            for_each = ["/auth/admin", "/auth/welcome", "/auth/realms/master"]
            content {
              path      = path.value
              path_type = "Prefix"
              backend {
                service {
                  name = local.http_service
                  port {
                    number = 80
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.keycloak]
}

# Scope fix per public realm: clients that omit scope= on the authorization
# endpoint get scope=openid appended (nginx_keycloak carry-forward).
resource "kubernetes_ingress_v1" "keycloak_scopefix" {
  for_each = local.scope_fix_realms

  metadata {
    name      = "keycloak-scopefix-${each.key}"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = merge(local.proxy_annotations, {
      "nginx.ingress.kubernetes.io/configuration-snippet" = local.scope_fix_snippet
    })
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = local.all_hosts
      secret_name = local.tls_secret
    }
    dynamic "rule" {
      for_each = local.all_hosts
      content {
        host = rule.value
        http {
          path {
            path      = "/auth/realms/${each.key}/protocol/openid-connect/auth"
            path_type = "Prefix"
            backend {
              service {
                name = local.http_service
                port {
                  number = 80
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.keycloak]
}

# Management: /auth/health and /auth/metrics from the management port, for
# the Icinga masters (and admins) only. Keycloak does not serve these on
# 8080, so without this ingress they are unreachable from outside.
resource "kubernetes_ingress_v1" "keycloak_mgmt" {
  metadata {
    name      = "keycloak-mgmt"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/whitelist-source-range" = local.mgmt_whitelist
    }
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = local.all_hosts
      secret_name = local.tls_secret
    }
    dynamic "rule" {
      for_each = local.all_hosts
      content {
        host = rule.value
        http {
          dynamic "path" {
            for_each = ["/auth/health", "/auth/metrics"]
            content {
              path      = path.value
              path_type = "Prefix"
              backend {
                service {
                  name = kubernetes_service_v1.keycloak_mgmt.metadata[0].name
                  port {
                    number = 9000
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Backups — nightly pg_dump + weekly realm export to Vultr object storage.
# Layout: s3://<bucket>/<prefix>/pgdump/<prefix>-pgdump-<stamp>.sql.gz
#         s3://<bucket>/<prefix>/realm-export/<prefix>-realms-<stamp>.tgz
# Each Job = initContainer producing the artefact into an emptyDir, then the
# aws-cli container running files/upload.sh (upload + age-based prune).
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "keycloak_backup_s3" {
  count = var.backups_enabled ? 1 : 0

  metadata {
    name      = "keycloak-backup-s3"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = {
    AWS_ACCESS_KEY_ID     = var.backup_s3_access_key
    AWS_SECRET_ACCESS_KEY = var.backup_s3_secret_key
    S3_ENDPOINT           = "https://${var.backup_s3_hostname}"
    BUCKET                = var.backup_bucket
    PREFIX                = local.backup_prefix
  }

  lifecycle {
    # A Job that runs with blank credentials fails every night and never
    # backs anything up; refuse the plan instead.
    precondition {
      condition     = var.backup_s3_hostname != "" && var.backup_s3_access_key != "" && var.backup_s3_secret_key != ""
      error_message = "backups_enabled requires backup_s3_hostname, backup_s3_access_key and backup_s3_secret_key (wire the object_storage outputs in)."
    }
  }
}

resource "kubernetes_config_map_v1" "keycloak_backup_scripts" {
  count = var.backups_enabled ? 1 : 0

  metadata {
    name      = "keycloak-backup-scripts"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = {
    "pgdump.sh" = file("${path.module}/files/pgdump.sh")
    "upload.sh" = file("${path.module}/files/upload.sh")
  }
}

resource "kubernetes_cron_job_v1" "kc_pgdump" {
  count = var.backups_enabled ? 1 : 0

  metadata {
    name      = "kc-pgdump"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  spec {
    schedule                      = var.backup_pgdump_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    # A run missed by more than an hour (controller outage) is skipped, not
    # fired late on top of the next one.
    starting_deadline_seconds = 3600

    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy                  = "Never"
            automount_service_account_token = false

            init_container {
              name    = "pgdump"
              image   = var.backup_postgres_image
              command = ["/bin/sh", "/scripts/pgdump.sh"]
              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.keycloak_db.metadata[0].name
                }
              }
              env {
                name = "PREFIX"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.keycloak_backup_s3[0].metadata[0].name
                    key  = "PREFIX"
                  }
                }
              }
              resources {
                requests = { cpu = "100m", memory = "128Mi" }
                limits   = { memory = "512Mi" }
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              # PGSSLMODE/PGSSLROOTCERT arrive via envFrom keycloak-db; this
              # puts the CA where PGSSLROOTCERT points.
              dynamic "volume_mount" {
                for_each = local.db_ca_enabled ? [1] : []
                content {
                  name       = "db-ca"
                  mount_path = local.db_ca_dir
                  read_only  = true
                }
              }
            }

            container {
              name    = "upload"
              image   = var.backup_awscli_image
              command = ["/bin/sh", "/scripts/upload.sh"]
              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.keycloak_backup_s3[0].metadata[0].name
                }
              }
              env {
                name  = "BACKUP_KIND"
                value = "pgdump"
              }
              dynamic "env" {
                for_each = local.awscli_env
                content {
                  name  = env.key
                  value = env.value
                }
              }
              resources {
                requests = { cpu = "100m", memory = "128Mi" }
                limits   = { memory = "512Mi" }
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
            }

            volume {
              name = "backup"
              empty_dir {}
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.keycloak_backup_scripts[0].metadata[0].name
                default_mode = "0555"
              }
            }
            # Only the CA key of keycloak-db — never the password on disk.
            dynamic "volume" {
              for_each = local.db_ca_enabled ? [1] : []
              content {
                name = "db-ca"
                secret {
                  secret_name = kubernetes_secret_v1.keycloak_db.metadata[0].name
                  items {
                    key  = "ca.crt"
                    path = "ca.crt"
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_cron_job_v1" "kc_realm_export" {
  count = var.backups_enabled ? 1 : 0

  metadata {
    name      = "kc-realm-export"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  spec {
    schedule                      = var.backup_realm_export_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 3600

    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy                  = "Never"
            automount_service_account_token = false

            # Same image/DB as the live pods so the export format matches
            # what `kc.sh import` on this platform expects. The image runs as
            # uid 1000 and the emptyDir is world-writable, so no
            # securityContext is needed. tar is not guaranteed in the
            # ubi-micro based image; upload.sh packs the directory instead.
            init_container {
              name  = "export"
              image = "quay.io/keycloak/keycloak:${var.keycloak_version}"
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                rm -rf /backup/realms
                /opt/keycloak/bin/kc.sh export --dir /backup/realms --users different_files
                ls -l /backup/realms
              EOT
              ]
              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.keycloak_db.metadata[0].name
                }
              }
              env {
                name  = "KC_DB"
                value = "postgres"
              }
              # Local cache so the one-shot export process never registers
              # itself in the jdbc-ping table the live cluster discovers by.
              env {
                name  = "KC_CACHE"
                value = "local"
              }
              # The export re-augments (auto-build) before running; that
              # step wants ~1 GB of heap headroom.
              resources {
                requests = { cpu = "250m", memory = "512Mi" }
                limits   = { memory = "2Gi" }
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              # KC_DB_URL (envFrom keycloak-db) names sslrootcert= at this
              # path when a CA is pinned.
              dynamic "volume_mount" {
                for_each = local.db_ca_enabled ? [1] : []
                content {
                  name       = "db-ca"
                  mount_path = local.db_ca_dir
                  read_only  = true
                }
              }
            }

            container {
              name    = "upload"
              image   = var.backup_awscli_image
              command = ["/bin/sh", "/scripts/upload.sh"]
              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.keycloak_backup_s3[0].metadata[0].name
                }
              }
              env {
                name  = "BACKUP_KIND"
                value = "realm-export"
              }
              dynamic "env" {
                for_each = local.awscli_env
                content {
                  name  = env.key
                  value = env.value
                }
              }
              resources {
                requests = { cpu = "100m", memory = "128Mi" }
                limits   = { memory = "512Mi" }
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
            }

            volume {
              name = "backup"
              empty_dir {}
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.keycloak_backup_scripts[0].metadata[0].name
                default_mode = "0555"
              }
            }
            # Only the CA key of keycloak-db — never the password on disk.
            dynamic "volume" {
              for_each = local.db_ca_enabled ? [1] : []
              content {
                name = "db-ca"
                secret {
                  secret_name = kubernetes_secret_v1.keycloak_db.metadata[0].name
                  items {
                    key  = "ca.crt"
                    path = "ca.crt"
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Monitoring identity — read-only ServiceAccount for check_vke_platform on
# the Icinga masters (openvox profile::icinga2master). Nodes are
# cluster-scoped, hence a ClusterRole; everything else the check reads lives
# in this namespace, hence a Role. The token is a long-lived Secret because
# Icinga cannot refresh a bound token; revoke by deleting the Secret.
# ---------------------------------------------------------------------------
resource "kubernetes_service_account_v1" "icinga_monitor" {
  metadata {
    name      = "icinga-monitor"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  # Nothing runs as this identity in-cluster; its only token is the explicit
  # Secret below.
  automount_service_account_token = false
}

resource "kubernetes_cluster_role_v1" "icinga_monitor" {
  metadata {
    name = "icinga-monitor"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "icinga_monitor" {
  metadata {
    name = "icinga-monitor"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.icinga_monitor.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.icinga_monitor.metadata[0].name
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
}

resource "kubernetes_role_v1" "icinga_monitor" {
  metadata {
    name      = "icinga-monitor"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["cert-manager.io"]
    resources  = ["certificates"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "icinga_monitor" {
  metadata {
    name      = "icinga-monitor"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.icinga_monitor.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.icinga_monitor.metadata[0].name
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
}

resource "kubernetes_secret_v1" "icinga_monitor_token" {
  metadata {
    name      = "icinga-monitor-token"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.icinga_monitor.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
  # The token controller fills data.token asynchronously; without this the
  # first apply would output an empty monitor_token.
  wait_for_service_account_token = true
}
