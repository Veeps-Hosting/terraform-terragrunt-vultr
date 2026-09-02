# keycloak

HA Keycloak on a VKE cluster: the codecentric `keycloakx` chart, four ingress-nginx Ingress
objects, a management Service, a read-only monitoring identity for Icinga, and optional backup
CronJobs to Vultr object storage. Consumes cluster credentials from `vke`, the database from
`managed_database`, and the ingress class + ClusterIssuer that `k8s_baseline` installs.

`cluster_endpoint` may be the bare host/IP that `vke` outputs (it becomes
`https://<host>:6443`) or a full `https://` URL; the same normalised `api_url` feeds the
kubernetes, helm and kubectl providers and the `monitor_api_url` output.

Build contract: Monday 2801647539 (Keycloak SSO via HA Kubernetes cluster). Chart templates and
values were verified against tag `keycloakx-7.3.1` (appVersion 26.7.3).

## What it creates

| Object | Name | Notes |
|---|---|---|
| Namespace | `keycloak` (`namespace`) | |
| Secret | `keycloak-db` | `KC_DB_URL/USERNAME/PASSWORD` for Keycloak **and** `PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD/PGSSLMODE` for `pg_dump`, from the same inputs; with `db_ca_certificate` also `PGSSLROOTCERT` and the CA as `ca.crt` |
| Secret | `keycloak-admin` | `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` — first start of an empty master realm only |
| random_password | `admin` | only when `admin_password` is empty — the generated bootstrap password (state + Secret only) |
| ConfigMap | `keycloak-theme` | `themes.tgz` (binary) — the login theme tarball |
| helm_release | `keycloak` | chart `keycloakx`; StatefulSet `keycloak-keycloakx`, Services `keycloak-keycloakx-http` (80 + 9000) and `-headless`, PDB `minAvailable: 1` |
| Service | `keycloak-mgmt` | ClusterIP 9000 → management port (health/metrics) |
| Ingress | `keycloak` | public `/auth`, cert-manager annotation, TLS secret `keycloak-tls` |
| Ingress | `keycloak-admin` | `/auth/admin`, `/auth/welcome`, `/auth/realms/master` — whitelist + scope fix |
| Ingress | `keycloak-scopefix-<realm>` | `/auth/realms/<realm>/protocol/openid-connect/auth` — scope fix, one per realm in `scope_fix_realms` except `master` |
| Ingress | `keycloak-mgmt` | `/auth/health`, `/auth/metrics` → `keycloak-mgmt:9000` — monitor + admin whitelist |
| Secret / ConfigMap / CronJob ×2 | `keycloak-backup-s3`, `keycloak-backup-scripts`, `kc-pgdump`, `kc-realm-export` | only when `backups_enabled` |
| ServiceAccount / ClusterRole + binding / Role + binding / Secret | `icinga-monitor`, `icinga-monitor-token` | read-only identity for `check_vke_platform`; always created |

## Keycloak configuration

- `kc.sh start` (not `start-dev`, not `--optimized`): the image auto-builds on first start
  because `KC_DB`, `KC_FEATURES`, health and metrics are build options. Allow ~60-90 s per pod;
  the chart's startup probe gives 300 s and `helm_release.timeout` is 600 s.
- `KC_HTTP_RELATIVE_PATH=/auth` and `KC_HOSTNAME=https://<hostname>/auth`. The full-URL
  hostname (hostname:v2) is what makes issuer, admin-console and redirect URLs carry `/auth`;
  drop the path and Keycloak silently generates links without it.
- Proxy headers `xforwarded`, HTTP enabled, health + metrics enabled, JSON console logging,
  login/admin events via the `jboss-logging` listener at info/warn (26.x `--spi-…--…--` form,
  i.e. `KC_SPI_EVENTS_LISTENER__JBOSS_LOGGING__SUCCESS_LEVEL`).
- Cache: chart default `ispn` + `jdbc-ping` — cluster discovery through the database, no RBAC
  or headless-DNS query, works across node replacement.
- `KC_DB_POOL_MAX_SIZE` (default 40/pod). Keycloak's default of 100 per pod would let two pods
  exceed the 97-connection ceiling of the `business-cc-1-55-2` plan.
