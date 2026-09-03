# managed_database

A Vultr Managed Database (PostgreSQL) for Keycloak: the one hard-stateful component of the
platform, kept out of the cluster. Attached to the cluster's VPC and reachable only from a
trusted list the module refuses to plan without.

## Plan

`vultr-dbaas-business-cc-1-55-2` — primary + standby with managed failover, 1 vCPU / 2 GB /
55 GB, 97 connections, US$50/mo in syd (2026-09-02) — in **both** environments. The single-node
startup plan is US$20 cheaper and would be the only SPOF in a platform built to have none; a
6–9 MB Keycloak database gets nothing from a bigger box.

- `plan` is not ForceNew: a change is an in-place resize.
- `database_engine` is ForceNew: a different engine is a different database.
- `database_engine_version` is not ForceNew, but a change is a major upgrade Vultr performs in
  place. Rehearse on staging.

## Network: fail closed (`5.0`+)

Vultr's default for a managed database is reachable from anywhere with the password. The
module therefore refuses to plan with `trusted_ips` empty, with a bare address instead of a
CIDR, or with a `/0` world route in it. The intended list is the cluster VPC subnet plus the
deploy host:

```
vpc_id      = dependency.vke.outputs.vpc_id
trusted_ips = [dependency.vke.outputs.vpc_cidr, "104.156.233.90/32"]
```

`mock_outputs` for the vke dependency must give `vpc_cidr` a real CIDR (`"10.0.0.0/20"`) or a
`validate`/`plan` against mocks fails the same check — which is the point.

Attaching the VPC is what makes `host` a private address; `public_host` is the public one and
sits behind the same trusted list. Pod egress leaves the node on its VPC address, so the whole
VPC subnet is trusted rather than the pod CIDR. If a connection from a pod is refused on first
apply, check which source address Vultr sees before widening anything.

## Backups and maintenance (UTC)

| when      | what |
|-----------|------|
| 15:00     | `kc-pgdump` CronJob in the cluster (keycloak module) → object storage |
| 16:00     | Vultr's own daily backup (`backup_hour` / `backup_minute`) |
| 17:10     | bak3 pulls the bucket into rsnapshot rotation |
| 18:00 Sun | Vultr maintenance window (`maintenance_dow` / `maintenance_time`) |

All of it clear of the 22:00 UTC fleet backup window.

## Outputs

`id`, `host`, `public_host`, `port` (a string, as the provider exports it), `dbname`, `user`,
`password`, `status`, `vpc_id`, `ca_certificate`. `password` is marked sensitive here because the
provider does not mark it; without that it prints in plan output. The keycloak leaf builds its
JDBC URL and the `keycloak-db` secret from these.

`ca_certificate` is the PEM of the CA that signed the server certificate, as the Vultr API
returns it. It is deliberately not sensitive - it is public CA material - so it can flow through
terragrunt dependency outputs into a ConfigMap. Keycloak uses it for `sslmode=verify-full`: with
`require` the JDBC driver accepts any certificate on the way to the private host, with
`verify-full` it pins this CA and checks the hostname, which is the only setting under which a
VPC neighbour cannot sit in the middle.

## Guardrails

- No `prevent_destroy` yet: the platform is being built and staging will be torn down and
  rebuilt. Add it before the prod cutover so destroying the identity store needs a code change,
  the way the compute module protects reserved IPs.
- Vultr rotates the admin password on request through its API; the provider re-reads it, and
  the keycloak leaf picks the new value up on its next apply.

## `backup_minute` is `"0"`, not `"00"` (5.6+)

Vultr stores the backup minute unpadded and returns `"0"`. A `"00"` default
therefore drifts on every plan, and the drift is not cosmetic: on an update the
provider sends `backup_minute` on its own, and the API answers
`422 Backup hour and minute must be set together.` That blocks **every**
in-place change to the resource — a `trusted_ips` edit included, which is how it
was found (2026-09-03). If a future field shows the same "always changing"
behaviour, check what the API actually returns before assuming it is harmless.
