# Infra Showcase Project

An Ansible + Docker + GitHub Actions portfolio project demonstrating multi-tier infrastructure provisioning, security hardening, secrets management, and observability. There's no real application being deployed — the infrastructure itself, and the process of building and hardening it, is the deliverable.

## Architecture

```
                    ┌──────────────┐
                    │  monitoring  │
                    │  Prometheus  │◄──────scrapes (9100)───────┐
                    │  Grafana     │                            │
                    └──────┬───────┘                            │
                           │ :9090 (Grafana datasource)         │
                           ▼                                    │
┌──────────────┐    ┌──────────────┐    ┌──────────────┐   ┌────┴─────┐
│   web1       │◄───┤ loadbalancer │    │   web2       │   │    db    │
│   nginx      │    │   nginx      │───►│   nginx      │   │  mysql   │
└──────────────┘    │ least_conn   │    └──────────────┘   └──────────┘
                    └──────────────┘

  node_exporter runs on every host above (web1, web2, loadbalancer, db, monitoring)
  hardening runs on every host above
```

Five hosts, five roles, one cross-cutting concern applied everywhere:

| Host(s) | Role(s) applied | Job |
|---|---|---|
| `web1`, `web2` | `web`, `hardening`, `node_exporter` | Serve a templated per-host webpage via nginx |
| `loadbalancer` | `loadBalancer`, `hardening`, `node_exporter` | nginx reverse proxy, `least_conn` across the web tier |
| `db` | `db`, `hardening`, `node_exporter` | MySQL, with an app database/user provisioned |
| `monitoring` | `monitoring`, `hardening`, `node_exporter` | Prometheus (scrapes everything) + Grafana (dashboards) |

`hardening` and `node_exporter` are applied identically across every host, the same way — both are "run this everywhere regardless of the host's job" concerns, kept as separate roles from the tier-specific ones (`web`, `loadBalancer`, `db`, `monitoring`) so neither role needs to know or care what else is running on the box.

Per-role detail, gotchas, and deferred items are documented in each role's own README — this document is the map, not the manual:
- [`control/roles/web/README.md`](control/roles/web/README.md)
- [`control/roles/loadBalancer/README.md`](control/roles/loadBalancer/README.md)
- [`control/roles/hardening/README.md`](control/roles/hardening/README.md)
- [`control/roles/db/README.md`](control/roles/db/README.md)
- [`control/roles/monitoring/README.md`](control/roles/monitoring/README.md)

## Why containers-as-hosts

Every managed host (`web1`, `web2`, `loadbalancer`, `db`, `monitoring`) is a Docker container built from the same base `dockerfile`: Ubuntu 22.04 + `openssh-server` + Python + sudo, with an `ansible` user. Ansible connects to each over SSH exactly as it would to a real VM or bare-metal host — the "container-as-host" fiction is deliberate, so every role, inventory group, and playbook play behaves the same way it would against real infrastructure.

The one recurring consequence worth knowing up front: **none of these containers run systemd** — each runs `sshd -D` as PID 1, so there's no init system underneath. This shaped several roles:
- Services are managed via the `service` command against hand-rolled SysV-style scripts (`hardening`, `db`, and every daemon in `monitoring`), not the `systemd` Ansible module.
- Restarting a service uses `command: service X restart` rather than the `service` module's `state: restarted`, which does a separate stop+start that can race.
- Directories/behaviors a real systemd host or an apt package's postinst script would normally set up invisibly (runtime directories, pidfile handling) sometimes had to be recreated by hand — documented in the `monitoring` role README in detail, since that's where it came up most.

## Control node and inventory

`control/` (bind-mounted into the `control` container at `/work`) holds everything Ansible needs: `ansible.cfg`, `inventory.ini`, `playbook.yaml`, and `roles/`. The `control` container itself is `python:3.11-slim` with `ansible`, `sshpass`, `curl`, and the `community.mysql` collection installed on startup.

`inventory.ini` groups:
```ini
[web]
web1
web2

[loadBalancer]
loadbalancer

[db]
db

[monitoring]
monitoring

[all:vars]
ansible_user=ansible
ansible_ssh_private_key_file=ssh_keys/ansible_hardening_key
```

