# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# VKE CLUSTER BASELINE — ingress-nginx behind a Vultr LB (proxy protocol,
# gelf_json access log), cert-manager (+ Let's Encrypt ClusterIssuer) and the
# log shipping path:
#   fluent-bit DaemonSet -> Service log-gateway -> NetBird gateway pods -> mesh
#   -> Logstash on wqelk1 (ops: nginx 5140, syslog 5142) / wqelk2 (sec: 5141).
# Pods are not mesh peers, hence the gateway. Envelope contracts: DESIGN.md §0.
# Consumes VKE client credentials from the vke module via terragrunt
# dependency outputs (base64-encoded PEM, as the VKE API returns them).
# Applied once per cluster, before the keycloak module.
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
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}

locals {
  # DNS-01 is configured when the leaf wires in the Route53 IAM key and at
  # least one zone; with neither the issuer falls back to HTTP-01 only.
  dns01_enabled = var.dns01_route53_access_key_id != "" && var.dns01_route53_secret_access_key != "" && length(var.dns01_zones) > 0

  # The vke module's `endpoint` output is vultr_kubernetes.cluster.endpoint: a
  # bare control-plane hostname (<id>.vultr-k8s.com), not a URL. All three
  # providers want a URL, and the kubeconfig VKE hands out uses :6443, so a bare
  # host becomes https://<host>:6443. A leaf that already passes a URL is used
  # verbatim.
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

# alekc/kubectl applies raw YAML server-side. Used for the ClusterIssuer only:
# hashicorp's kubernetes_manifest needs the cert-manager CRDs to exist at PLAN
# time, which they do not on a fresh cluster, so the first apply of this module
# would fail before it had installed them.
provider "kubectl" {
  host                   = local.api_url
  client_certificate     = base64decode(var.client_certificate)
  client_key             = base64decode(var.client_key)
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  load_config_file       = false
}

locals {
  lb_label         = var.lb_label != "" ? var.lb_label : var.cluster_name
  log_gateway_name = "log-gateway"
  # Full name so it resolves the same from any namespace (fluent-bit runs in
  # `logging` today, but nothing here should depend on that).
  log_gateway_fqdn = "${local.log_gateway_name}.logging.svc.cluster.local"
}

# ---------------------------------------------------------------------------
# ingress-nginx — TLS terminates here; the Service (type LoadBalancer)
# provisions the Vultr LB that DNS points at.
# ---------------------------------------------------------------------------
locals {
  # Access log = the fleet gelf_json format (openvox: CUSTOM_CONF_HTTP_gelf_json
  # on wqwafbk1) with "shipper" prepended. Key ORDER is deliberate: "shipper"
  # first, "nginx_access" last — that trailer is what files/envelope.lua keys on
  # to tell an access line from controller stderr. Ints/float are unquoted,
  # $status is quoted because Logstash maps response_status as a string.
  # escape=json is added by log-format-escape-json below, which keeps the line
  # valid JSON whatever the client sends in a header.
  # nginx $vars are literal in HCL; only a $${...} form would need escaping.
  nginx_log_fields = [
    "\"shipper\": \"${var.cluster_name}\"",
    "\"timestamp\": \"$time_iso8601\"",
    "\"remote_addr\": \"$remote_addr\"",
    "\"connection\": \"$connection\"",
    "\"connection_requests\": $connection_requests",
    "\"pipe\": \"$pipe\"",
    "\"body_bytes_sent\": $body_bytes_sent",
    "\"request_length\": $request_length",
    "\"request_time\": $request_time",
    "\"response_status\": \"$status\"",
    "\"request\": \"$request\"",
    "\"request_method\": \"$request_method\"",
    "\"host\": \"$host\"",
    "\"server_name\": \"$server_name\"",
    "\"upstream_cache_status\": \"$upstream_cache_status\"",
    "\"upstream_addr\": \"$upstream_addr\"",
    "\"http_x_forwarded_for\": \"$http_x_forwarded_for\"",
    "\"http_referrer\": \"$http_referer\"",
    "\"http_user_agent\": \"$http_user_agent\"",
    "\"http_version\": \"$server_protocol\"",
    "\"remote_user\": \"$remote_user\"",
    "\"http_x_forwarded_proto\": \"$http_x_forwarded_proto\"",
    "\"upstream_response_time\": \"$upstream_response_time\"",
    "\"nginx_access\": true",
  ]
  nginx_log_format = "{ ${join(", ", local.nginx_log_fields)} }"

  ingress_nginx_selector = {
    "app.kubernetes.io/name"      = "ingress-nginx"
    "app.kubernetes.io/instance"  = "ingress-nginx"
    "app.kubernetes.io/component" = "controller"
  }

  ingress_nginx_values = {
    controller = {
      replicaCount = var.ingress_replicas
      # PodDisruptionBudget; the chart only renders it when replicaCount > 1,
      # so a single-replica cluster never blocks a node drain.
      minAvailable = 1
      # One replica per worker node so a node loss keeps the LB serving.
      # ScheduleAnyway: a cluster degraded to fewer nodes than replicas must
      # still be able to roll the Deployment.
      topologySpreadConstraints = [{
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = "ScheduleAnyway"
        labelSelector     = { matchLabels = local.ingress_nginx_selector }
      }]
      service = {
        type = "LoadBalancer"
        # Cluster, not Local: the Vultr LB health-checks every node, and with
        # Local a node without an ingress pod fails the check and drops out of
        # the LB. The price is a kube-proxy SNAT when the packet is forwarded to
        # a pod on another node, so the source nginx sees on the TCP connection
        # is the node's VPC address - which is why proxy-real-ip-cidr below
        # carries the VPC CIDR (the leaves pass it from the vke vpc_cidr output)
        # and not the LB's addresses. The client address itself still arrives
        # intact in the PROXY header. The first-apply whitelist test in the
        # README (admin console 403 from off-list, 200 from on-list) is what
        # proves the chain end to end.
        externalTrafficPolicy = "Cluster"
        # Vultr CCM (vultr-cloud-controller-manager docs/load-balancers.md).
        annotations = {
          # TCP passthrough: TLS terminates in ingress-nginx with cert-manager
          # certificates, never on the LB.
          "service.beta.kubernetes.io/vultr-loadbalancer-protocol" = "tcp"
          # Client IP survives the TCP hop as a PROXY header; use-proxy-protocol
          # in the ConfigMap below reads it.
          "service.beta.kubernetes.io/vultr-loadbalancer-proxy-protocol" = "true"
          # LB reaches the NodePorts over the cluster VPC, so the VKE-managed
          # node firewall can stay closed to the public internet.
          "service.beta.kubernetes.io/vultr-loadbalancer-vpc"                  = "true"
          "service.beta.kubernetes.io/vultr-loadbalancer-node-count"           = tostring(var.lb_node_count)
          "service.beta.kubernetes.io/vultr-loadbalancer-label"                = local.lb_label
          "service.beta.kubernetes.io/vultr-loadbalancer-healthcheck-protocol" = "tcp"
        }
      }
      # The keycloak module's admin and scope-fix Ingresses carry
      # configuration-snippet annotations. Since controller 1.12 that needs BOTH
      # this switch and annotations-risk-level Critical.
      allowSnippetAnnotations = true
      config = {
        "use-proxy-protocol"     = "true"
        "annotations-risk-level" = "Critical"
        # X-Forwarded-* from the client is untrusted: the LB is a plain TCP
        # proxy and the real client address comes from PROXY protocol.
        "use-forwarded-headers" = "false"
        # Bound who may speak PROXY protocol to nginx (set_real_ip_from). The
        # controller default is 0.0.0.0/0, which would let anything that can
        # reach the NodePort - another pod, a VPC neighbour - forge the client
        # address and walk through the whitelist-source-range Ingresses. The
        # variable is validated non-empty so this never silently reverts to the
        # default. See the externalTrafficPolicy comment for why it is the VPC
        # CIDR rather than the LB.
        "proxy-real-ip-cidr"     = join(",", var.trusted_proxy_cidrs)
        "log-format-escape-json" = "true"
        "log-format-upstream"    = local.nginx_log_format
        # Keycloak: realm imports and admin console uploads; long-poll admin
        # operations (600 s matches the wqkc nginx carry-forward).
        "proxy-body-size"    = "16m"
        "proxy-read-timeout" = "600"
        "proxy-send-timeout" = "600"
        "ssl-redirect"       = "true"
        "server-tokens"      = "false"
      }
      metrics = { enabled = false }
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true
  # helm --wait holds until the LoadBalancer has an address; Vultr takes a few
  # minutes to build a 3-node LB, longer than the provider's 300 s default.
  timeout = 600

  values = [yamlencode(local.ingress_nginx_values)]
}

# Read back after the release so ingress_lb_ip can feed the Route53 leaf.
data "kubernetes_service_v1" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = helm_release.ingress_nginx.namespace
  }
  depends_on = [helm_release.ingress_nginx]
}

# ---------------------------------------------------------------------------
# cert-manager + Let's Encrypt ClusterIssuer (HTTP-01 through ingress-nginx)
# ---------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  values = [yamlencode({
    crds = {
      enabled = true
      # keep = true annotates the CRDs helm.sh/resource-policy: keep, so a
      # release uninstall cannot cascade-delete every Certificate in the cluster.
      keep = true
    }
    # HTTP-01 self-check hairpin (found on the first staging apply, 2026-09-02):
    # cert-manager GETs http://<host>/.well-known/acme-challenge/<token> itself
    # before telling Let's Encrypt to try, and pods cannot reach the Vultr LB's
    # public address from inside the cluster (connect fails instantly), so the
    # challenge sat Pending while the same URL answered 200 from the internet.
    # Pinning the hostnames to the ingress-nginx ClusterIP inside the
    # cert-manager pod makes the self-check take the in-cluster path; ACME's
    # own validation still comes from outside through the LB.
    hostAliases = length(var.acme_self_check_hosts) == 0 ? [] : [{
      ip        = data.kubernetes_service_v1.ingress_nginx.spec[0].cluster_ip
      hostnames = var.acme_self_check_hosts
    }]
  })]
}