- `passkeys_enabled` toggles `KC_FEATURES=passkeys` / `KC_FEATURES_DISABLED=passkeys`, the same
  pair the docker-compose template on wqkc3/wqkc4 uses. `passkeys:v1` is on by default from
  26.4, so the explicit flag is about keeping the two platforms identical, not about enabling
  it.
- The chart already emits `KC_PROXY_HEADERS`, `KC_HTTP_ENABLED`, `KC_HEALTH_ENABLED`,
  `KC_METRICS_ENABLED`, `KC_DB`, `KC_CACHE*` from its own values; only what it does not emit
  goes through `extraEnv`, so no env name appears twice in the pod spec.

### Database TLS

Without `db_ca_certificate` the connection is `sslmode=<db_sslmode>` (`require` by default:
encrypted, CA not verified — how the fleet connects today). With it:

- `KC_DB_URL` becomes `...?sslmode=verify-full&sslrootcert=/etc/keycloak/db-ca/ca.crt`;
- the `keycloak-db` Secret gains `PGSSLMODE=verify-full`, `PGSSLROOTCERT=/etc/keycloak/db-ca/ca.crt`
  and the CA as `ca.crt`;
- the Keycloak pods, the `kc-pgdump` initContainer and the `kc-realm-export` initContainer all
  mount **only** the `ca.crt` key of that Secret, read-only, as the directory
  `/etc/keycloak/db-ca/` (a directory mount, not `subPath`, so a rotated CA propagates without a
  restart; a `checksum/db-tls` pod annotation still rolls the StatefulSet when the URL or CA
  changes).

The value may be the PEM or the base64 of the PEM (a plan-time validation rejects anything
else). `verify-full` also checks `db_host` against the server certificate's SAN — prove that from
jenkci1 (`psql "host=<db_host> port=<db_port> dbname=<db_name> user=<db_user> sslmode=verify-full
sslrootcert=ca.crt"`) before wiring the CA into a leaf, otherwise Keycloak fails to start on the
next rollout.

### Bootstrap admin password

`admin_password` is the value the leaf reads from AWS Secrets Manager
`veeps/tf/keycloak-k8s/<env>` (key `keycloak_admin_password`). The read is tolerant: if the
secret is missing or unreadable the leaf passes `""` and the module generates a 32-character
password with `random_password` (provider `hashicorp/random ~> 3.6`). Either way the value that
seeded `KC_BOOTSTRAP_ADMIN_PASSWORD` is the `bootstrap_admin_password` output
(`terragrunt output -raw bootstrap_admin_password`). It only matters until the master realm is
imported; the imported `admin` keeps its own password, which is rotated with `kcadm` (SEC-02, see
"Running kcadm" below).

`extraEnv`, `extraEnvFrom`, `extraInitContainers`, `extraVolumes` and `extraVolumeMounts` are
**strings** the chart passes through `tpl`; the module builds them with a nested `yamlencode()`.

### Login theme

`files/keycloak_themes_23_kc26.tgz` is a byte copy of openvox
`site/profile/files/keycloak_themes_23_kc26.tgz` (the tarball wqkc3/wqkc4 mount). It lands in the
`keycloak-theme` ConfigMap; a busybox init container running as uid 1000 untars it into an
emptyDir mounted at `/opt/keycloak/themes`, asserts `/opt/keycloak/themes/<theme_name>` exists,
then `chmod -R u+rwX,go+rX` **each extracted top-level entry** — never the mount root. The
chart's `podSecurityContext.fsGroup: 1000` makes the emptyDir group-writable, but its root stays
root-owned, so a `chmod`/`chown` on the root is `EPERM` for uid 1000 and would kill the script
under `set -e`. The main container mounts the same `themes` emptyDir at `/opt/keycloak/themes`.
`/opt/keycloak/themes` is empty in the stock image (built-in themes are in the jar), so masking it
loses nothing. A `checksum/theme` pod annotation rolls the StatefulSet when the tarball changes.
To update the theme, replace the file in the openvox repo, copy it here, tag the module.

## Ingress layout and whitelists

