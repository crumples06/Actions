# Monitoring Role (Prometheus + Grafana)

Deploys the visualization half of the project's observability stack to a dedicated `monitoring` host: **Prometheus** (metrics collection/storage) and **Grafana** (dashboards). Paired with the separate `node_exporter` role, which is applied to *every* host (including `monitoring` itself) the same way `hardening` is — a cross-cutting concern rather than a per-tier one.

## Architecture

```
web1 ──[node_exporter :9100]──┐
web2 ──[node_exporter :9100]──┤
loadbalancer ──[node_exporter]┼──► Prometheus (scrapes all, stores) ──► Grafana (queries, dashboards)
db ──[node_exporter :9100]────┘
```

- **node_exporter** (separate role) exposes OS-level metrics (CPU, memory, disk, network) on every host at `:9100/metrics`. Passive — it only serves data when scraped, never pushes anything.
- **Prometheus** pulls from every node_exporter target on a 15s interval and stores the time series locally. Scrape targets are generated from Ansible inventory groups (`groups['web'] + groups['loadBalancer'] + groups['db']`), the same pattern the `loadBalancer` role uses for its nginx upstream block — add a host to inventory, rerun the playbook, and Prometheus picks it up with no template changes.
- **Grafana** connects to Prometheus as a datasource and renders the community **Node Exporter Full** dashboard (Grafana.com dashboard ID `1860`).

Both Prometheus and Grafana run on a single dedicated `monitoring` host/group, kept separate from the `node_exporter` role so that "runs everywhere" and "runs once, knows about everything else" stay cleanly separated — same reasoning as keeping `hardening` distinct from `web`/`loadBalancer`.

## Why hand-written init scripts

None of these containers run systemd — `sshd -D` is PID 1, same constraint documented in the `hardening` role. That ruled out the `systemd` Ansible module entirely and meant every long-running daemon in this role needed to be **backgrounded and tracked manually**, via `start-stop-daemon` + a small SysV-style script at `/etc/init.d/<service>`, controlled through the `service` command (mirrors how `hardening`/`db` already use `service` instead of `systemd`).

- **Prometheus** ships as a bare tarball with no init system integration at all — an init script was always going to be needed.
- **Grafana** was expected to ship a SysV script (its historical/documented install pattern does), but the current `apt.grafana.com` package turned out to be **systemd-unit only**. This was caught by checking `dpkg -L grafana` directly rather than trusting install docs, which described an older packaging convention. The actual init script here was hand-translated from Grafana's own `grafana-server.service` unit file (`ExecStart`, `EnvironmentFile`, `User`/`Group`, `RuntimeDirectory`) rather than guessed.

## Directories Ansible has to create by hand

Normally, systemd's `RuntimeDirectory=` and a package's postinst script create these invisibly on a "real" host. Without an init system, they don't exist unless a task creates them explicitly:

| Path | Normally created by | Needed for |
|---|---|---|
| `/etc/prometheus/`, `/var/lib/prometheus/` | manual choice, N/A here | Prometheus config + TSDB data |
| `/run/grafana/` | systemd `RuntimeDirectory=` | Grafana's own pidfile |
| `/var/lib/grafana/plugins/` | apt postinst | `grafana cli plugins ls`/install |

All three are created via explicit `file` tasks, owned by the service's own user (`grafana:grafana` where relevant) — see the permissions note below for why ownership, not just mode bits, matters here.

## Secrets

Grafana's admin password is stored the same way the `db` role handles `vault_db_password`: `roles/monitoring/vars/vault.yml` (Vault-encrypted, `vault_admin_password`) is referenced from `roles/monitoring/vars/main.yml` as `grafana_admin_password`, templated into `grafana.ini`, and the `monitoring` play in `playbook.yaml` has an explicit `vars_files:` entry pointing at it — required because Ansible only auto-loads a role's `vars/main.yml`, not other files in that folder.

