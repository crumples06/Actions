# LoadBalancer Role

Installs and configures nginx as a reverse proxy / load balancer in front of the web tier, on the dedicated `loadbalancer` host. Applied alongside `hardening` and `node_exporter` in the `loadBalancer` play of `playbook.yaml`.

## What it does

- Installs `nginx` via `apt`.
- Deploys `templates/nginx.conf.j2` to `/etc/nginx/nginx.conf`. The template loops over `groups['web']` (Ansible's automatic inventory-group variable) to build an `upstream` block listing every web-tier host, using `least_conn` as the balancing algorithm. This means the load balancer's config is generated entirely from inventory — add or remove a host from `[web]` in `inventory.ini`, rerun the playbook, and the upstream block updates automatically with no manual editing. Prometheus's scrape-target list in the `monitoring` role uses the same inventory-driven pattern.
- Deploying the config `notify`s a `reload nginx` handler (`state: reloaded`), so config changes take effect without a full restart.
- Starts and enables nginx via the `service` module.

## Role Variables

None currently defined — `vars/main.yml` and `defaults/main.yml` are both empty placeholders.

## Handlers

- `reload nginx` — `state: reloaded`, triggered by config file changes.
- `restart nginx` — `state: restarted`, defined but not currently wired to any task; available if a future change needs a full restart rather than a reload.

## Verification

Verified in CI (`Test_Connection.yml`, "Verify load balancing" step): a 10-request loop against `http://loadbalancer` asserts that both `web1` and `web2` appear across the responses, confirming `least_conn` is actually distributing traffic across both upstream hosts rather than pinning to one.

Manual check:
```bash
for i in $(seq 1 10); do curl -s http://loadbalancer; echo; done
```
Each response's content should vary between web1 and web2 (per the `web` role's hostname-templated page), confirming both are being hit.

## Dependencies

Depends on `groups['web']` being correctly populated in `inventory.ini` — the upstream block is empty (and nginx would fail to start) if that group is empty or misnamed.

## Deliberately deferred / not implemented

- No health-check-based upstream removal — nginx's open-source build doesn't support active health checks out of the box, so a failed web host currently only drops out of rotation once `least_conn` naturally routes around slow/hung connections, not via an explicit health probe. Worth knowing when reasoning about the kill-and-recover demo in the `monitoring` role: nginx itself doesn't "detect" web1 going down in the same sense Prometheus/Grafana do.
- No TLS/SSL termination — this is an HTTP-only reverse proxy, consistent with the project's scope as an infra showcase rather than a production-facing service.