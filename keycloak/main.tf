# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# KEYCLOAK ON VKE — HA Keycloak 26.4.x via the codecentric keycloakx chart.
# Design decisions carried in from Monday 2801647539:
#   * KC_HTTP_RELATIVE_PATH=/auth kept at migration (zero client changes).
#   * 2+ replicas, Infinispan/JGroups kubernetes discovery, PDB, anti-affinity.
#   * TLS at ingress-nginx; admin console (/auth/admin) restricted to the
#     restricted_to_wq whitelist — including the static admin HTML residual.
#   * DB is Vultr Managed PostgreSQL (managed_database module outputs).
#   * Secrets arrive as sensitive TF vars (sops / env at deploy) — never in git.
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
  }
}

provider "kubernetes" {
  host                   = var.cluster_endpoint
  client_certificate     = base64decode(var.client_certificate)
  client_key             = base64decode(var.client_key)
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    client_certificate     = base64decode(var.client_certificate)
    client_key             = base64decode(var.client_key)
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  }
}

resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = var.namespace
  }
}

# DB connection — host/port/user/password come from the managed_database leaf.
resource "kubernetes_secret" "keycloak_db" {
  metadata {
    name      = "keycloak-db"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }
  data = {
    KC_DB_URL      = "jdbc:postgresql://${var.db_host}:${var.db_port}/${var.db_name}"
    KC_DB_USERNAME = var.db_user
    KC_DB_PASSWORD = var.db_password
  }
}

# Bootstrap admin credential — rotated as part of first prod deploy (the
# deferred SEC-02 item). Value is supplied at deploy time, never committed.
resource "kubernetes_secret" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }
  data = {
    KC_BOOTSTRAP_ADMIN_USERNAME = var.admin_user
    KC_BOOTSTRAP_ADMIN_PASSWORD = var.admin_password
  }
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://codecentric.github.io/helm-charts"
  chart      = "keycloakx"
  version    = var.keycloakx_chart_version
  namespace  = kubernetes_namespace.keycloak.metadata[0].name

  values = [yamlencode({
    image = {
      repository = "quay.io/keycloak/keycloak"
      tag        = var.keycloak_version
    }
    replicas = var.replicas
    command  = ["/opt/keycloak/bin/kc.sh", "start"]

    # /auth relative path kept at migration (decision: decouple any later
    # path change from the platform migration).
    http = {
      relativePath = "/auth"
    }

    extraEnv = yamlencode([
      { name = "KC_HOSTNAME", value = "https://${var.hostname}/auth" },
      { name = "KC_PROXY_HEADERS", value = "xforwarded" },
      { name = "KC_HTTP_ENABLED", value = "true" },
      { name = "KC_HEALTH_ENABLED", value = "true" },
      { name = "KC_METRICS_ENABLED", value = "true" },
      # Infinispan clustering via kubernetes DNS discovery (headless service)
      { name = "KC_CACHE", value = "ispn" },
      { name = "KC_CACHE_STACK", value = "kubernetes" },
      { name = "JAVA_OPTS_APPEND", value = "-Djgroups.dns.query=keycloak-keycloakx-headless.${var.namespace}.svc.cluster.local" },
      # Login/admin event logging as structured JSON -> stdout -> Elastic Agent
      { name = "KC_LOG_CONSOLE_OUTPUT", value = "json" },
      { name = "KC_SPI_EVENTS_LISTENER_JBOSS_LOGGING_SUCCESS_LEVEL", value = "info" },
      { name = "KC_DB", value = "postgres" },
    ])

    extraEnvFrom = yamlencode([
      { secretRef = { name = kubernetes_secret.keycloak_db.metadata[0].name } },
      { secretRef = { name = kubernetes_secret.keycloak_admin.metadata[0].name } },
    ])

    dbchecker = {
      enabled = true
    }

    podDisruptionBudget = {
      minAvailable = 1
    }

    affinity = yamlencode({
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "keycloakx"
            }
          }
          topologyKey = "kubernetes.io/hostname"
        }]
      }
    })

    # Ingress is managed below (two objects: public + whitelisted admin),
    # not by the chart, so the admin whitelist cannot drift with chart moves.
    ingress = {
      enabled = false
    }
  })]
}

# ---------------------------------------------------------------------------
# Public ingress — everything under /auth EXCEPT the admin console.
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "keycloak" {
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
    annotations = {
      "cert-manager.io/cluster-issuer" = var.cluster_issuer
      # restricted_to_wq carry-forward: block the admin console AND its static
      # HTML from outside the whitelist. server-snippet returns 403 for
      # /auth/admin from non-whitelisted sources; the dedicated admin ingress
      # below re-admits whitelisted CIDRs. This closes the "static admin
      # console HTML returns 200" residual from the old prod deployment.
      "nginx.ingress.kubernetes.io/server-snippet" = <<-SNIPPET
        location ~* ^/auth/(admin|welcome) {
          %{for cidr in var.admin_whitelist_cidrs~}
          allow ${cidr};
          %{endfor~}
          deny all;
          proxy_pass http://upstream_balancer;
        }
      SNIPPET
    }
  }
  spec {
    ingress_class_name = "nginx"
    tls {
      hosts       = [var.hostname]
      secret_name = "keycloak-tls"
    }
    rule {
      host = var.hostname
      http {
        path {
          path      = "/auth"
          path_type = "Prefix"
          backend {
            service {
              name = "keycloak-keycloakx-http"
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
