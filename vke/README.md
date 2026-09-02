# vke

A Vultr Kubernetes Engine cluster: HA control plane, managed firewall group, one default node
pool, optional extra pools, and a lookup of the VPC the cluster lives in. Consumed by the
`k8s_baseline` and `keycloak` modules through terragrunt dependency outputs.

## What you get (`5.0`+)

- `vultr_kubernetes.cluster` with `ha_controlplanes` and `enable_firewall` defaulting **on**.
  Both are ForceNew, as is `vpc_id`: change any of them on a live cluster and the plan is a
  rebuild. `k8s_version` is not ForceNew — a change is an in-place upgrade by VKE, rehearsed on
  staging first.
- One default pool `<label>-default` of `node_quantity` × `node_plan` (3 × `vc2-2c-4gb`), with
  `node_labels` applied to every node in it.
- `extra_node_pools` as `{ <label> = { plan, node_quantity, [auto_scaler, min_nodes, max_nodes,
  labels] } }`.
- Outputs: the kubeconfig and the three client credentials (sensitive, base64 as the API returns
  them), the pod and service subnets, the default pool id, and `vpc_id` / `vpc_cidr`.

## The VPC lookup

VKE creates a VPC per cluster when none is given, but the provider never reads its id back:
`vpc_id` on the resource is write-only (the Read function sets every other attribute). So the
module looks the VPC up with a `vultr_vpc` data source filtered on the description VKE gives it,
`VKE-Network-<cluster id>`. The filter is an exact string match, so the orphan `VKE-Network-*`
VPCs left in the account by earlier experiments cannot be picked up.

`vpc_cidr` is `<v4_subnet>/<v4_subnet_mask>` and is what the `managed_database` leaf puts in
`trusted_ips`. It is populated whether the VPC was created by VKE or passed in as `vpc_id` (a
second lookup, by id, covers that case) and is `""` only when neither lookup exists.

If the first apply of a new cluster fails at the data source with `no results were found`, VKE
has named the VPC differently from the pattern above. Fix the filter in `main.tf` and re-apply:
it is a data source change, the cluster is already built, and nothing else in the module depends
on the description format.

## Autoscaler

`auto_scaler = false` (the default) is a fixed pool: `min_nodes` and `max_nodes` are pinned to
`node_quantity` unless set, the same rule the extra pools use. With the autoscaler on, set all
three explicitly in the leaf.

## Node pool sizing

The default pool's `plan` and `label` are effectively immutable in provider 2.32: the
`node_pools` update only sends quantity, autoscaler bounds and labels (Vultr has no API call to
change a pool's plan), so editing `node_plan` on a live cluster **plans as an in-place update
and changes nothing** - the nodes keep their old size while the plan output looks like it
succeeded. `node_quantity` is a real in-place change. The default `node_pools` block is
required (min 1 / max 1 in the schema) so it cannot be removed from the resource, and the API
minimum for a pool is one node.

To move the workers to a bigger plan (prod to `vc2-4c-8gb` before cutover):

1. Add a pool with the new plan: `extra_node_pools = { "kck8s-prod-large" = { plan =
   "vc2-4c-8gb", node_quantity = 3 } }`, apply, wait for the nodes to be `Ready`.
2. Drain the default-pool nodes one at a time: `kubectl cordon <node>` then `kubectl drain
   <node> --ignore-daemonsets --delete-emptydir-data`. The PDBs (keycloak, ingress-nginx,
   log-gateway) keep one replica of each up while the pods move.
3. Shrink the old pool: set `node_quantity = 1` (the minimum the resource accepts), apply. One
   small node stays; leave it cordoned or let it carry DaemonSets only. `node_plan` stays as
   it was so the plan matches the live pool.

Alternatively rebuild the cluster: nothing stateful lives in it (the database is external), so
`terragrunt destroy` + apply with the new `node_plan` and re-applying baseline and keycloak is
the cleaner result for a cluster that has not been cut over yet. DNS changes because the LB is
rebuilt.

## Destroy

Order: `keycloak`, then `k8s_baseline` (its Service removal is what makes the CCM delete the
Vultr LB - destroy the cluster with the Service still there and the LB is orphaned in the
account), then the `db` leaf (it is attached to the cluster VPC), then this module. Terragrunt
`run-all destroy` follows the dependency graph and does this on its own.

What happens to the VPC depends on how the cluster got one:

- **`vpc_id` supplied by the leaf** (the tf-infra-live design: a `vpc` leaf per environment)
  - this module only ever placed the cluster in it. Destroying the cluster leaves the VPC
  intact and it is destroyed by its own leaf. Nothing leaks.
- **`vpc_id = ""`** - VKE created a `VKE-Network-<cluster id>` VPC, and this module only
  *reads* it (`data.vultr_vpc.cluster`); it is **not in state**, so `destroy` removes the
  cluster and leaves the VPC behind, the way the two orphan `VKE-Network-*` VPCs already in
  the account got there. Record the id before destroying (`terragrunt output -raw vpc_id`; the
  data source is gone afterwards) and delete it by API once the cluster is gone:

  ```sh
  curl -X DELETE -H "Authorization: Bearer $VULTR_API_KEY" https://api.vultr.com/v2/vpcs/<vpc id>
  ```

  The delete fails with a 4xx while anything is still attached (the database, the LB), which
  is the right order check.

## Kubeconfig

```
terragrunt output -raw kube_config | base64 -d > ~/.kube/kck8s-<env>
```

Both the kubeconfig and the split credentials are base64 exactly as the VKE API returns them;
the `k8s_baseline` and `keycloak` providers `base64decode()` the split ones.