resource "kubectl_manifest" "letsencrypt_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = var.acme_server
        email  = var.acme_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        # DNS-01 through Route53 for the zones we own (selector.dnsZones), HTTP-01
        # for anything else. DNS-01 is the one that works here: ingress-nginx
        # requires PROXY protocol on every connection and pods cannot reach the
        # Vultr LB's public address, so cert-manager's HTTP-01 self-check gets
        # EOF from the ClusterIP and the Order never leaves Pending (staging,
        # 2026-09-02). DNS-01 also lets a certificate issue BEFORE a name is cut
        # over, which the production cutover needs.
        solvers = concat(
          local.dns01_enabled ? [{
            selector = { dnsZones = var.dns01_zones }
            dns01 = {
              route53 = {
                region      = var.dns01_route53_region
                accessKeyID = var.dns01_route53_access_key_id
                secretAccessKeySecretRef = {
                  name = "route53-dns01-credentials"
                  key  = "secret-access-key"
                }
              }
            }
          }] : [],
          [{
            http01 = {
              ingress = {
                ingressClassName = "nginx"
              }
            }
          }]
        )
      }
    }
  })

  server_side_apply = true
  wait              = true

  depends_on = [helm_release.cert_manager, kubernetes_secret_v1.route53_dns01]
}

# IAM user credentials for the Route53 DNS-01 solver (aws-tf-modules-veeps
# cert-manager-route53). Lives in the cert-manager namespace because the
# ClusterIssuer's secretRef is resolved there.
resource "kubernetes_secret_v1" "route53_dns01" {
  count = local.dns01_enabled ? 1 : 0
  metadata {
    name      = "route53-dns01-credentials"
    namespace = helm_release.cert_manager.namespace
  }
  data = {
    "secret-access-key" = var.dns01_route53_secret_access_key
  }
}

