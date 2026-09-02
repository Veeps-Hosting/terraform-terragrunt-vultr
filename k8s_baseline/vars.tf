# --- cluster connection (from vke module outputs, base64-encoded PEM) ---
variable "cluster_endpoint" {
  # The vke module's `endpoint` output: a bare control-plane hostname
  # (<id>.vultr-k8s.com) as vultr_kubernetes.cluster.endpoint returns it. The
  # providers need a URL, so main.tf turns a bare host into
  # https://<host>:6443 (the port in the kubeconfig VKE issues). A full
  # http(s):// URL is accepted as-is for leaves that already build one.
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

# --- identity ---
variable "cluster_name" {
  # Stamped as "shipper" on every nginx access line and as "host" on every
  # syslog envelope, so Kibana can tell kck8s-stg from kck8s-prod. Also the
  # default LB label and the NetBird peer name prefix.
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a DNS label (lowercase alphanumerics and dashes, max 63 chars)."
  }
}

# --- ingress-nginx ---
variable "ingress_nginx_chart_version" {
  # Pin to the chart version validated on staging before any prod apply.
  # 4.15.1 = controller v1.15.1.
  default = "4.15.1"
}
variable "ingress_replicas" {
  default = 2
  type    = number
  validation {
    condition     = var.ingress_replicas >= 1
    error_message = "ingress_replicas must be at least 1."
  }
}
variable "lb_node_count" {
  # Vultr LB instances behind the one address. Vultr only accepts odd values.
  default = 3
  type    = number
  validation {
    condition     = var.lb_node_count >= 1 && var.lb_node_count % 2 == 1
    error_message = "lb_node_count must be an odd number (Vultr LB requirement)."
  }
}
variable "lb_label" {
  # Label shown in the Vultr console. Empty = cluster_name.
  default = ""
  type    = string
}
variable "trusted_proxy_cidrs" {
  # Networks allowed to speak PROXY protocol to ingress-nginx
  # (proxy-real-ip-cidr, i.e. nginx set_real_ip_from). The controller default
  # is 0.0.0.0/0, so anything reaching the NodePort could forge the client
  # address the admin whitelists key on; this is validated non-empty and
  # CIDR-only so the module can never fall back to that. With
  # externalTrafficPolicy Cluster the source nginx sees is the node's VPC
  # address after kube-proxy's SNAT, so the leaf passes the cluster VPC subnet
  # (vke output vpc_cidr), not the LB addresses. No default: fail closed.
  type = list(string)
  validation {
    condition     = length(var.trusted_proxy_cidrs) > 0
    error_message = "trusted_proxy_cidrs must not be empty: without it ingress-nginx trusts PROXY protocol from 0.0.0.0/0 and the admin whitelist can be bypassed. Pass the cluster VPC subnet from the vpc leaf, e.g. [\"172.24.40.0/22\"]."
  }
  validation {
    condition = alltrue([
      for c in var.trusted_proxy_cidrs : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]), 0) > 0
    ])
    error_message = "Every trusted_proxy_cidrs entry must be CIDR notation (use /32 for a single host) and none may be a /0 world route - that is the controller default this variable exists to replace."
  }
}

# --- cert-manager ---
variable "cert_manager_chart_version" {
  default = "v1.21.1"
}
variable "acme_email" {
  default = "admin@webqem.com"
  type    = string
  validation {
    condition     = length(var.acme_email) > 0
    error_message = "acme_email must be set; Let's Encrypt expiry notices go there."
  }
}
variable "acme_server" {
  # Swap for https://acme-staging-v02.api.letsencrypt.org/directory while
  # rehearsing to stay clear of the production rate limits. The issuer is
  # still named letsencrypt-prod so the keycloak module needs no change.
  default = "https://acme-v02.api.letsencrypt.org/directory"
  type    = string
}

# --- log shipping: fluent-bit -> log-gateway -> NetBird mesh -> Logstash ---
variable "log_shipping_enabled" {
  # Everything under ns logging is created only when true.
  default = true
  type    = bool
}
variable "netbird_setup_key" {
  # NetBird setup key for the gateway peers: kck8s-stg-logs-gw or
  # kck8s-prod-logs-gw (reusable, ephemeral, auto-assigning group
  # kck8s-log-shippers so policy kck8s-log-ingest lets them reach
  # veeps-log-stack on tcp 5140-5142). Read by the leaf from SM secret
  # veeps/tf/keycloak-k8s/<env> (key netbird_setup_key); never committed.
  # Empty is NOT a plan failure: the Secret netbird-setup-key is then not
  # managed here and the operator creates it with kubectl (README); the
  # gateway pods sit NotReady until it exists and fluent-bit buffers to disk.
  default   = ""
  type      = string
  sensitive = true
}
variable "netbird_image" {
  # Matches the fleet client version so the peer speaks the same protocol
  # as the wqelk relays.
  default = "netbirdio/netbird:0.77.1"
}
variable "netbird_management_url" {
  default = "https://api.netbird.io"
}
variable "socat_image" {
  # Forwarder sidecar; alpine-based so the readiness exec has /bin/sh.
  default = "alpine/socat:1.8.0.0"
}
variable "log_gateway_replicas" {
  default = 2
  type    = number
  validation {
    condition     = var.log_gateway_replicas >= 1
    error_message = "log_gateway_replicas must be at least 1."
  }
}
variable "log_ops_target" {
  # wqelk1 mesh IP: Logstash nginx (5140) and syslog (5142) inputs.
  default = "100.85.165.68"
  type    = string
}
variable "log_sec_target" {
  # wqelk2 mesh IP: Logstash auth/security (5141) input.
  default = "100.85.43.155"
  type    = string
}
variable "log_nginx_port" {
  default = 5140
  type    = number
}
variable "log_sec_port" {
  default = 5141
  type    = number
}
variable "log_syslog_port" {
  default = 5142
  type    = number
}
variable "fluent_bit_chart_version" {
  # 0.58.1 = fluent-bit 5.1.1.
  default = "0.58.1"
}