ingress-nginx merges all four Ingress objects for a host into one nginx `server` and picks the
longest matching `location`, so `/auth/admin` (admin ingress) always wins over `/auth` (public).
Every ingress carries **every** host in `[hostname] + extra_hostnames` — if the alias were only on
the public ingress, `/auth/admin` on the alias would fall through to the unrestricted `/auth`
rule.

Whitelists **fail closed**: an empty `admin_whitelist_cidrs` renders
`whitelist-source-range: 127.0.0.1/32` on the admin ingress, and an empty
`monitor_cidrs + admin_whitelist_cidrs` does the same on the mgmt ingress. A forgotten list denies
the admin console everywhere; it never opens it.

The scope fix is the `nginx_keycloak` `raw_prepend` carry-forward:

```
if ($args !~ "scope=") { set $args "${args}&scope=openid"; }
```

(written `$${args}` in HCL). It goes on the admin ingress for `master` — a separate longer-path
ingress for `/auth/realms/master/protocol/openid-connect/auth` would sit outside the whitelist —
and on its own ingress per public realm. Requires `allowSnippetAnnotations` and
`annotations-risk-level: Critical` on the controller (set by `k8s_baseline`).

Only the public ingress carries `cert-manager.io/cluster-issuer`; the other three reference the
same `keycloak-tls` secret so cert-manager orders exactly one certificate. Add a name to
`extra_hostnames` only once its DNS resolves to the LB: one failing HTTP-01 blocks the whole
order.

Proxy settings match the fleet nginx (600 s read/send timeouts, 16m body) plus
`proxy-buffer-size: 128k` — Keycloak's cookie-heavy responses overflow nginx's 4k default and
surface as 502s.

## Backups

`backups_enabled = true` requires `backup_s3_hostname`, `backup_s3_access_key` and
`backup_s3_secret_key` (a plan-time precondition refuses blanks). Wire them from the
`object_storage` leaf outputs.

| CronJob | Schedule (UTC) | initContainer | Artefact |
|---|---|---|---|
| `kc-pgdump` | `0 15 * * *` | `postgres:17-alpine` runs `files/pgdump.sh` (`pg_dump --format=plain --compress=gzip:6 --no-owner --no-privileges`) | `s3://<bucket>/<prefix>/pgdump/<prefix>-pgdump-<stamp>.sql.gz` |
| `kc-realm-export` | `30 15 * * 0` | `quay.io/keycloak/keycloak:<version>` runs `kc.sh export --dir /backup/realms --users different_files` with `KC_DB=postgres`, `KC_CACHE=local` | `s3://<bucket>/<prefix>/realm-export/<prefix>-realms-<stamp>.tgz` |

Both: `concurrencyPolicy Forbid`, history 3/3, `backoffLimit 1`, `startingDeadlineSeconds 3600`,
no service-account token. The leaves pass one bucket per environment
(`backup_bucket = "kck8s-backups-staging"` / `"kck8s-backups-prod"`, from the per-environment
`object_storage` leaf); the module default `kck8s-backups` is only a stand-in for ad-hoc plans.
`<prefix>` defaults to the hostname, which keeps the key layout `<prefix>/<kind>/` stable across
a rename or a shared bucket. With `db_ca_certificate` set, both jobs run with
`PGSSLMODE=verify-full` / `PGSSLROOTCERT` (pg_dump) and the pinned `KC_DB_URL` (realm export) and
mount the CA; `pgdump.sh` refuses to run a `verify-*` dump without a readable CA file.

The main container is `amazon/aws-cli:2.27.0` running `files/upload.sh`: `head-bucket ||
create-bucket`, pack `/backup/realms` into a `.tgz` if present, `aws s3 cp` every file in
`/backup`, then delete objects under `<prefix>/<kind>/` whose `LastModified` is older than
`backup_retention_days`. Pruning never leaves that key prefix, is skipped for retention < 1, and
skips (never deletes) an object whose date it cannot parse.

Image facts that shaped the scripts: the aws-cli image (Amazon Linux 2023) has `python3` and GNU
`date` but **no `tar` or `gzip`** — packing uses `python3 -m tarfile`; `pg_dump` compresses with
its own zlib. The Keycloak image is ubi-micro based and `tar` is not guaranteed there either,
which is why the export container only writes the directory. `AWS_REQUEST_CHECKSUM_CALCULATION`
/ `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required` are set because aws-cli ≥ 2.23 sends CRC
trailers that Ceph-based S3 stores reject.

