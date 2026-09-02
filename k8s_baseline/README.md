# k8s_baseline

Cluster-wide plumbing for a VKE cluster built by the `vke` module, applied once
per cluster before the `keycloak` module. Nothing application-specific lives
here.

| Namespace       | What                                                                                   |
|-----------------|----------------------------------------------------------------------------------------|
| `ingress-nginx` | ingress-nginx (chart 4.15.1 / controller 1.15.1), Service type LoadBalancer -> Vultr LB |
| `cert-manager`  | cert-manager v1.21.1 with CRDs, ClusterIssuer `letsencrypt-prod` (HTTP-01)             |
| `logging`       | fluent-bit DaemonSet, Service `log-gateway`, Deployment `log-gateway` (NetBird + socat) |

Providers: `hashicorp/kubernetes ~> 2.38`, `hashicorp/helm ~> 2.17` (2.x block
syntax), `alekc/kubectl ~> 2.1`. All three authenticate with the VKE client
certificate the `vke` module outputs.

## Inputs

| Name                          | Default                                          | Notes                                                         |
|-------------------------------|--------------------------------------------------|---------------------------------------------------------------|
| `cluster_endpoint`            | required                                         | `vke` output `endpoint`: a bare hostname, turned into `https://<host>:6443`; a full URL is used as-is |
| `client_certificate`          | required, sensitive                              | base64 PEM, from `vke`                                        |
| `client_key`                  | required, sensitive                              | base64 PEM, from `vke`                                        |
| `cluster_ca_certificate`      | required, sensitive                              | base64 PEM, from `vke`                                        |
| `cluster_name`                | required                                         | DNS label; `shipper` / `host` stamp, LB label, NetBird peer name |
| `ingress_nginx_chart_version` | `4.15.1`                                         |                                                               |
| `ingress_replicas`            | `2`                                              | PDB minAvailable 1 is rendered only when > 1                  |
| `lb_node_count`               | `3`                                              | Vultr LB instances; must be odd                               |
| `lb_label`                    | `""` = `cluster_name`                            | Vultr console label                                           |
| `trusted_proxy_cidrs`         | required, non-empty                              | CIDRs allowed to speak PROXY protocol (`proxy-real-ip-cidr`); the cluster VPC subnet, `vke` output `vpc_cidr` |
| `cert_manager_chart_version`  | `v1.21.1`                                        |                                                               |
| `acme_email`                  | `admin@webqem.com`                               |                                                               |
| `acme_server`                 | LE production directory                          | LE staging URL for rehearsals; issuer name stays `letsencrypt-prod` |
| `log_shipping_enabled`        | `true`                                           | gates everything in `logging`                                 |
| `netbird_setup_key`           | `""`, sensitive                                  | SM `veeps/tf/keycloak-k8s/<env>` key `netbird_setup_key`; empty = Secret `netbird-setup-key` is left to the operator |
| `netbird_image`               | `netbirdio/netbird:0.77.1`                       |                                                               |
| `netbird_management_url`      | `https://api.netbird.io`                         |                                                               |
| `socat_image`                 | `alpine/socat:1.8.0.0`                           |                                                               |
| `log_gateway_replicas`        | `2`                                              | PDB minAvailable 1 only when > 1                              |
| `log_ops_target`              | `100.85.165.68`                                  | wqelk1 mesh IP                                                |
| `log_sec_target`              | `100.85.43.155`                                  | wqelk2 mesh IP                                                |
| `log_nginx_port`              | `5140`                                           |                                                               |
| `log_sec_port`                | `5141`                                           |                                                               |
| `log_syslog_port`             | `5142`                                           |                                                               |
| `fluent_bit_chart_version`    | `0.58.1`                                         | fluent-bit 5.1.1                                              |

## Outputs

| Name                  | Value                                                                  |
|-----------------------|------------------------------------------------------------------------|
| `ingress_namespace`   | `ingress-nginx`                                                        |
| `cluster_issuer`      | `letsencrypt-prod`                                                     |
| `ingress_lb_ip`       | public IP of the Vultr LB, `""` until the CCM has created it            |
| `log_gateway_service` | `log-gateway.logging.svc.cluster.local`, `""` when shipping is disabled |

## Ingress and the Vultr LB

