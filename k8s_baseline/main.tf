# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# VKE CLUSTER BASELINE — ingress-nginx, cert-manager (+ Let's Encrypt
# ClusterIssuer), Elastic Agent log shipping.
# Consumes VKE client credentials from the vke module via terragrunt
# dependency outputs (base64-encoded PEM, as the VKE API returns them).
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

# ---------------------------------------------------------------------------
# ingress-nginx — TLS terminates here; the Service (type LoadBalancer)
# provisions the Vultr load balancer that DNS is cut over to.
# ---------------------------------------------------------------------------
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [yamlencode({
    controller = {
      replicaCount = var.ingress_replicas
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/vultr-loadbalancer-protocol" = "tcp"
        }
      }
      # allow-snippet-annotations is needed for the Keycloak admin-console
      # location hardening (restricted_to_wq carry-forward).
      allowSnippetAnnotations = true
      config = {
        use-proxy-protocol = "false"
      }
    }
  })]
}

# ---------------------------------------------------------------------------
# cert-manager + Let's Encrypt ClusterIssuer
# ---------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

resource "kubernetes_manifest" "letsencrypt_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.acme_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          http01 = {
            ingress = {
              ingressClassName = "nginx"
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

# ---------------------------------------------------------------------------
# Elastic Agent DaemonSet — ships container + node logs to the ELK stack
# (wqelk1 ops cluster). Disabled until the Fleet/ES endpoint and enrolment
# secrets are supplied at deploy time.
# ---------------------------------------------------------------------------
resource "helm_release" "elastic_agent" {
  count = var.elastic_agent_enabled ? 1 : 0

  name             = "elastic-agent"
  repository       = "https://helm.elastic.co"
  chart            = "elastic-agent"
  version          = var.elastic_agent_chart_version
  namespace        = "elastic-system"
  create_namespace = true

  values = [yamlencode({
    outputs = {
      default = {
        type    = "ESPlainAuthAPI"
        url     = var.elasticsearch_url
        api_key = var.elasticsearch_api_key
      }
    }
    kubernetes = {
      enabled = true
    }
  })]
}
