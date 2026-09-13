# Shared box-level services

Docker Compose configs for services that run on the shared VM (see `ansible/inventory.ini`
for the host) but aren't owned by any single site repo — captured here per
[#14](https://github.com/taban-clinic/taban-infrastructure/issues/14) after these
files were found to exist only as live, hand-edited state on the server with no
git home anywhere.

| Dir | Live path on server | Docker Compose project name | Serves |
|---|---|---|---|
| `umami/` | `~/umami-infra/` | `umami-infra` | Analytics for all three sites |
| `supabase/` | `~/supabase-infra/` (override only — base compose + `.env` come from the standard [supabase/supabase](https://github.com/supabase/supabase) self-host `docker/` setup and are not duplicated here) | `supabase` (pinned in the upstream base file) | In-progress work, see #14 |
| `lab-directus/` | `~/services/lab-directus/` (moved from `~/clinic-next/lab/`, see "Relocating lab-directus" below) | `lab` | Directus CMS + the clinic Postgres, backing `clinic-next` + `implant-rescue-institute` |

**Do not run `docker compose up` directly from `services/umami/` or `services/lab-directus/`
without `--project-directory` pointing at the real live directory.** Compose derives its
project name (and therefore its volume names) from the directory unless a top-level `name:`
is set — both files pin `name:` to match the live project (`umami-infra`, `lab`), but a
stray `docker compose up` from inside `services/<x>/` on a laptop with no `--project-directory`
override will still create fresh local volumes, not touch production. On the server, use
`services/bin/apply-service` (below), which always passes the live project name and directory
(`~/umami-infra`, `~/services/lab-directus`).

## Published ports

Docker-published ports **bypass UFW** on this host (Docker's iptables rules accept the
traffic before UFW's allow-list is consulted). Every `ports:` entry here must bind to
`127.0.0.1` unless the port is deliberately public — Caddy and the site apps reach these
services over localhost. Verify from outside the box, never assume UFW covers it.

## Secrets

**No real credentials are committed here.** Every `docker-compose.yml`/`.env.example`
pair uses `${VAR}` substitution; the real `.env` file stays only on the server
(git-ignored via the root `.env*` rule) until the `sops`+`age` migration proposed in
[#14](https://github.com/taban-clinic/taban-infrastructure/issues/14) lands.

`services/umami/docker-compose.yml` originally had a plaintext DB password and
`APP_SECRET` in the live file on the server — parameterized here before committing,
since this repo is public. Verified: the template + a real `.env` next to it resolves
to a config identical to the live one in every field besides those secrets.

## Status vs. the live server (as of 2026-09-13, verified by the session working on the box)

- `services/supabase/docker-compose.override.yml` and `services/lab-directus/docker-compose.yml`
  matched the live files after the `mem_limit: 512m` and `127.0.0.1` port changes were applied.
- `services/umami/docker-compose.yml` differs from the live file only in the 3 secret
  values, which is expected and correct (see Secrets above).
- **Directus uploads now have a named volume** (`uploads:/directus/uploads`, i.e. `lab_uploads`).
  Before this, Directus's default local storage lived inside the container and every recreate
  would have destroyed uploaded files. `directus_files` had 0 rows when this was found, so
  nothing had been lost.
- **Attribution correction**: the `mem_limit` settings on `umami`/`umami-db`/Supabase's
  `db`/`auth`/`rest` predate the 2026-09-12 outage response — they were not added as part of
  it. The actual fix was the 3 GB swapfile, `earlyoom`, the healthcheck interval
  relaxation (5s→30s steady state), and `init: true` on Supabase's `studio`/`meta`.

## Known gaps

- The Supabase base compose (not in this repo) pins specific upstream image tags as of
  2026-09-13: `studio:2026.08.03-sha-022b374`, `gotrue:v2.189.0`, `postgres-meta:v0.96.6`.
  Record the exact upstream `supabase/supabase` commit/tag these came from somewhere
  durable — a rebuild from a fresh upstream checkout would silently pick up newer
  versions otherwise.
- `~/supabase-infra/bin/backup-to-bamdad` (the nightly backup script) has no git home
  either — worth its own follow-up.
- Runtime state that must never be touched by a repo-driven sync (no `rsync --delete`,
  no copying into these paths): `~/supabase-infra/volumes/db/data` (bind-mounted Postgres
  data), and every service's real `.env`. `bin/apply-service` never copies anything into
  the live directories (see below).

## Applying changes to the live server

Decided in #14: a **pinned, read-only checkout** of this repo on the VM plus
`services/bin/apply-service`, run by hand. Nothing is copied into the live directories:
Compose reads the files straight from the checkout, with the live project name and
directory, so `.env` files, bind mounts and named volumes stay exactly where they are.

```bash
git -C ~/taban-infrastructure fetch origin
git -C ~/taban-infrastructure checkout --detach <merged sha>
~/taban-infrastructure/services/bin/apply-service umami --dry-run   # shows which services would be recreated
~/taban-infrastructure/services/bin/apply-service umami
```

- `services/<name>/apply.conf` sets the live project name and directory, the compose files,
  the **explicit list of services to manage**, required live files (e.g. `.env`) and HTTP
  checks. Supabase's upstream file also defines realtime, storage, imgproxy, functions and
  supavisor; they aren't deployed here, aren't listed, and are never started by an apply.
- Only listed services whose Compose config hash differs from the running container are
  recreated (`up -d --no-deps --wait`), then the HTTP checks run.
- `--recreate` recreates **every** listed service even when nothing differs
  (`--force-recreate`). Use it after a live directory moves: the project directory isn't part
  of the config hash, so without it the containers' labels keep pointing at the old directory.
- Exit codes: `0` applied or nothing to do, `1` refused (dirty checkout, missing live file,
  invalid compose), `2` applied but unhealthy (prints the revert command), `3` locked.
- State: `~/apps/services/<name>.json` (last good sha) and `~/apps/services/apply.log`.

### Relocating lab-directus (one-time)

`lab-directus` used to run from `~/clinic-next/lab/`, inside an app directory that the release
layout will eventually delete. Its only live state there is `.env`; both volumes (`lab_pgdata`,
`lab_uploads`) are named, so they are unaffected by the move.

```bash
mkdir -p ~/services/lab-directus
mv ~/clinic-next/lab/.env ~/services/lab-directus/.env        # keeps mode 600
ln -s ~/services/lab-directus/.env ~/clinic-next/lab/.env     # clinic-next's lab/ scripts use --env-file=.env
git -C ~/taban-infrastructure fetch origin
git -C ~/taban-infrastructure checkout --detach <merged sha>
~/taban-infrastructure/services/bin/apply-service lab-directus --dry-run --recreate
~/taban-infrastructure/services/bin/apply-service lab-directus --recreate   # ~15–20 s: Postgres, then Directus
```

Afterwards: both containers' `com.docker.compose.project.working_dir` label is
`~/services/lab-directus`, Directus has the `lab_uploads` mount, `/booking` and
`cms.dr-yousefi.ir/server/health` return 200, and `services/bin/drift-check` is OK.

### Drift check

`services/bin/drift-check` compares every managed service's running config hash with
the checkout and flags local edits to the checkout. Exit `0` in sync, `1` drift, `2` a
check could not run. DRIFT lines go to `journalctl -t drift-check`; set `ALERT_CMD` to
pipe the report to a notifier (no alert channel chosen yet). It runs nightly at 04:15 UTC
via `services/systemd/taban-drift-check.{service,timer}` (install commands are in the unit file).

### Tests

`services/tests/run.sh` runs both scripts end to end from a throwaway git checkout with a
stub `docker`; no containers are touched.