# ---------------------------------------------------------------------------
# Log shipping (count = log_shipping_enabled)
#
#   fluent-bit (DaemonSet, ns logging)
#     tail /var/log/containers -> kubernetes filter -> files/envelope.lua
#     -> rewrite_tag nginx.* | syslog.* -> tcp json_lines
#   -> Service log-gateway:5140/5141/5142 (ClusterIP)
#   -> Deployment log-gateway (netbird peer + socat forwarder, shared netns)
#   -> mesh -> Logstash on wqelk1/wqelk2
#
# The NetBird peer joins with a setup key (kck8s-stg-logs-gw / kck8s-prod-logs-gw,
# ephemeral, auto-assigning group kck8s-log-shippers; policy kck8s-log-ingest
# opens tcp 5140-5142 from that group to veeps-log-stack). socat runs in the
# same pod so its outbound sockets leave through the peer's wt0.
# ---------------------------------------------------------------------------
locals {
  log_gateway_labels = { app = local.log_gateway_name }

  # The Secret the gateway reads NB_SETUP_KEY from. A literal name, shared by
  # the Secret below and the Deployment's secret_key_ref, so the Deployment
  # never references the count-ed Secret resource: when the leaf has no key
  # (netbird_setup_key = "") the Secret is simply not managed here and the
  # operator creates one of the same name by hand (README). The pods sit
  # NotReady until it exists; nothing else in the module waits on them.
  netbird_secret_name = "netbird-setup-key"

  # One self-restarting listener per port. `fork` gives every fluent-bit
  # connection its own child; a child that cannot reach the mesh exits alone
  # and the listener stays up, so the loop only matters if socat itself dies.
  # $1/$2 are shell positionals, which HCL leaves alone (no braces).
  forwarder_script = <<-EOT
    set -u
    fwd() {
      while :; do
        socat -d TCP-LISTEN:$1,fork,reuseaddr TCP:$2
        sleep 2
      done
    }
    fwd ${var.log_nginx_port} ${var.log_ops_target}:${var.log_nginx_port} &
    fwd ${var.log_sec_port} ${var.log_sec_target}:${var.log_sec_port} &
    fwd ${var.log_syslog_port} ${var.log_ops_target}:${var.log_syslog_port} &
    trap 'kill 0' TERM INT
    wait
  EOT

  # Readiness = "Logstash is reachable over the mesh", not "socat listens".
  # socat accepts a fluent-bit connection even when the mesh is down and only
  # then fails to connect onward, which silently loses whatever was already
  # written. Taking the pod out of the Service endpoints instead makes
  # fluent-bit's connect fail, and it retries from its disk buffer.
  forwarder_readiness = [
    "/bin/sh", "-c",
    "socat -T 3 -u OPEN:/dev/null TCP:${var.log_ops_target}:${var.log_syslog_port},connect-timeout=3",
  ]
}