The LB is a TCP passthrough (`vultr-loadbalancer-protocol: tcp`) with PROXY
protocol on, attached to the cluster VPC, `lb_node_count` instances behind one
address. TLS terminates in ingress-nginx with cert-manager certificates.
`use-proxy-protocol: "true"` recovers the client IP; `use-forwarded-headers`
stays off because nothing between the client and nginx is trusted to set it.

### Who may speak PROXY protocol

`proxy-real-ip-cidr` (nginx `set_real_ip_from`) is set from `trusted_proxy_cidrs`.
The controller default is `0.0.0.0/0`: anything that can reach the NodePort
(another pod, a VPC neighbour) could then prepend a PROXY header with a
whitelisted address and walk through the keycloak module's
`whitelist-source-range` Ingresses. The variable is validated non-empty and
CIDR-only so the module can never fall back to that default.

The Service keeps `externalTrafficPolicy: Cluster`: the Vultr LB health-checks
every node, and with `Local` a node without an ingress pod fails the check and
drops out of the LB. The cost is a kube-proxy SNAT when the packet is forwarded
to a pod on another node, so the source address nginx sees on the TCP
connection is the **node's VPC address**, not the LB's. That is why the leaves
pass the cluster VPC subnet (`dependency.vke.outputs.vpc_cidr`) and not a list
of LB addresses; the client address itself still arrives intact in the PROXY
header. The first-apply whitelist test proves the whole chain: the admin
console must answer 403 from an address off the whitelist and 200 from one on
it. A 403 from *everywhere* means the PROXY header was ignored, and the source
nginx saw was outside `trusted_proxy_cidrs` (check `kubectl -n ingress-nginx
logs deploy/ingress-nginx-controller` for the `remote_addr` it logged).

Snippet annotations are enabled (`allowSnippetAnnotations` +
`annotations-risk-level: Critical`) because the keycloak module's admin and
scope-fix Ingresses need `configuration-snippet`. Keep that in mind when
granting anyone else the right to create Ingresses in this cluster.

First apply: `helm --wait` blocks until the LB has an address, which takes a few
minutes on Vultr; the release timeout is 600 s for that reason. `ingress_lb_ip`
is read back through a data source that depends on the release, so a plan
before the first apply shows it as `(known after apply)`. The `log-gateway`
Deployment, by contrast, is applied with `wait_for_rollout = false`: its
readiness is a probe through the mesh to Logstash, a Service-endpoint signal
for fluent-bit rather than something the apply should gate on. A gateway that
cannot join the mesh (no setup key yet, NetBird outage, closed ACL) therefore
never fails or delays the apply of ingress and cert-manager.

## Log shipping

Cluster pods are not mesh peers, so:

```
fluent-bit (DaemonSet)  --tcp json_lines-->  Service log-gateway  -->  Pod log-gateway
                                                                       ├─ netbird  (peer <cluster_name>-logs-gw, NET_ADMIN, /dev/net/tun)
                                                                       └─ forwarder (socat; same netns, so it egresses over wt0)
                                                                            5140 -> log_ops_target:5140   nginx access
                                                                            5141 -> log_sec_target:5141   auth/security (reserved)
                                                                            5142 -> log_ops_target:5142   syslog
```

### Envelopes (must match the Logstash contracts in DESIGN.md §0)

