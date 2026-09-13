# deploy/: release-based deploys for the Next.js sites

Server-side half of the CI/CD model agreed in [#14](https://github.com/taban-clinic/taban-infrastructure/issues/14)
(decisions D1–D8): **GitHub builds, m4 ships, the shared VM only runs.** No builds,
no `pnpm install`, no `rsync --delete` into a live app directory, ever again.

```
v* tag (scripts/promote) ──► GitHub Actions (ubuntu x64, Node 22.14.0) ──► <app>-<tag>-<sha7>.tgz + .sha256
        ──► m4 self-hosted runner ──► rsync over Tailscale into ~/apps/incoming/   (deploy-gate → rrsync, write-only)
        ──► ssh "deploy <app> <file>"                                               (deploy-gate → deploy-release)
        ──► unpack to releases/<id> → switch current → systemctl restart → health checks → auto-rollback on failure
```

| App | Unit | Port | Shared env file | Health paths |
|---|---|---|---|---|
| `dr-yousefi-site` | `dr-yousefi-site` | 7332 | `.env` | `/` |
| `clinic-next` | `clinic-next` | 7333 | `.env.production.local` | `/`, `/booking` |
| `implant-rescue-institute` | `implant-rescue-institute` | 7334 | `.env.production.local` | `/` |

Per-app settings live in `apps/<app>.conf`, units in `systemd/<unit>.service`.

## Layout on the server

```
~/apps/incoming/                         uploaded artifacts (write-only for the deploy key)
~/apps/<app>/releases/<vX.Y.Z>-<sha7>/   unpacked artifact, never modified after install
~/apps/<app>/current -> releases/<id>    what the unit runs (WorkingDirectory)
~/apps/<app>/shared/<env file>           the ONLY copy of the app's secrets; linked into each release
~/apps/<app>/deployed.json               last result: current, previous, release metadata
~/apps/<app>/deploy.log                  append-only history
~/apps/<app>/unit-backup/                unit files replaced by migrate-app
```

Env files are never inside a release, so no deploy, rollback or cleanup can delete them.
dr-yousefi-site's SQLite database is at `/var/lib/dr-yousefi-site/` (`SQLITE_PATH`), also
outside the release tree.

## Artifact contract (build side, owned by the m4/CI workflows)

- **Trigger:** a `v*` tag pushed by `scripts/promote`.
- **Build:** `ubuntu` x64 runner, **Node 22.14.0** (matches `/opt/node/bin/node` on the VM;
  `better-sqlite3` in dr-yousefi-site is a native module built against that ABI).
  `output: "standalone"` in `next.config.ts`.
- **Name:** `<app>-<tag>-<sha7>.tgz` (e.g. `dr-yousefi-site-v1.0.0-fcf1d71.tgz`), plus
  `<name>.sha256` (`sha256sum` output; only the hash is read).
- **Contents at the tarball root, ready to run:** `server.js`, `.next/` (with `.next/static`
  copied in), `public/`, the traced `node_modules/`, `package.json`, and a `RELEASE` file
  of `key=value` lines (`tag=`, `sha=`, `built_at=`, `node=`).
- **Never** an env file at the root: `deploy-release` refuses any `.env*` other than
  `.env.example`. None of the three apps uses `NEXT_PUBLIC_*` variables, so no secrets are
  needed at build time.
- **Ship:** `rsync` the `.tgz` and `.sha256` to `ubuntu@dr-yousefi:` (the key lands in
  `~/apps/incoming/` whatever path is given), then `ssh ubuntu@dr-yousefi "deploy <app> <tgz file name>"`.
  Treat exit `1` (refused, or failed and rolled back) and `2` (app down) as a failed deploy.

## Scripts

| Script | What it does |
|---|---|
| `bin/deploy-release deploy <app> <tgz>` | verify name + checksum + contents → unpack → link env → switch `current` → restart → health checks → prune to `KEEP_RELEASES`; on failure switch back and restart |
| `bin/deploy-release rollback <app> [id]` | switch to the recorded previous release (or `id`), restart, health-check; running it twice flips back |
| `bin/deploy-release status <app>` / `health <app>` | current release, unit state, health, release list |
| `bin/deploy-gate` | SSH forced command for the deploy key: only rsync uploads into `incoming/`, `deploy`, `rollback`, `status` |
| `bin/migrate-app <app> ...` | one-time cutover from `~/<app>` + old unit to this layout; restores the old unit on failure |

Exit codes: `0` ok, `1` refused / failed-and-rolled-back, `2` failed and the app is down,
`3` another operation holds the per-app lock, `64` usage.

## One-time server setup

1. **Pinned read-only checkout** (public repo, no credentials on the box). Moved only by
   hand to a merged commit, never edited in place:
   ```bash
   git clone https://github.com/taban-clinic/taban-infrastructure.git ~/taban-infrastructure
   git -C ~/taban-infrastructure checkout --detach <merged sha>
   mkdir -p ~/apps/incoming
   ```
2. **Deploy key.** The m4 runner generates a dedicated ed25519 key; add ONE line to
   `~/.ssh/authorized_keys`:
   ```
   command="/home/ubuntu/taban-infrastructure/deploy/bin/deploy-gate",restrict ssh-ed25519 AAAA... taban-deploy-runner
   ```
   `restrict` disables forwarding, PTY and agent. The gate logs every request to the journal
   (`journalctl -t deploy-gate`).

## Migrating an app (once per app, in a window the user has agreed)

Order: **dr-yousefi-site first** (already standalone), then clinic-next and
implant-rescue-institute once their first standalone artifact exists.

```bash
cd ~/taban-infrastructure/deploy
bin/migrate-app dr-yousefi-site --seed-from-live --dry-run   # prints the plan, changes nothing
bin/migrate-app dr-yousefi-site --seed-from-live             # ~5 s restart
bin/deploy-release status dr-yousefi-site
```

- `--seed-from-live` copies the running standalone build into `releases/legacy-<timestamp>`,
  so the very first CI deploy already has a rollback target.
- `--from-tarball <tgz>` uses a CI artifact instead (used for clinic-next and implant-rescue-institute).
- Env files are **copied** to `shared/` (mode 600); `~/<app>` is never modified. Delete it by
  hand only after at least a week of normal deploys, **and only once nothing else lives in it**.
  `migrate-app` warns if a Docker Compose project still runs from inside the old directory.
- ⚠️ **`~/clinic-next`**: `~/clinic-next/lab` was the live working directory of the `lab` Compose
  project (Directus + the clinic Postgres). It moves to `~/services/lab-directus` (see
  `services/README.md`, "Relocating lab-directus"); after that, `~/clinic-next/lab/.env` is only a
  symlink for clinic-next's provisioning scripts. Before deleting `~/clinic-next`, confirm no
  container's `com.docker.compose.project.working_dir` label points inside it.
- On failure the old unit file is restored and restarted automatically, and `current` is
  removed so the migration can be retried.
- Unit changes vs. the old units: `WorkingDirectory` is `~/apps/<app>/current`, the app
  binds `127.0.0.1` only (Caddy proxies to localhost), `MemoryHigh`/`MemoryMax` are set,
  and clinic-next/implant-rescue-institute use `Wants=docker.service` instead of
  `Requires=` (a Docker restart no longer stops the sites).

## Memory limits are guards, not a budget

The per-process limits on this box add up to more than it has. Checked 2026-09-13:

| Where | Limit |
|---|---|
| Site units (`MemoryMax`) | 300M + 400M + 400M = 1.1G |
| Containers (`mem_limit`) | lab-directus 512M, lab-postgres 512M, supabase-db 512M, umami 512M, umami-db 512M, supabase-auth 128M, supabase-rest 128M = 2.8G |
| No limit | supabase-envoy, supabase-meta, supabase-studio |
| **Box** | **2.8G RAM + 3.0G swap** |

So the ~3.9G of limits only stops a single runaway process. It does not stop everything
from peaking at once. The box stays up because typical usage is far lower, with swap and
`earlyoom` as the backstop. Before adding a service here, or raising a limit, check what is
actually in use (`free -h`, `docker stats --no-stream`, `systemd-cgtop`), not the limits.

## Manual operations

```bash
~/taban-infrastructure/deploy/bin/deploy-release status   clinic-next
~/taban-infrastructure/deploy/bin/deploy-release rollback clinic-next             # to previous
~/taban-infrastructure/deploy/bin/deploy-release rollback clinic-next v1.2.0-abc1234
```

## Tests

```bash
deploy/tests/run.sh
```

Runs the real scripts end to end against a temp directory with a stub `systemctl` and a
tiny local HTTP app whose health follows whichever release is running. Covers migration
(dry run, seed, refusal to re-run, failure → old unit restored), good and unhealthy
deploys with auto-rollback, refused artifacts (root env file, bad checksum, bad name,
duplicate release, missing shared env), manual rollback both ways, locking, pruning, and
the gate's allow/deny rules. Lint with `shellcheck deploy/bin/* deploy/lib/*.sh deploy/tests/run.sh`.
