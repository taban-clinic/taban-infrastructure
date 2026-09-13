# shellcheck shell=bash disable=SC2034  # STATE_DIR, REQUIRE_FILES etc. are read by the scripts that source this
# Shared helpers for apply-service and drift-check. Source it, don't execute it.
#
# Paths and commands can be overridden from the environment, which is how
# services/tests/run.sh exercises the real scripts with a stub docker.

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SERVICES_LIVE_ROOT="${SERVICES_LIVE_ROOT:-/home/ubuntu}"
STATE_DIR="${SERVICES_STATE_DIR:-$HOME/apps/services}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-90}"
HTTP_INTERVAL="${HTTP_INTERVAL:-3}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
read -r -a DOCKER_CMD <<<"${DOCKER:-docker}"

now() { date -u +%FT%TZ; }
log() { printf '%s %s\n' "$(now)" "$*" >&2; }
die() { log "✗ $1"; exit "${2:-1}"; }

# load_service <name>: sources services/<name>/apply.conf and sets svc, PROJECT,
# LIVE_DIR, COMPOSE_FILES, SERVICES, REQUIRE_FILES, HTTP_CHECKS.
load_service() {
  svc="${1:-}"
  [[ "$svc" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid service name: '$svc'"
  local conf="$REPO/services/$svc/apply.conf"
  [ -f "$conf" ] || die "unknown service '$svc' (no $conf)"
  PROJECT="" LIVE_DIR=""
  COMPOSE_FILES=() SERVICES=() REQUIRE_FILES=() HTTP_CHECKS=()
  # shellcheck source=/dev/null
  . "$conf"
  if [ -z "$PROJECT" ] || [ -z "$LIVE_DIR" ] || [ "${#COMPOSE_FILES[@]}" -eq 0 ] || [ "${#SERVICES[@]}" -eq 0 ]; then
    die "$conf must set PROJECT, LIVE_DIR, COMPOSE_FILES and SERVICES"
  fi
}

# docker compose pinned to the live project name and directory, so .env files,
# relative bind mounts and named volumes resolve exactly as they do today.
compose() {
  local args=(compose -p "$PROJECT" --project-directory "$LIVE_DIR") f
  for f in "${COMPOSE_FILES[@]}"; do args+=(-f "$f"); done
  "${DOCKER_CMD[@]}" "${args[@]}" "$@"
}

repo_dirty() { [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; }

# drifted_services: one "service reason" line per managed service that doesn't match
# the checkout. Reasons: not-defined-in-compose, missing, <container state>, config-differs.
# Compares Compose's own config hash, the same signal `docker compose up` uses to decide
# whether to recreate a container.
drifted_services() {
  local s h st
  declare -A want have state
  while read -r s h; do
    if [ -n "$s" ]; then want[$s]="$h"; fi
  done < <(compose config --hash '*')
  while read -r s h st; do
    if [ -n "$s" ]; then have[$s]="$h"; state[$s]="$st"; fi
  done < <("${DOCKER_CMD[@]}" ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.Label "com.docker.compose.service"}} {{.Label "com.docker.compose.config-hash"}} {{.State}}')
  for s in "${SERVICES[@]}"; do
    if [ -z "${want[$s]:-}" ]; then echo "$s not-defined-in-compose"
    elif [ -z "${have[$s]:-}" ]; then echo "$s missing"
    elif [ "${state[$s]}" != running ]; then echo "$s ${state[$s]}"
    elif [ "${have[$s]}" != "${want[$s]}" ]; then echo "$s config-differs"
    fi
  done
}

# HTTP checks pass when every URL answers with 2xx–4xx (a 401 from an API gateway
# still proves it is up); 5xx or no answer fails.
http_checks_pass() {
  local url code
  for url in "${HTTP_CHECKS[@]}"; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$url" || true)"
    if ! [[ "$code" =~ ^[234][0-9]{2}$ ]]; then
      log "check failed: $url -> $code"
      return 1
    fi
  done
}

wait_http() {
  local waited=0
  until http_checks_pass 2>/dev/null; do
    if [ "$waited" -ge "$HTTP_TIMEOUT" ]; then http_checks_pass; return 1; fi
    sleep "$HTTP_INTERVAL"
    waited=$((waited + HTTP_INTERVAL))
  done
}