resource "kubernetes_namespace_v1" "logging" {
  count = var.log_shipping_enabled ? 1 : 0

  metadata {
    name = "logging"
  }
}

# Managed only when the leaf supplies the key (SM secret
# veeps/tf/keycloak-k8s/<env>, key netbird_setup_key). With an empty key the
# plan still succeeds and the whole logging stack is built; only this Secret is
# left for the operator (DESIGN.md §8). Not a plan-time failure on purpose: a
# missing key must not block ingress and cert-manager, and fluent-bit buffers
# to disk until the gateway is up, so nothing is lost in the meantime.
resource "kubernetes_secret_v1" "netbird_setup_key" {
  count = var.log_shipping_enabled && var.netbird_setup_key != "" ? 1 : 0

  metadata {
    name      = local.netbird_secret_name
    namespace = kubernetes_namespace_v1.logging[0].metadata[0].name
  }
  data = {
    NB_SETUP_KEY = var.netbird_setup_key
  }
}

resource "kubernetes_deployment_v1" "log_gateway" {
  count = var.log_shipping_enabled ? 1 : 0

  # Gateway readiness is "Logstash reachable through the mesh" (the forwarder
  # probe below). That is a Service-endpoint signal for fluent-bit, not an
  # apply gate: with the provider's default wait, a missing setup-key Secret, a
  # NetBird outage or a closed ACL would hold the apply for 10 minutes and then
  # fail it, taking ingress and cert-manager down with it on a first apply.
  # fluent-bit buffers to disk until the endpoints appear, so nothing is lost
  # by returning early.
  wait_for_rollout = false

  metadata {
    name      = local.log_gateway_name
    namespace = kubernetes_namespace_v1.logging[0].metadata[0].name
    labels    = local.log_gateway_labels
  }

  spec {
    replicas = var.log_gateway_replicas

    selector {
      match_labels = local.log_gateway_labels
    }

    template {
      metadata {
        labels = local.log_gateway_labels
      }

      spec {
        # Preferred, not required: a cluster temporarily down to one worker
        # must still be able to reschedule both gateways.
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = local.log_gateway_labels
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }

        termination_grace_period_seconds = 20

        container {
          name  = "netbird"
          image = var.netbird_image

          # By name, not via the Secret resource: that one may not exist in
          # this plan (see netbird_secret_name). kubelet holds the container in
          # CreateContainerConfigError and keeps retrying until the Secret
          # appears, so no ordering is needed either way.
          env {
            name = "NB_SETUP_KEY"
            value_from {
              secret_key_ref {
                name = local.netbird_secret_name
                key  = "NB_SETUP_KEY"
              }
            }
          }
          env {
            name  = "NB_MANAGEMENT_URL"
            value = var.netbird_management_url
          }
          env {
            name  = "NB_HOSTNAME"
            value = "${var.cluster_name}-logs-gw"
          }
          env {
            name  = "NB_LOG_LEVEL"
            value = "info"
          }
          # The image entrypoint defaults to console + /var/log/netbird/client.log
          # inside the container; stdout alone is enough, fluent-bit collects it.
          env {
            name  = "NB_LOG_FILE"
            value = "console"
          }
          # Pure egress peer. `netbird up` binds every persistent flag to
          # NB_<FLAG> (client/cmd/root.go SetFlagsFromEnvVars), so these are the
          # --disable-dns / --block-inbound / --disable-*-routes switches:
          # never rewrite the pod's resolv.conf (Logstash targets are IPs),
          # accept nothing from the mesh, install and advertise no routes.
          env {
            name  = "NB_DISABLE_DNS"
            value = "true"
          }
          env {
            name  = "NB_BLOCK_INBOUND"
            value = "true"
          }
          env {
            name  = "NB_DISABLE_CLIENT_ROUTES"
            value = "true"
          }
          env {
            name  = "NB_DISABLE_SERVER_ROUTES"
            value = "true"
          }

          # NET_ADMIN creates wt0 (kernel WireGuard when the node has the module,
          # wireguard-go over /dev/net/tun otherwise) and sets routes in the pod
          # netns. Nothing here needs privileged or SYS_MODULE.
          security_context {
            privileged = false
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          volume_mount {
            name       = "dev-net-tun"
            mount_path = "/dev/net/tun"
          }
          volume_mount {
            name       = "netbird-state"
            mount_path = "/var/lib/netbird"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }

        container {
          name    = "forwarder"
          image   = var.socat_image
          command = ["/bin/sh", "-c", local.forwarder_script]

          port {
            name           = "nginx"
            container_port = var.log_nginx_port
            protocol       = "TCP"
          }
          port {
            name           = "sec"
            container_port = var.log_sec_port
            protocol       = "TCP"
          }
          port {
            name           = "syslog"
            container_port = var.log_syslog_port
            protocol       = "TCP"
          }

          readiness_probe {
            exec {
              command = local.forwarder_readiness
            }
            initial_delay_seconds = 10
            period_seconds        = 15
            timeout_seconds       = 5
            failure_threshold     = 2
            success_threshold     = 1
          }

          liveness_probe {
            tcp_socket {
              port = var.log_syslog_port
            }
            initial_delay_seconds = 5
            period_seconds        = 20
            failure_threshold     = 3
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "dev-net-tun"
          host_path {
            path = "/dev/net/tun"
            type = "CharDevice"
          }
        }
        volume {
          name = "netbird-state"
          empty_dir {}
        }
      }
    }
  }
}

# Only meaningful with >1 replica: minAvailable 1 on a single replica would
# block every node drain (VKE upgrades) instead of protecting anything.
resource "kubernetes_pod_disruption_budget_v1" "log_gateway" {
  count = var.log_shipping_enabled && var.log_gateway_replicas > 1 ? 1 : 0

  metadata {
    name      = local.log_gateway_name
    namespace = kubernetes_namespace_v1.logging[0].metadata[0].name
    labels    = local.log_gateway_labels
  }
  spec {
    min_available = "1"
    selector {
      match_labels = local.log_gateway_labels
    }
  }
}

resource "kubernetes_service_v1" "log_gateway" {
  count = var.log_shipping_enabled ? 1 : 0

  metadata {
    name      = local.log_gateway_name
    namespace = kubernetes_namespace_v1.logging[0].metadata[0].name
    labels    = local.log_gateway_labels
  }
  spec {
    type     = "ClusterIP"
    selector = local.log_gateway_labels

    port {
      name        = "nginx"
      port        = var.log_nginx_port
      target_port = var.log_nginx_port
      protocol    = "TCP"
    }
    port {
      name        = "sec"
      port        = var.log_sec_port
      target_port = var.log_sec_port
      protocol    = "TCP"
    }
    port {
      name        = "syslog"
      port        = var.log_syslog_port
      target_port = var.log_syslog_port
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# fluent-bit DaemonSet — builds the two §0 envelopes and ships them to the
# gateway. Classic-mode config strings; the chart runs each through tpl, so
# never put {{ }} in them.
# ---------------------------------------------------------------------------
locals {
  fluent_bit_values = {
    kind        = "DaemonSet"
    hostNetwork = false
    dnsPolicy   = "ClusterFirst"

    testFramework  = { enabled = false }
    serviceMonitor = { enabled = false }
    dashboards     = { enabled = false }

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }

    # Mounted by the chart at /fluent-bit/scripts/<key>.
    luaScripts = {
      "envelope.lua" = templatefile("${path.module}/files/envelope.lua", {
        cluster_name = var.cluster_name
      })
    }

    # Replaces the chart's default list. VKE runs containerd: the
    # /var/log/containers symlinks resolve under /var/log/pods, so /var/log
    # read-only is the only host read. flb-storage is the disk buffer plus the
    # tail offset DB, the one place fluent-bit writes on the host.
    daemonSetVolumes = [
      {
        name     = "varlog"
        hostPath = { path = "/var/log" }
      },
      {
        name     = "flb-storage"
        hostPath = { path = "/var/log/flb-storage", type = "DirectoryOrCreate" }
      },
    ]
    daemonSetVolumeMounts = [
      { name = "varlog", mountPath = "/var/log", readOnly = true },
      { name = "flb-storage", mountPath = "/var/log/flb-storage" },
    ]

    config = {
      # HTTP_Server/Health_Check back the chart's liveness/readiness probes on
      # :2020. storage.* is the filesystem buffer every input and the rewrite_tag
      # emitter use; backlog.mem_limit bounds how much of it is replayed into
      # memory after a restart.
      service = <<-EOT
        [SERVICE]
            Daemon Off
            Flush 1
            Log_Level info
            Parsers_File /fluent-bit/etc/parsers.conf
            Parsers_File /fluent-bit/etc/conf/custom_parsers.conf
            HTTP_Server On
            HTTP_Listen 0.0.0.0
            HTTP_Port 2020
            Health_Check On
            storage.path /var/log/flb-storage/
            storage.sync normal
            storage.checksum off
            storage.backlog.mem_limit 16M
            storage.max_chunks_up 64
            storage.metrics on
      EOT

      # cri_line (custom_parsers.conf) instead of the built-in multiline cri:
      # partial-line stitching is off on purpose, the syslog envelope is one
      # record per runtime line. Exclude_Path drops fluent-bit's own container
      # log so a shipping error can never feed back into the pipeline; the
      # gateway's logs are kept deliberately (they are the mesh diagnostics).
      inputs = <<-EOT
        [INPUT]
            Name tail
            Tag kube.*
            Path /var/log/containers/*.log
            Exclude_Path /var/log/containers/*_logging_fluent-bit-*.log
            Parser cri_line
            Refresh_Interval 10
            Rotate_Wait 30
            Mem_Buf_Limit 16MB
            Buffer_Chunk_Size 64k
            Buffer_Max_Size 512k
            Skip_Long_Lines On
            Skip_Empty_Lines On
            DB /var/log/flb-storage/tail-containers.db
            DB.locking true
            DB.sync normal
            storage.type filesystem
      EOT

      # Order matters, records flow top to bottom and re-enter at the top after
      # rewrite_tag:
      #   kubernetes  : pod/namespace/container identity. Merge_Log Off — Keycloak
      #                 writes JSON too and must stay a string inside the syslog
      #                 envelope, only ingress access lines are decoded.
      #   lua         : builds the envelope (syslog) or passes the access line
      #                 through (nginx) and stamps flb_route.
      #   rewrite_tag : kube.* -> nginx.<tag> | syslog.<tag>; new tags cannot
      #                 match kube.* so there is no loop. Emitter buffered on
      #                 disk like the input.
      #   parser      : nginx.* only — decodes the access line into the record;
      #                 Reserve_Data Off drops everything else (incl. flb_route).
      #   modify      : syslog.* only — strips flb_route so the envelope is
      #                 exactly the §0 key set.
      filters = <<-EOT
        [FILTER]
            Name kubernetes
            Match kube.*
            Kube_Tag_Prefix kube.var.log.containers.
            Merge_Log Off
            Keep_Log On
            Labels On
            Annotations Off
            Buffer_Size 0
            K8S-Logging.Parser Off
            K8S-Logging.Exclude Off

        [FILTER]
            Name lua
            Match kube.*
            script /fluent-bit/scripts/envelope.lua
            call build_envelope
            time_as_table On

        [FILTER]
            Name rewrite_tag
            Match kube.*
            Rule $flb_route ^nginx$ nginx.$TAG false
            Rule $flb_route ^syslog$ syslog.$TAG false
            Emitter_Name log_router
            Emitter_Storage.type filesystem
            Emitter_Mem_Buf_Limit 16M

        [FILTER]
            Name parser
            Match nginx.*
            Key_Name log
            Parser nginx_access_json
            Reserve_Data Off
            Preserve_Key Off

        [FILTER]
            Name modify
            Match syslog.*
            Remove flb_route
      EOT

      # json_lines = one JSON object per line, the Logstash json_lines codec on
      # the far side. json_date_key false: Logstash reads `timestamp` from the
      # envelope, an extra `date` key would be an unknown field. Retry forever;
      # total_limit_size caps the per-output disk buffer so a long mesh outage
      # cannot fill the node's /var/log.
      outputs = <<-EOT
        [OUTPUT]
            Name tcp
            Match nginx.*
            Host ${local.log_gateway_fqdn}
            Port ${var.log_nginx_port}
            Format json_lines
            json_date_key false
            Retry_Limit False
            net.connect_timeout 10
            storage.total_limit_size 512M

        [OUTPUT]
            Name tcp
            Match syslog.*
            Host ${local.log_gateway_fqdn}
            Port ${var.log_syslog_port}
            Format json_lines
            json_date_key false
            Retry_Limit False
            net.connect_timeout 10
            storage.total_limit_size 512M
      EOT

      # cri_line: containerd's "<rfc3339nano> <stream> <P|F> <line>". The time
      # becomes the record timestamp (that is what the syslog envelope stamps),
      # the message lands in `log` so envelope.lua sees the same key on every
      # runtime. nginx_access_json has no Time_Key on purpose: the access line's
      # own `timestamp` field must survive untouched for Logstash.
      customParsers = <<-EOT
        [PARSER]
            Name cri_line
            Format regex
            Regex ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<log>.*)$
            Time_Key time
            Time_Format %Y-%m-%dT%H:%M:%S.%L%z
            Time_Keep Off

        [PARSER]
            Name nginx_access_json
            Format json
      EOT
    }
  }
}

resource "helm_release" "fluent_bit" {
  count = var.log_shipping_enabled ? 1 : 0

  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = var.fluent_bit_chart_version
  namespace  = kubernetes_namespace_v1.logging[0].metadata[0].name

  values = [yamlencode(local.fluent_bit_values)]

  # Not strictly needed (fluent-bit retries until the Service resolves) but it
  # keeps a first apply from logging minutes of connection errors.
  depends_on = [kubernetes_service_v1.log_gateway]
}
