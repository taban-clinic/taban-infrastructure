# Deploy clinic-next: Dockerized stack (Traefik + Directus + Next.js), built off-box

Status: proposed — supersedes the Docker-avoidance premise of
`2026-08-24-lab-subdomain-deploy.md` and Discussion #7's Option A′, given the verified
network-condition reversal below. Narrows the parent RFC (#1) and directly follows on
from #6. Not yet actioned — no server change, no DNS change, no deploy has happened
from this doc.

## What changed since 2026-08-24 (verified live, 2026-08-28)

- **Direct inbound SSH to `94.101.177.69` now works** — no `185.206.93.107` jump host
  required, even though that jump host was genuinely necessary before (the VM's own
  `Last login ... from 185.206.93.107` history confirms it was actually used, not just
  documented as a precaution).
- **The documented full outbound egress block is no longer observed.** Live-tested from
  the VM this session: `registry.npmjs.org`, `github.com`, `ghcr.io`, Let's Encrypt's
  ACME API, `get.docker.com`, `download.docker.com`, and `registry-1.docker.io` are all
  reachable with fast (<1s) responses. Only a bare HTTPS GET to `1.1.1.1` timed out —
  a single unusual target, not evidence of a general block (everything else resolved
  and connected fine).
- **Caveat — not a permanent guarantee.** Iranian national filtering is known to
  fluctuate (time-of-day, political conditions) rather than being a fixed on/off
  switch. This is one clean test window. Tracked for re-verification over the following
  days in #5 before the no-internet-access deploy pattern (`DEPLOY.md`,
  `2026-08-24-lab-subdomain-deploy.md`) gets fully retired as a fallback design.
- **The managed Postgres (`bamdad-postgresql-10`) is reachable from outside Iran
  directly**, not just from the VM — worth flagging as a standing security note (no
  source-IP allowlist observed on the instance), independent of this deploy decision.

## Why this changes the recommendation

The entire architecture in `2026-08-24-lab-subdomain-deploy.md` — build locally, ship a
hand-assembled `node_modules` tarball over scp, no ACME, TLS terminated only at
Arvan's CDN edge — exists specifically to work around an egress block that no longer
appears to hold. With outbound internet, Docker Hub, `ghcr.io`, and Let's Encrypt all
reachable, a standard Docker Compose + Traefik deployment becomes possible, and is
simpler to operate and reason about than hand-built systemd units shipping raw
dependency trees.

## Recommended architecture

### Runtime, on the target box

- `docker compose` stack: `traefik` (reverse proxy + TLS), `directus`, `clinic-next`.
- **Postgres is not containerized.** Use the already-provisioned managed instance
  (`bamdad-postgresql-10`) — already isolated on its own instance, already reachable,
  already working. No reason to add a second stateful Postgres.
- **Traefik v3** (latest release at time of writing: `3.7.12`), Docker provider
  (label-based routing — a new service just needs labels, no manual config reload on
  deploy), Let's Encrypt ACME resolver now that Let's Encrypt is reachable. This
  replaces the CDN-only-TLS design for this stack. Consequence: the new subdomain's DNS
  record needs to point directly at the VM's IP rather than staying proxied through
  Arvan's CDN edge the way the root `dr-yousefi.ir` record does today — open question
  below on whether Arvan's DNS panel supports a per-record "DNS only" toggle.
- **Directus pinned at `v11`**, deliberately not `latest`. Docker Hub's `latest` tag
  moved to `v12` on 2026-08-25 — a major version bump not yet evaluated against the
  schema the booking/CMS code was actually built against. Treat the v12 upgrade as its
  own future decision, not something to inherit silently.
- **`clinic-next`**: Next.js is already close to current (`16.3.0` in `package.json` vs
  `16.3.3` latest on npm — trivial patch bump). Needs a `Dockerfile` and
  `output: "standalone"` added to `next.config.ts` — neither exists in the repo yet
  (unlike `dr-yousefi-site`, which already has the standalone-build pattern proven).

### Build, deliberately not on the box

- GitHub Actions builds both images — Directus needs no build (official image, just
  pinned); `clinic-next` needs a multi-stage `Dockerfile` — and pushes to `ghcr.io`.
  Confirmed reachable from the target box live (`HTTP 401` in 0.44s — auth-gated, not
  network-blocked).
- The box's deploy step becomes `docker compose pull && docker compose up -d`. No
  `pnpm install`, no `docker build`, no build toolchain resident on the box at any
  point. This is the main lever against the box's tight RAM budget, and it's a good
  idea independent of which box ends up running the stack — a `docker build` for
  Next.js can spike well past what running the finished image needs.

### Sizing — open decision

- The current live box (`dr-yousefi`, `94.101.177.69`): 1 vCPU, 2.8GB RAM, ~650MB free
  today running only the existing bare-metal `dr-yousefi-site`. Even with builds moved
  off-box, Traefik + Directus + `clinic-next` as running containers still need real
  headroom (realistically a few hundred MB apiece) — likely too tight as-is, and any
  contention risks the live site sharing the same kernel.
- **Preferred next step**: check whether ArvanCloud supports a vertical flavor resize
  on the existing VM in place — one box, right-sized, one Traefik fronting both the
  live site and the new stack — before provisioning a second server.
- **Fallback**: a new, dedicated server. The `taban-infrastructure` Terraform was meant
  to provision this, but `terraform/server.tf`'s actual `arvancloud_iaas_server`
  resource is currently **fully commented out**, with documented blockers: the
  image-lookup data source (`arvancloud_iaas_images`) always returns zero results
  (tenant-private images only, never the public catalog), and the SSH-key data source
  hits an unresolved IAM permission denial on the account's machine-user role. Not a
  quick `terraform apply` as it stands today.

## Open questions

1. Does Arvan support resizing `dr-yousefi`'s flavor in place, and does that require
   downtime for the live site during the resize?
2. Does Arvan's DNS panel expose a per-record "DNS only" (non-proxied) toggle — needed
   for Traefik's own ACME HTTP-01/TLS-ALPN challenge to reach the origin directly,
   rather than Arvan's CDN edge answering on the origin's behalf?
3. Is the egress-open finding stable over multiple days, or does it fluctuate with
   time-of-day / conditions? Tracked in #5.
4. Real RAM measurement once the stack is actually running, on whichever box it lands
   on — this doc's sizing section is reasoning from known baselines, not a live
   measurement of the new stack's actual footprint.
5. Directus `v11` → `v12`: worth a deliberate look at the migration notes before ever
   moving off the pin above, given `v12` is now what a bare `latest` would pull.

## Relation to prior work

Narrows/supersedes the Docker-avoidance premise in #6 and Discussion #7's Option A′,
given the verified network-condition reversal logged on #5. Does not resolve #1's
shared-vs-per-site-Directus question, and does not change anything about the live
`dr-yousefi-site` deployment itself — that stays exactly as documented in
`dr-yousefi-site/DEPLOY.md` unless a future doc says otherwise.
