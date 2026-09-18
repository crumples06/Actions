# Hardening Role

Applies security hardening to all managed hosts (`web1`, `web2`, `loadbalancer`), independent of each host's specific job. Tasks are designed to be idempotent and safe to re-run.

## What it does

### SSH key-based authentication

- Generates a dedicated SSH keypair (not committed to the repo — see `ssh_keys/` below) and deploys the public key to the `ansible` user on every managed host via `authorized_key`.
- Fixes private key file permissions automatically (`0600`) before any key-based connection is attempted, regardless of how the key file lands on disk (bind mounts don't always preserve strict permissions).
- Once key-based access is verified working end-to-end, `PasswordAuthentication` is disabled in `sshd_config` on every host — password login is no longer accepted for any user.

### Root login restriction

- `PermitRootLogin` is set to `prohibit-password`, meaning root cannot log in via password under any circumstance. (Root has no deployed key in this project, so root login is effectively fully disabled — this setting reflects standard hardening practice regardless.)

### Config reload, not restart

- SSH config changes are applied via a `reload` handler, not `restart`. These containers run `sshd -D` as PID 1 with no init system — a restart would kill the container itself, since Docker stops a container the moment its PID 1 process exits. Reload re-reads config without terminating the process.


## Deliberately deferred / not implemented

**Scoped sudo** — targets currently retain `NOPASSWD:ALL` for the `ansible` user. Replacing this with a narrow, path-specific command allowlist (e.g. only `apt`, `service`, and the specific binaries each role actually needs) is a natural next step, deferred here to keep this project's scope focused on the highest-impact hardening changes first.

**ufw / fail2ban** — not implemented, deliberately. Both require the `NET_ADMIN` (and typically `NET_RAW`) Linux kernel capability to modify `iptables`/`netfilter` rules, which Docker containers do not grant by default. Granting these capabilities would let each container rewrite host-level firewall rules — a meaningfully larger privilege expansion than the security benefit justifies in a lab/portfolio context. In a real deployment (VMs or bare metal), firewalling and intrusion-prevention belong at the host or cloud security-group layer, not inside individual application containers — so this gap reflects an architectural boundary of the container-based demo environment, not an oversight.

## Bootstrapping a freshly-rebuilt container

If a target container is destroyed and recreated (e.g. `docker compose down && docker compose up`), it will have no key deployed yet and password auth will still need to be used once to re-establish key access. `ansible_password` is kept in `inventory.ini`, commented out by default, specifically for this bootstrap case — uncomment it, run the playbook once, then comment it back out and confirm a key-only run succeeds.