`playbook.yaml` has one play per host group, each running that tier's role plus `hardening` (and, once added, `node_exporter`). Several roles read Ansible's automatic `groups['<name>']` variables directly to stay inventory-driven rather than hardcoding hostnames — the `loadBalancer` role's nginx upstream block and the `monitoring` role's Prometheus scrape-target list both work this way. Add a host to the right inventory group, rerun the playbook, and both configs pick it up automatically.

## Secrets — Ansible Vault

Two secrets are Vault-encrypted, following the same pattern in both places: a `vars/vault.yml` inside the relevant role holds the encrypted value, `vars/main.yml` references it under a plain variable name, and the role's play in `playbook.yaml` has an explicit `vars_files:` entry (required because Ansible only auto-loads a role's `vars/main.yml`, not other files in that directory — this exact gap once left a stale, unused `vault.yml` silently orphaned under `hardening` early in the project).

- `db` role: `vault_db_password` → the app database user's password.
- `monitoring` role: `vault_admin_password` → Grafana's admin account password.

`control/vault_pass.txt` (gitignored) holds the vault password locally; in CI it's written from the `ANSIBLE_VAULT_PASSWORD` GitHub Actions secret, passed via `env:` rather than direct string interpolation into a `run:` step (interpolating a secret containing `$` characters directly into a shell command gets it shell-reinterpreted before bash ever sees the real value — this bit once in CI and is documented in the `db` role's history).

## CI/CD

`.github/workflows/Test_Connection.yml` runs on every PR to `main`:
1. Checkout, restore the SSH keypair and vault password from GitHub Actions secrets.
2. `docker compose up --build --wait` — builds and starts every container fresh, so CI always exercises the full bootstrap path (no key deployed yet, password auth still enabled) rather than testing against already-hardened hosts.
3. Run the playbook with `--vault-password-file`.
4. Verify load balancing: a 10-request loop against the load balancer asserts both `web1` and `web2` appear in the results.
5. Tear down (`if: always()`).

Branch protection on `main` requires this check; merged branches auto-delete.

## SSH and hardening

A dedicated SSH keypair (generated once, public key committed at `control/ssh_keys/*.pub`, private key gitignored) is deployed to every host's `ansible` user via the `hardening` role, after which password authentication is disabled entirely (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`). `inventory.ini` keeps `ansible_password` present but commented out — the documented bootstrap path for a freshly rebuilt container that has no key yet, used explicitly (uncommented, run once, re-commented) rather than left permanently enabled. Full detail, including the SSH-key-committed-to-git-history incident and its remediation (key rotation, not just history rewriting), is in the `hardening` role README.

## Observability

The full metrics pipeline — node_exporter on every host, Prometheus scraping and storing, Grafana visualizing via an auto-provisioned datasource and the community "Node Exporter Full" dashboard — is detailed in the `monitoring` role README, including a long list of real bugs hit along the way (stale install docs, permission/ownership gaps between root-run Ansible tasks and non-root service users, and Grafana's non-obvious "admin password only applies at first bootstrap" behavior).

A kill-and-recover demonstration (stopping nginx on `web1`, observing the effect, restarting) serves as this project's incident-response demo. Alertmanager was deliberately scoped out — the demo is visual (dashboard/load-balancer behavior), not alert-driven — and is documented as a natural next step rather than something silently missing.

## What's deliberately out of scope

Documented per-role rather than treated as oversights:
- **Scoped sudo** — targets currently retain `NOPASSWD:ALL` for the `ansible` user; a narrower command allowlist is a natural next step (`hardening` README).
- **ufw/fail2ban** — not implemented; Docker doesn't grant the `NET_ADMIN`/`NET_RAW` capabilities they'd need by default, and a real deployment should firewall at the host/cloud layer instead (`hardening` README).
- **No persistent volumes / real application** — this is an infra showcase, not a deployed app; the web tier serves a placeholder page and the db tier has no data worth persisting.
- **Alertmanager** — visual-only incident demo instead (`monitoring` README).