Every container line is tailed from `/var/log/containers`, parsed with a CRI
regex (no multiline stitching), enriched by the kubernetes filter with
`Merge_Log Off` (Keycloak's JSON stays a string), then `files/envelope.lua`
decides:

* **nginx stream** — namespace `ingress-nginx`, line starts with `{` and ends
  with `"nginx_access": true }`: the line is the record. It is the fleet
  gelf_json format with `"shipper": "<cluster_name>"` prepended, decoded by the
  parser filter with `Reserve_Data Off`, so exactly the access-line keys leave
  the node. Sent to port 5140.
* **syslog stream** — everything else:
  `{"timestamp": <rfc3339 ms UTC>, "host": "<cluster_name>", "facility": "local0",
  "severity": "err"|"info" (stderr/stdout), "programname": "<namespace>/<container>",
  "procid": "-", "message": "[<pod>] <line>", "stream": "syslog"}`. Sent to 5142.

Routing is a `rewrite_tag` on the `flb_route` key the Lua sets; the key is
stripped again before output. fluent-bit's own container log is excluded at
the tail (`*_logging_fluent-bit-*.log`) so a shipping failure can never feed
back into itself; the gateway's logs are kept because they are the mesh
diagnostics.

`os.getenv` is not used in the Lua — `cluster_name` is rendered in with
`templatefile()`, so the script is fixed at plan time. The Lua is plain 5.1
(fluent-bit embeds LuaJIT); keep 5.2+ syntax out of it.

### Buffering

`storage.path /var/log/flb-storage` is a hostPath on every node. The tail
input and the rewrite_tag emitter are filesystem-buffered, each tcp output
retries forever with a 512 M disk cap, so a mesh outage costs nothing until
the cap is hit. `/var/log` itself is mounted read-only.

### Gateway readiness

The forwarder's readiness probe opens a TCP connection to
`log_ops_target:log_syslog_port` *through the mesh* every 15 s. A gateway
whose peer is down leaves the Service endpoints, fluent-bit's connect fails
and it retries from disk, rather than socat accepting the connection and
dropping the data on the far side. Liveness is a plain tcpSocket on 5142.

### NetBird setup key

The gateway peers enrol with the setup keys `kck8s-stg-logs-gw` (staging) and
`kck8s-prod-logs-gw` (prod): reusable, ephemeral (so replaced pods do not pile
up as stale peers), auto-assigning the group `kck8s-log-shippers`. Policy
`kck8s-log-ingest` opens tcp 5140-5142 from that group to `veeps-log-stack`
(wqelk1/wqelk2). Peers appear as `<cluster_name>-logs-gw` (NetBird
de-duplicates the name for the second replica). The peer state lives in an
emptyDir, so every pod restart is a fresh enrolment with the same key;
rotating the key means a `kubectl -n logging rollout restart
deployment/log-gateway` after apply.

The key reaches the module as `netbird_setup_key`, which the leaf reads from
SM secret `veeps/tf/keycloak-k8s/<env>` (key `netbird_setup_key`), and the
module writes it to Secret `netbird-setup-key` in `logging`. The Deployment
references that Secret **by name**, not through the Terraform resource, so an
empty `netbird_setup_key` is not a plan failure: the Secret is simply not
managed, everything else is built, and the operator creates it by hand:

```sh
kubectl -n logging create secret generic netbird-setup-key \
  --from-literal=NB_SETUP_KEY='<key from the NetBird console>'
```

Until it exists the gateway pods sit `CreateContainerConfigError` / NotReady
and fluent-bit buffers to disk (512 M per output per node); kubelet retries and
the pods come up on their own once the Secret is there. A later apply with the
key filled in adopts nothing: delete the hand-made Secret first or the apply
fails with "already exists".

The peer runs as pure egress: `NB_DISABLE_DNS`, `NB_BLOCK_INBOUND`,
`NB_DISABLE_CLIENT_ROUTES` and `NB_DISABLE_SERVER_ROUTES` are set (they map to
the `netbird up` flags of the same name), so it never rewrites the pod's
resolv.conf, accepts nothing from the mesh and neither installs nor
advertises routes. NET_ADMIN is the only capability; `/dev/net/tun` is a
hostPath CharDevice for the userspace WireGuard fallback.

## Verifying

```sh
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide      # EXTERNAL-IP = ingress_lb_ip
kubectl get clusterissuer letsencrypt-prod                              # READY True
kubectl -n logging get pods -o wide                                     # fluent-bit x nodes, log-gateway x2 Ready
kubectl -n logging logs deploy/log-gateway -c netbird | tail            # "Connected" / peer status
kubectl -n logging exec deploy/log-gateway -c forwarder -- \
  socat -u OPEN:/dev/null TCP:100.85.165.68:5142,connect-timeout=3 && echo mesh ok
kubectl -n logging exec ds/fluent-bit -- \
  wget -qO- http://127.0.0.1:2020/api/v1/storage                        # chunks up/down, no growth = draining
```

Then on wqelk1, `logs-nginx-*` should carry `shipper: <cluster_name>` and
`logs-syslog-*` should carry `host: <cluster_name>` with
`program: ingress-nginx/controller`, `keycloak/keycloak`, `logging/netbird`.

## Not done here

* No NetworkPolicy on `logging`; the setup key and NetBird ACLs are the
  control on the far side, and VKE's default CNI is permissive inside the
  cluster.
* Port 5141 (auth/security) is forwarded but nothing in the cluster produces
  that stream yet; the keycloak module's event logs go out as syslog.
