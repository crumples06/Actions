# DB Role

Installs and configures MySQL for the application data tier, applied to the `db` host group.

## What it does

### MySQL install and startup

- Installs `mysql-server` and `python3-pymysql` (a target-side dependency required by Ansible's `community.mysql` modules).
- Starts MySQL via `command: service mysql restart` rather than the `service` module's `state: restarted`. The `service` module issues a separate stop-then-start rather than the init script's own atomic restart; under this container's minimal init environment, the start step can fire before the stop step has fully released MySQL's socket/lock files, silently leaving the daemon down while still reporting `changed: true`. Calling the init script directly avoids the race. `changed_when: true` is set explicitly since `command` has no built-in idempotency detection.
- Waits for `/var/run/mysqld/mysqld.sock` to exist (`wait_for`) before continuing — mysqld takes a few seconds after starting to finish initialization and create its socket, and any task run before that races and fails with a misleading "connection refused"/"no such file" error.

### Application database and user

- Creates an application database (`myapp`) and a dedicated app user (`myapp_user`) via `community.mysql.mysql_db` / `community.mysql.mysql_user`.
- Both tasks authenticate via `login_unix_socket`, not the modules' TCP default — a fresh MySQL install only trusts `root` locally over the Unix socket, not over TCP with no password.
- The app user's password is never stored in plaintext: it's Ansible Vault-encrypted in `vars/vault.yml` (`vault_db_password`), referenced from `vars/main.yml` as `db_password`. Because Ansible only auto-loads a role's `vars/main.yml` — not other files sitting in the same `vars/` folder — `vault.yml` must be loaded explicitly via `vars_files` in the play (see `playbook.yaml`), or `vault_db_password` resolves as undefined even though the file itself decrypts correctly.

## Requirements

- Run `ansible-galaxy collection install community.mysql` on the control node before this role can use `mysql_db`/`mysql_user` — they're not part of Ansible core.
- Requires `--vault-password-file vault_pass.txt` on every `ansible-playbook` run, same as the rest of this project's vault-encrypted content.

## Deliberately deferred / not implemented

**Persistent storage** — the `db` container has no Docker volume, so its data does not survive a `docker compose down`/`up` cycle. This is intentional: this project is an infrastructure showcase with no real application behind it, so persistence adds operational complexity without adding to the demonstration. A real deployment would attach a named volume to `/var/lib/mysql`.

**Cache tier (Redis)** — scoped out to keep this milestone focused; the multi-tier connectivity pattern is already demonstrated by the DB alone.

**CI verification** — the pipeline currently proves the playbook runs against the `db` host successfully, but does not yet assert the database/user are actually queryable end-to-end.