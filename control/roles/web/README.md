# Web Role

Installs nginx and deploys a simple templated webpage to each web-tier host (`web1`, `web2`). Applied alongside `hardening` and `node_exporter` in the `web` play of `playbook.yaml` — `web` handles the host's actual job, the other two are cross-cutting concerns applied the same way across every tier.

## What it does

- Installs `nginx` via `apt`.
- Installs `ufw` (package only — no rules are configured; see [Deliberately deferred](#deliberately-deferred--not-implemented) in the `hardening` role README for why firewalling isn't active in this container-based setup).
- Deploys `templates/index.html.j2` to `/var/www/html/index.html`. The template uses `inventory_hostname`, so each host serves a page identifying itself — this is what makes the CI load-balancing check (and manual browser testing) able to distinguish `web1` from `web2` behind the load balancer rather than seeing identical content from both.
- Starts and enables nginx via the `service` module (`state: started`, `enabled: true`).

## Role Variables

None currently defined — `vars/main.yml` and `defaults/main.yml` are both empty placeholders.

## Verification

Confirmed both indirectly (via the `loadBalancer` role and the CI load-balancing check, which asserts both `web1` and `web2` appear across repeated requests through the load balancer) and directly:

```bash
curl http://web1
curl http://web2
```

Each should return a page whose content differs only in the hostname it reports.

## Dependencies

None directly — relies on `groups['web']` being correctly populated in `inventory.ini` for the `loadBalancer` role's upstream config and Prometheus's scrape targets to find these hosts, but the `web` role itself doesn't reference other roles or groups.

## Deliberately deferred / not implemented

- No real application — this is a portfolio/showcase project, so the "web tier" is a placeholder page rather than a deployed app. Swapping in a real app would mean replacing this role's task list and template with whatever that app's deployment actually requires.
- `ufw` is installed but not configured — same reasoning as the `hardening` role's decision not to manage firewall rules inside these containers (Docker doesn't grant `NET_ADMIN`/`NET_RAW` by default; real deployments should firewall at the host/cloud layer).