# Shared box-level services

Docker Compose configs for services that run on the shared VM (`94.101.177.69`)
but aren't owned by any single site repo — captured here per
[#14](https://github.com/taban-clinic/taban-infrastructure/issues/14) after these
files were found to exist only as live, hand-edited state on the server with no
git home anywhere.

| Dir | Live path on server | Serves |
|---|---|---|
| `umami/` | `~/umami-infra/` | Analytics for all three sites |
| `supabase/` | `~/supabase-infra/` (override only — base compose + `.env` come from the standard [supabase/supabase](https://github.com/supabase/supabase) self-host `docker/` setup and are not duplicated here) | In-progress work, see #14 |
| `lab-directus/` | `~/clinic-next/lab/` | Directus CMS backing `clinic-next` + `implant-rescue-institute` (moved out of `clinic-next` since it's genuinely shared, not clinic-next-specific) |

## Secrets

**No real credentials are committed here.** Every `docker-compose.yml`/`.env.example`
pair uses `${VAR}` substitution; the real `.env` file stays only on the server
(git-ignored via the root `.env*` rule) until the `sops`+`age` migration proposed in
[#14](https://github.com/taban-clinic/taban-infrastructure/issues/14) lands.

`services/umami/docker-compose.yml` originally had a plaintext DB password and
`APP_SECRET` in the live file on the server — parameterized here before committing,
since this repo is public.

## Status vs. the live server

This directory was populated from the live server state as of 2026-09-13, plus one
fix not yet applied live: `services/lab-directus/docker-compose.yml` now sets
`mem_limit: 512m` on both `postgres` and `directus` (the one gap flagged in #14 —
`umami`/`umami-db`/Supabase already had limits set live). **This still needs to be
synced to the server** — either by the session actively working there, or as a
follow-up PR-and-deploy step. Until then, the live file and this repo differ by
exactly that one addition.