Run one by hand:

```
kubectl -n keycloak create job --from=cronjob/kc-pgdump kc-pgdump-manual
kubectl -n keycloak logs job/kc-pgdump-manual -c pgdump
kubectl -n keycloak logs job/kc-pgdump-manual -c upload
```

Restore a dump into an empty database with the same `PG*` values the job used:

```
eval "$(kubectl -n keycloak get secret keycloak-db -o json \
  | jq -r '.data | to_entries[] | select(.key | startswith("PG")) | "export \(.key)=\(.value | @base64d)"')"
gunzip -c <prefix>-pgdump-<stamp>.sql.gz | psql
```

Restore a realm export: untar, then `kc.sh import --dir <dir> --override true` from a tools pod
(runbook in openvox `ai_context/runbooks/keycloak_k8s_platform.md`).

## Monitoring identity

`check_vke_platform` on the Icinga masters (openvox `profile::icinga2master`) reads nodes,
the `keycloak-keycloakx` StatefulSet and cert-manager Certificates. The module creates the
ServiceAccount `keycloak/icinga-monitor`, a ClusterRole (`nodes` get/list/watch) with its
ClusterRoleBinding, a namespaced Role (`apps/statefulsets` get/list, `cert-manager.io/certificates`
get/list) with its RoleBinding, and a `kubernetes.io/service-account-token` Secret
`icinga-monitor-token` (the apply waits for the token controller to fill it). Feed wqmon2 from the
outputs:

```
terragrunt output -raw monitor_api_url
terragrunt output -raw monitor_ca_pem   > kck8s-<env>.ca.pem
terragrunt output -raw monitor_token    # -> veeps/puppet/node/wqmon2... veeps::secret::vke_monitor::<cluster>_token
```

Revoke by deleting the Secret (`kubectl -n keycloak delete secret icinga-monitor-token`) and
re-applying, which mints a new token.

## Running kcadm (verification, SEC-02 rotation)

jenkci1 (104.156.233.90) is **not** on the admin whitelist, so `kcadm` cannot reach
`/auth/admin` through the ingress from there. Run it from a `kc-tools` pod inside the cluster
against the chart's ClusterIP Service, which bypasses the ingress entirely:

```
kubectl -n keycloak run kc-tools --image=quay.io/keycloak/keycloak:26.7.3 --restart=Never \
  --command -- sleep infinity
kubectl -n keycloak exec -it kc-tools -- /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://keycloak-keycloakx-http/auth --realm master --user admin
kubectl -n keycloak exec -it kc-tools -- /opt/keycloak/bin/kcadm.sh get users -r webqem --fields id | grep -c id
kubectl -n keycloak exec -it kc-tools -- /opt/keycloak/bin/kcadm.sh set-password -r master \
  --username admin --new-password "$(aws secretsmanager get-secret-value ... | jq -r .keycloak_admin_password)"
kubectl -n keycloak delete pod kc-tools
```

The same pod (with `envFrom` the `keycloak-db` Secret and `KC_DB=postgres`) is where
`kc.sh import` runs during the migration; the runbook in openvox
`ai_context/runbooks/keycloak_k8s_platform.md` has the full procedure.

## Migration notes

- The bootstrap admin only exists until the master realm is imported from wqkc4/wqkc3; after
  that the source instance's `admin` wins. Rotate its password to the SM value with `kcadm`
  from the kc-tools pod (SEC-02).
- `extra_hostnames` is for the kc4.staging alias later; it changes nothing in `KC_HOSTNAME`.
- The compose template's dev-only theme flags (`--spi-theme-cache-*=false`,
  `--spi-theme-static-max-age=-1`) and `KC_HOSTNAME_STRICT=false` / `KC_HOSTNAME_DEBUG=true` are
  deliberately not carried over.

## Outputs

`namespace`, `hostname`, `http_service` (`keycloak-keycloakx-http`), `mgmt_service`
(`keycloak-mgmt`), `bootstrap_admin_password` (sensitive), `monitor_api_url`, `monitor_ca_pem`,
`monitor_token` (sensitive).
