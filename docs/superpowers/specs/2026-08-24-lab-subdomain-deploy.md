# Proposal: deploy `clinic-next`'s `lab` stack as a subdomain of `dr-yousefi.ir`

Status: proposed — narrows the open RFC (`taban-infrastructure` issue #1, decision
`d-001`) into a concrete pilot deployment. Not yet actioned; no `terraform apply`,
DNS change, or server mutation has been made from this doc.

**Update (same day, after initial draft):** a managed Postgres instance already
exists on the account and is confirmed reachable from the VM — see "Update: managed
Postgres already exists" below. This changes the recommendation from Option B to
Option A′.

## Goal

Stand up a pilot/staging deploy of the `clinic-next` app (Next.js 16 + Directus 11 +
Postgres — currently only running in local Docker Compose, see
`clinic-next/lab/docker-compose.yml`) as a subdomain — e.g. `lab.dr-yousefi.ir` —
reusing the existing ArvanCloud server that already hosts the live `dr-yousefi.ir`
site, before committing to the full three-site production cutover scoped in issue #1.

## The one fact that shapes every option below

Confirmed independently twice now — once via live SSH testing this session, once
already documented in `dr-yousefi-site/DEPLOY.md` from the original site's
deployment (2026-08-21/22):

**The server (`94.101.177.69`, "arvan_dr_yousefi") has a full outbound egress block
to any foreign IP.** Not just DNS — GitHub, the npm registry, Let's Encrypt, and
apt's own nodesource/cloudsmith repos are all unreachable, even by raw IP (tested
`curl` to `1.1.1.1` directly, no DNS involved — still times out). Only
ArvanCloud-domestic destinations resolve and connect: `mirror.arvancloud.ir` (their
apt mirror) responds in under 0.1s.

Per `arvancloud-eco/docs/upstream/pages/cloud-server__firewall.txt`, Cloud Server's
own security-group model **defaults to allowing all outbound traffic** — so this is
**not** an Arvan-configurable firewall setting we can just open up. It's upstream
filtering (ISP/national) outside Arvan's control surface. Every option below has to
design around it, not try to fix it.

## What's already proven on this exact box: the `dr-yousefi.ir` precedent

Live discovery via SSH (this session) plus `dr-yousefi-site/DEPLOY.md` together give
a complete, already-working pattern for exactly this class of problem:

- **Runtime**: Ubuntu 24.04.1, 1 vCPU, 2.8 GB RAM, no swap, 25 GB disk free. Node.js
  v22.14.0 hand-installed at `/opt/node` (apt's candidate is only 18.19.1 — too old
  for Next 16, and nodesource is unreachable). No Docker, no `pnpm`, no `psql`
  installed on the box today.
- **Deploy shape**: `next.config.ts` sets `output: "standalone"`. The app is built
  **locally** inside a `--platform linux/amd64` Docker container (native deps like
  `better-sqlite3`/`lightningcss` must match the Linux target, not macOS), assembled
  into a self-contained tarball (`server.js` + only-needed `node_modules` +
  `.next/static` + `public/`), and shipped via `scp` through the existing SOCKS
  tunnel (`nc -X 5 -x 127.0.0.1:1080`). `pnpm install` never runs on the server —
  it can't, there's no registry access.
- **Process management**: plain systemd unit (`dr-yousefi-site.service`) running
  `/opt/node/bin/node server.js`, `Restart=on-failure`. No container runtime
  involved anywhere.
