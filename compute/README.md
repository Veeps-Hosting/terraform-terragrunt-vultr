# compute

A Vultr virtual server plus its forward A record and IPv4/IPv6 PTR records, and optionally a
reserved IP used as the server's main IP.

## Reserved IPs (`4.2`+)

`reserved_ip = true` creates an unattached `vultr_reserved_ip` and passes it to the instance as
`reserved_ip_id`, which Vultr uses as the **main IP at create time**. The A and PTR records
follow `main_ip`, so they land on the reserved IP with no extra wiring.

Before `4.2` this variable created a reserved IP and attached it to the running instance, which
Vultr adds as a *secondary* address on the main NIC — nothing pointed at it. No leaf ever used it.

### Existing servers

The flag alone does nothing to an instance that already exists: `reserved_ip_id` is ForceNew and
is only written at create, and the module carries `ignore_changes = [reserved_ip_id]` so that
adding the flag cannot destroy and rebuild a live host.

To give an existing server a reserved IP, convert its main IP out of band and import the result:

```
curl -s -X POST https://api.vultr.com/v2/reserved-ips/convert \
  -H "Authorization: Bearer $VULTR_API_KEY" -H "Content-Type: application/json" \
  -d '{"ip_address":"<main_ip>","label":"<hostname>-reserved-ip"}'

terragrunt import 'vultr_reserved_ip.reserved_ip[0]' <reserved-ip-uuid>
```

Converting does not change the address and does not require a restart. Never leave a
`reserved_ip = true` leaf unimported: any apply in that window creates a second, unattached
reserved IP and blocks the import.

### Guardrails

- `prevent_destroy = true` on the reserved IP. A destroy, or flipping the flag back to `false`,
  fails at plan time rather than stripping a live host's main IP. Releasing an IP is a deliberate
  `terragrunt state rm` followed by `DELETE /v2/reserved-ips/<id>`.
- `reserved_ip_type` accepts `v4` only; the instance create field is `ReservedIPv4`.
- `reserved_ip_label` overrides the default label `<hostname>-reserved-ip`, for addresses that
  were converted by hand under another name.
- Never add `create_before_destroy` to the instance: two instances cannot hold one reserved IP.

Reserved IPs are region-locked and billed per IP whether attached or not.

## adopt_existing

`adopt_existing = true` leaves `ssh_key_ids` and `script_id` unmanaged so the module can take
over an instance created outside it. Both are ForceNew, so managing them would rebuild the
server. Such an instance has no startup script, and a `-replace` on it boots with no bootstrap.