**Important Grafana-specific trap:** `admin_password` in `grafana.ini` is only read **once**, at first-ever admin-account creation. Changing it and restarting Grafana does *not* update an existing admin account's password — the value only matters on a truly fresh `grafana.db`. If you need to change the password on a container that's already run once, either use `grafana cli admin reset-admin-password <new password>` or delete `/var/lib/grafana/grafana.db` and let Grafana re-bootstrap.

## Notable bugs hit and fixed

- **Prometheus tarball missing `consoles`/`console_libraries`** — removed from the release tarball as of Prometheus v3.x; most install guides still describe the v2.x layout. The copy tasks for them were simply dropped, no replacement needed.
- **CRLF line endings in the Prometheus init script** — same root cause as the earlier SSH-key corruption incident (Windows-origin file). Caused a misleading `service prometheus start` → "No such file or directory" (actually an execve failure on a `\r`-terminated shebang line). Diagnosed with `cat -A`, fixed with `sed -i 's/\r$//'`.
- **YAML indentation bug in `prometheus.yml.j2`** — sibling keys (`job_name`, `static_configs`) were indented at different depths instead of aligning, plus a `job name`/`job_name` typo. Produced `yaml: line 5: did not find expected key`. Diagnosed by running the `prometheus` binary directly (bypassing the init script) to see its own parse error, then `cat -n` on the rendered file to see the actual indentation.
- **Grafana pidfile permission denied** — `start-stop-daemon --make-pidfile` wrote the pidfile as root *before* dropping to the `grafana` user via `--chuid`; Grafana's own internal `--pidfile` flag then couldn't overwrite a root-owned file. Fixed by dropping `--make-pidfile` entirely and letting Grafana manage its own pidfile.
- **Datasource provisioning "permission denied"** — the templated provisioning file was deployed with `mode: "0640"` but no explicit `owner`/`group`, landing as `root:root`; the `grafana` user (not in the `root` group) couldn't read it. Fixed by setting `owner: grafana, group: grafana` on every task that writes into `/etc/grafana/`.
- **Datasource silently not registering** (`/api/datasources` returning `[]`, no hard error — just a "[Deprecated] the datasource provisioning config is outdated" log line) — root cause was `datasource.yml.j2` rendering as a completely empty file on disk.
- **`grafana cli plugins ls` failing** with "stat /var/lib/grafana/plugins: no such file or directory" — same root-cause class as the `/run/grafana` gap: that directory is normally created by the apt package's postinst script, and doesn't exist on a fresh no-init-system container until a `file` task creates it explicitly.

General lesson that shows up repeatedly across this role: **anything written as root that a non-root service user (`grafana`) later needs to read or write requires explicit `owner`/`group`, not just correct mode bits** — and several directories/behaviors that systemd + apt postinst scripts normally handle invisibly on a "real" host had to be recreated by hand here.

## Deliberately deferred / not implemented

- **Alertmanager** — considered for the kill-and-recover demo, deliberately skipped to keep scope focused. The demo is Grafana-visual-only: stop nginx on `web1`, confirm the load balancer only serves from `web2`, screenshot, restart, screenshot recovery. Adding real alert firing (Alertmanager + notification routing) is a natural next step if this project continues.
- **Service-specific exporters** (e.g. an nginx exporter) — node_exporter only reports host-level OS metrics, so the kill-and-recover demo proves "web1 the container OS is still up" rather than "nginx specifically is down." A dedicated nginx exporter would give a metric that directly reflects service health rather than only host health.
- **CI verification of the monitoring stack** — CI currently verifies web/loadBalancer/db; Prometheus/Grafana health is verified manually, not asserted in `Test_Connection.yml`.

## Container caveat

node_exporter reads `/proc` and `/sys`, which are already namespaced per-container under Docker — so its metrics reflect *this container's* cgroup-scoped resource usage, not the underlying Docker host's physical hardware. This is consistent with the project's existing container-as-host model (the same fiction `hardening`/`web`/`loadBalancer` already rely on) and doesn't need any special handling, but is worth knowing if a panel shows unexpectedly low/high numbers compared to what `docker stats` or the host machine itself would report.