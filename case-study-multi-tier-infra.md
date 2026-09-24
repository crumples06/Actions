# Case Study: Provisioning, Hardening, and Monitoring a Multi-Tier Infrastructure from Scratch

## The Problem

Most infrastructure work isn't glamorous — it's making sure that when a server gets rebuilt, when a service crashes, or when someone new joins the team, nothing has to be figured out from memory. I wanted to prove I could build that kind of infrastructure end-to-end: provisioned automatically, secured by default, and observable enough that a failure shows up on a dashboard instead of in a support ticket.

So I built a five-tier system — two web servers behind a load balancer, a database, and a monitoring stack — and treated it exactly like production infrastructure, even though it was a personal project. Every host is provisioned from a single command. Every configuration change is version-controlled. Every claim about "it recovers automatically" is backed by a recorded demo, not a description.

## The Approach

**Everything is defined as code, not clicked together.** Ansible playbooks and roles describe the desired state of every host — install this, configure that, start this service — so the entire five-host environment can be torn down and rebuilt from nothing in one command. Docker containers stand in for real servers, connected over their own network, so the setup can be tested and demonstrated without touching real infrastructure or costing anything to run.

**The build order mirrored how I'd actually prioritize a client engagement.** I got the core system working first — web tier, load balancer — then deliberately paused feature work to add security hardening (SSH key-only auth, disabled root login, disabled password auth) before touching the database tier. The reasoning: a database holding real data is exactly the kind of thing you don't want sitting on a host you haven't hardened yet. Observability (Prometheus + Grafana) came last, once there was something worth monitoring.

**Secrets are never stored in plain text.** Database and dashboard passwords are encrypted with Ansible Vault and only decrypted at deploy time with a password that's never committed to the repository — including in the automated CI pipeline, where it's injected from a secrets store and destroyed the moment the job ends.

**Every change is verified automatically before it can reach the main branch.** A GitHub Actions pipeline rebuilds the entire environment from scratch on every pull request, runs the full deployment, and checks that traffic is actually load-balanced across both web servers before anything can be merged. This is the same discipline I'd bring to a client's infrastructure: nothing ships without a machine confirming it works, not just a person assuming it does.

## A Real Obstacle, and How I Solved It

Midway through building the database tier, I ran into a failure that's worth describing because it's the kind of thing that separates "it works on my machine" from production-ready work: a Docker-container database and the host machine's own database were both listening on the same network port. Every connection attempt from the application silently went to the *wrong* database — no error, no crash, just quiet failure. It took real debugging (checking what was actually listening on the port, not just assuming the container was the one answering) to track down. The fix was simple once found. The lesson wasn't: *check for port conflicts before you trust a new service is the one responding* — a habit I've carried into everything built after it.

This is representative of most of the real bugs hit during the build: a service-restart race condition in the database tier, a Windows-origin file with hidden line-ending characters that broke a startup script with a misleading error, a permissions gap between a task running as root and a service that needed to read the file it created. None of these are exotic — they're the ordinary friction of real systems — and each one is documented with its root cause and fix, not just patched and forgotten.

## Proof It Works, Not Just a Claim

The best way to show infrastructure is resilient is to break it on purpose and record what happens. So I did: with the full system running normally, I stopped the web server on one of the two web hosts mid-traffic — simulating exactly the kind of failure that happens in production, at the worst possible time.

- **Before:** requests alternate evenly between both web servers.
- **During the failure:** the load balancer detects the failed host and routes every request to the healthy one automatically — zero dropped requests, zero manual intervention.
- **A genuine limitation, found and documented rather than hidden:** the monitoring dashboard's host-level metrics stayed "healthy" the entire time, because they measure the server, not the specific web service running on it. That's a real gap in what this monitoring setup can see — and I wrote it up as exactly that, along with the specific fix (a service-level monitoring check) needed to close it.
- **After recovery:** traffic resumes across both servers automatically, no configuration changes needed.


## The Outcome

A self-healing, monitored, security-hardened, multi-tier deployment that can be rebuilt from nothing in one command, verified automatically on every change, with its own recorded incident response demo. Every architectural decision, every bug, and every deliberately deferred item is documented in plain language — the same standard of documentation I'd hold a client engagement to.

**What this demonstrates for a client engagement:**
- Infrastructure-as-code deployment (Ansible) that's repeatable, not one-off manual setup
- Security hardening applied as a default, not an afterthought
- Automated testing/verification (CI) before changes reach production
- Monitoring and alerting that surfaces real problems, with honest documentation of what it doesn't yet catch
- Clear, non-technical communication of technical decisions and trade-offs