- **Reverse proxy / TLS**: Caddy (`/usr/local/bin/caddy`, static binary — installed
  the same way, since cloudsmith's apt repo for Caddy is also unreachable) serves
  **plain `http://dr-yousefi.ir { reverse_proxy localhost:7332 }`** — no ACME, no
  cert on the origin at all, because the origin can't reach Let's Encrypt either.
  **TLS lives entirely at ArvanCloud's CDN edge**: the domain's DNS is on Arvan's
  CDN nameservers with the `@` A-record in "cloud mode," the edge holds Arvan's own
  managed certificate, and the DNS record's `upstream_https` field is set to
  `"http"` so the edge talks plain HTTP to the origin — this is the mechanism that
  makes the whole thing work without the origin ever touching the public internet.
- **Current box state confirmed live**: UFW allows `22/80/443`, but only port `80`
  is actually listening (Caddy) — `443` is open at the firewall but unused, matching
  the CDN-terminates-TLS design. `postgresql` (16) and `nodejs` are available as apt
  candidates (via the in-network mirror), just not installed yet. Free/available RAM
  right now: ~2.3 GB of 2.8 GB total, with the live site already running.

## What `arvancloud-eco` adds

- **Container registry reachability from the VM is undocumented, not confirmed
  either way.** Arvan's container registry lives at a different domain
  (`registry.apps.ir-central1.arvancaas.ir`, per
  `docs/upstream/pages/cloud-container__container-registry.txt`) than the apt
  mirror (`mirror.arvancloud.ir`) — the apt-mirror precedent does **not**
  automatically extend to it. This must be live-tested before any plan depends on
  it, not assumed.
- **Cloud Container (Arvan's PaaS/Kubernetes product) is a genuinely separate,
  viable option** — deploy by Docker image, raw manifest, kubectl, or one of 60+
  Helm charts (`docs/upstream/pages/cloud-container__create-app.txt`). Image-based
  deploys let you pick a free Arvan-generated subdomain (HTTP-only) or a personal
  domain, but a personal domain **must already be registered in Arvan's own
  CDN/DNS on the same account** — `dr-yousefi.ir` already is, so that precondition
  is met (`docs/upstream/pages/cloud-container__create-app__container-image.txt`).
  Only two datacenters run this layer today (Bamdad/Shahriar, per
  `docs/reference/provisioning-guide.md` §3.4). Being a separate managed platform,
  it very likely has normal outbound internet (unlike the VM) — but this is an
  inference, not something the docs state outright, and should be verified.
- **DNS mechanics for the subdomain itself are simple and already proven on this
  domain**: A/CNAME/etc. records go through the panel or
  `POST https://napi.arvancloud.ir/cdn/4.0/domains/{domain}/dns-records` with an
  `Authorization: Apikey ...` header (`docs/upstream/pages/cdn__dns-records__adding-records.txt`
  — note the `Apikey` capitalization, which `dr-yousefi-site/DEPLOY.md` flags as a
  real gotcha against the docs' own example). Adding `lab.dr-yousefi.ir` is just a
  new A record titled `lab` pointing at `94.101.177.69`, in the same cloud-mode /
  `upstream_https: "http"` configuration already working for the root domain.
- **Known unrelated gotchas that don't block this plan but are worth knowing**:
  the pinned Terraform provider version (`~> 0.4.0`) trails the current `0.6.0`,
  and SSH keys aren't Terraform-manageable on this account (IAM permission denial,
  unresolved) — neither blocks a manual/Ansible-driven deploy like the one
  proposed here, but they will matter if this pilot later gets codified into
  Terraform.
- Private networking (`cloud-server__network__private.txt`) only links sibling VMs
  in the same datacenter — not applicable to running two apps on one existing VM;
  that's just port separation behind Caddy, not a distinct Arvan feature.

## Update: managed Postgres already exists

The account already has an active ArvanCloud DBaaS instance — discovered via the
DBaaS API (`GET https://napi.arvancloud.ir/dbaas/v1/instances`, using the existing
`ARVAN_API_KEY` from `.envrc`, which turned out to have enough scope for this read):

- `name`: `bamdad-postgresql-10`, engine `postgresql` `17.9`, port `5432`
- Flavor `g2-2-1-0`: 1 vCPU / 2 GB RAM / 10 GB disk ("Standard" category)
- Datacenter: **Bamdad** (`az: "ba"`, `region: "ir-thr"`) — the same datacenter
  `arvancloud-eco`'s `provisioning-guide.md` names as one of only two running
  Arvan's Cloud Container/Kubernetes layer
- Status `ACTIVE`, created `2026-08-19` (5 days before this proposal — provisioned
  in an earlier session, not something to spin up)
- Public IP `94.101.186.8`; also has an Arvan-generated subdomain
  (`*.db.arvandbaas.ir`) that did **not** resolve from the VM (see below)
- Default user `base-user`, default database `default` — credentials are in the
  DBaaS API response / Arvan dashboard, not repeated here; treat as a live secret

**Live-tested from the VM** (raw TCP, `/dev/tcp` — no `psql` installed):

- `94.101.186.8:5432` → **reachable**
- `<instance>.db.arvandbaas.ir:5432` → **DNS resolution fails** (the domestic
  `arvandbaas.ir` zone doesn't resolve from this VM, unlike `mirror.arvancloud.ir`
  or `arvancloud.ir` itself) — the raw IP works regardless, so this is a non-issue
  as long as the app config uses the IP (or a `/etc/hosts` pin) rather than the
  hostname

This resolves Open Question #3 below in the best possible direction: **Postgres
does not need to be provisioned as part of this pilot, doesn't need to run on the
filtered VM at all, and is already confirmed reachable from it.** It also removes
the main reason Option B routed Directus + Postgres to Cloud Container together —
the database half of that rationale is now moot, since an already-isolated,
already-reachable Postgres exists independent of any Cloud Container decision.

## Options

### Option A — Everything on the existing VM, including a local Postgres

(Superseded by Option A′ below, now that a managed Postgres already exists and is
reachable — kept here for the record.) Replicate the proven recipe for the Next.js
frontend, and additionally `apt install postgresql` locally on the VM for Directus's
database, plus ship Directus's full `node_modules` as a tarball the same way.

- **Cons that no longer apply given the discovery above**: no need to provision or
  maintain a local Postgres on the filtered VM at all.

### Option A′ — Next.js + Directus on the existing VM, pointed at the already-existing managed Postgres (recommended)

Replicate the proven `dr-yousefi.ir` recipe for `clinic-next`'s Next.js frontend
(standalone build, shipped tarball, new systemd unit on a new port e.g. `7333`, new
`lab.dr-yousefi.ir` Caddy block, new DNS A record — all a direct copy of what
already works). For Directus: build its full `node_modules` locally in the same
`linux/amd64` container already used for the Next.js build (Directus has no
official "standalone output" mode like Next.js, so this means shipping its entire
dependency tree rather than a trimmed one — heavier, and a genuinely new pattern
here, but the same *mechanism* already proven for Node/npm-registry-blocked
deploys), ship it via scp, run it under its own systemd unit, and point it at the
already-active `bamdad-postgresql-10` instance by IP (`94.101.186.8:5432`) — no
local Postgres install needed at all.

- **Pros**: reuses the proven build-locally/ship-a-tarball/systemd/Caddy pattern
  for both pieces; the database is already provisioned, already isolated on its
  own instance (so a VM-level incident can't corrupt or take down the DB), and
  already confirmed reachable; zero new ArvanCloud products to provision; DNS/TLS
  is a five-minute copy of the existing root-domain config.
- **Cons**: the VM still runs the live `dr-yousefi.ir` site alongside two new
  processes (Next.js frontend + Directus) — RAM headroom (~2.3 GB free of 2.8 GB
  total, no swap configured) is the real constraint now, not the database. A
  runaway Directus process could still starve the live site's Next.js process for
  memory since they share the same OS. Shipping Directus without Docker is
  untested (see Open Questions) even though the shipping *mechanism* is proven.

### Option B — Split: Next.js frontend on the existing VM, Directus on ArvanCloud Cloud Container

Keep `clinic-next`'s Next.js frontend on `94.101.177.69` using the exact
`dr-yousefi.ir` recipe. Move **Directus only** (Postgres is already solved per the
update above, regardless of which option is chosen) onto Arvan's Cloud Container
platform, deployed from Directus's official public Docker image
(`directus/directus:11` — the same image already used in local dev), pointed at
the existing `bamdad-postgresql-10` instance.

- **Pros**: isolates the live site's blast radius from the Directus pilot
  completely — a Directus crash or OOM can't touch `dr-yousefi.ir`'s process or
  memory at all, since it's not even the same VM. Directus deploys from its
  official image with no custom node_modules bundling, since Cloud Container is
  built for exactly that.
- **Cons**: introduces a second product to provision (cost, one more account
  surface to learn) and a network hop between the VM (frontend) and Cloud
  Container (Directus) that still needs verifying — is Cloud Container's endpoint
  reachable from the filtered VM the way the DB instance turned out to be, or does
  it look "foreign" to the VM's egress filter the same way GitHub does? Given the
  DB instance (also on a `*.arvandbaas.ir`-style domestic domain family) was
  reachable by IP, this is likely to work too, but **still unverified — test
  before committing** (see Open Questions).

### Option C — Move everything to Cloud Container, don't touch the VM

Deploy the whole `clinic-next` stack (frontend + Directus + Postgres) on Cloud
Container using a free Arvan-generated subdomain or a properly configured personal
one, leaving `94.101.177.69` untouched.

- **Pros**: cleanest separation from the filtered-VM problem for every component;
  no blast-radius risk to `dr-yousefi.ir` at all.
- **Cons**: doesn't literally reuse `dr-yousefi.ir`'s domain the way the ask
  ("as subdomain on dr-yousefi") implies — though a `lab.dr-yousefi.ir` CNAME
  pointed at the Cloud Container app's custom domain would still satisfy that
  externally, per the create-app docs. More setup than a pilot needs, and departs
  furthest from what's already running and proven.

## Recommendation

**Option A′.** With the database question already solved — Postgres exists,
is isolated on its own instance, and is confirmed reachable from the VM by IP —
the strongest remaining reason to reach for Cloud Container (Option B) is gone for
the DB half, and the Next.js half was always going to reuse the existing VM
pattern regardless of option. That leaves one real decision: whether Directus
itself runs on the VM (Option A′) or on Cloud Container (Option B). Recommend
starting with A′ because it needs zero new ArvanCloud products and reuses a
build-locally/ship-a-tarball mechanism that's already proven for exactly this
"no npm registry access" constraint — the only new work is that Directus's tarball
is heavier than Next.js's trimmed standalone output. **Fall back to Option B only
if A′'s RAM headroom (Open Question 2 below) or the no-Docker Directus packaging
(Open Question 3) turns out not to work in practice.**

This also derisks the full three-site production question in issue #1 either way:
this pilot becomes a live test of "Directus without Docker on the shared VM"
(if A′) or "Directus on Cloud Container" (if B) before deciding the shared-CMS
architecture for all three sites.

## Open questions — verify before committing

1. ~~Is Postgres available and reachable from the VM?~~ **Resolved above** — yes,
   `bamdad-postgresql-10` is active and reachable by IP.
2. **RAM headroom for Directus alongside the live `dr-yousefi.ir` process.** ~2.3 GB
   free of 2.8 GB total, no swap configured, before adding anything. Directus
   typically wants several hundred MB to 1 GB+ under light use. Worth adding a
   swap file as a cheap safety cushion regardless of which option is chosen, and
   worth a real memory measurement once Directus is running, before calling A′
   viable long-term.
3. **Can Directus actually be packaged and run without Docker**, the way Next.js's
   standalone output was? This is untested — Directus has no official equivalent
   to `output: "standalone"`, so the build-locally/ship-full-node_modules approach
   needs a real trial run before Option A′ can be called proven rather than just
   plausible.
4. **Is Arvan's container registry (`registry.apps.ir-central1.arvancaas.ir`)
   reachable from the VM?** If yes, that's a second path to Option A′ (install
   Docker via the working apt mirror, pull Directus's official image from Arvan's
   registry instead of Docker Hub, avoiding the no-Docker packaging problem in
   Open Question 3 entirely). Worth testing regardless of which option is chosen.
5. **Is Cloud Container's endpoint reachable from the VM's filtered egress?**
   Only matters if Option B is needed as a fallback. Given the DB instance (same
   domestic-domain family) was reachable by IP, likely yes — but unverified.
6. **Is `dr-yousefi.ir`'s NS already fully on Arvan's CDN/DNS** (confirmed by
   `DEPLOY.md`'s existing cloud-mode setup) — if so, adding the `lab` A record is
   trivial; this should be a five-minute confirmation, not an assumption.

## Rollback / blast-radius notes

- Whatever option is chosen, `dr-yousefi-site.service` and the existing Caddyfile
  block for the root domain should not be touched by this work — a new systemd
  unit and a new Caddy block, added alongside, keep the existing site's config
  file diff-reviewable and trivially revertable.
- `dr-yousefi-site/DEPLOY.md` already documents one real incident worth heeding
  here too: never `rm -rf` an app directory on the server without backing up its
  `.env` first — the same discipline applies to whatever `lab` deploy script gets
  written.

## Relation to issue #1 / decision `d-001`

This doc narrows, not replaces, the open RFC. It answers one of that issue's four
open questions concretely — the migration path from local dev lab to a real
deployment — for a pilot scope only. The remaining open questions in issue #1
(shared vs. per-site Directus, WordPress cutover plan, whether `185.206.93.107`
sizing applies here) are unaffected and still need resolving before the full
three-site production plan is finalized.
