# shellcheck shell=bash
# Shared helpers for deploy-release and migrate-app. Source it, don't execute it.
#
# Every path and command can be overridden from the environment, which is how
# deploy/tests/run.sh exercises the real scripts against a throwaway tree.

APPS_ROOT="${APPS_ROOT:-$HOME/apps}"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONF_DIR="${CONF_DIR:-$DEPLOY_DIR/apps}"
INCOMING_DIR="${INCOMING_DIR:-$APPS_ROOT/incoming}"
HEALTH_HOST="${HEALTH_HOST:-127.0.0.1}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"
read -r -a SYSTEMCTL_CMD <<<"${SYSTEMCTL:-sudo systemctl}"

now() { date -u +%FT%TZ; }
log() { printf '%s %s\n' "$(now)" "$*" >&2; }
die() { log "✗ $1"; exit "${2:-1}"; }

# remove_uploaded_artifact <tgz>: once a release is installed and live, its unpacked
# directory is the real copy, so the upload is dropped. Only files that sit directly in
# INCOMING_DIR are removed, never an artifact an operator passed from somewhere else.
remove_uploaded_artifact() {
  local dir incoming
  dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 0
  incoming="$(cd "$INCOMING_DIR" 2>/dev/null && pwd -P)" || return 0
  if [ "$dir" = "$incoming" ]; then
    rm -f -- "$1" "$1.sha256"
    log "removed uploaded $(basename "$1") from $INCOMING_DIR"
  fi
}

# load_app <app>: validates the name, sources deploy/apps/<app>.conf and sets
# app, app_dir, UNIT, PORT, ENV_FILES, HEALTH_PATHS, KEEP_RELEASES.
load_app() {
  app="${1:-}"
  [[ "$app" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid app name: '$app'"
  local conf="$CONF_DIR/$app.conf"
  [ -f "$conf" ] || die "unknown app '$app' (no $conf)"
  UNIT="" PORT="" KEEP_RELEASES=5
  ENV_FILES=() HEALTH_PATHS=()
  # shellcheck source=/dev/null
  . "$conf"
  if [ -z "$UNIT" ] || [ -z "$PORT" ] || [ "${#HEALTH_PATHS[@]}" -eq 0 ]; then
    die "$conf must set UNIT, PORT and HEALTH_PATHS"
  fi
  app_dir="$APPS_ROOT/$app"
}

# One deploy/rollback/migration per app at a time; fd 9 holds the lock until exit.
lock_app() {
  mkdir -p "$app_dir"
  exec 9>"$app_dir/.deploy.lock"
  flock -n 9 || die "another deploy/rollback/migration of $app is in progress" 3
}

restart_unit() {
  log "restarting $UNIT"
  "${SYSTEMCTL_CMD[@]}" restart "$UNIT" || log "warning: systemctl restart $UNIT returned an error"
}

healthy() {
  local path code
  for path in "${HEALTH_PATHS[@]}"; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$HEALTH_HOST:$PORT$path" || true)"
    [[ "$code" =~ ^[23][0-9]{2}$ ]] || return 1
  done
}

wait_healthy() {
  local waited=0
  until healthy; do
    if [ "$waited" -ge "$HEALTH_TIMEOUT" ]; then return 1; fi
    sleep "$HEALTH_INTERVAL"
    waited=$((waited + HEALTH_INTERVAL))
  done
}

current_release() {
  if [ -L "$app_dir/current" ]; then basename "$(readlink "$app_dir/current")"; fi
}

previous_release() {
  jq -r '.previous // empty' "$app_dir/deployed.json" 2>/dev/null || true
}

list_releases() {  # newest first
  find "$app_dir/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %f\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2-
}

# Atomic swap: a rename over the old symlink, never a moment without "current".
switch_to() {
  ln -sfn "releases/$1" "$app_dir/.current.tmp"
  mv -Tf "$app_dir/.current.tmp" "$app_dir/current"
}

# verify_tarball <tgz>: name, checksum and content checks. Sets release_id.
verify_tarball() {
  local tgz="$1" name expected actual listing
  name="$(basename "$tgz")"
  [ -f "$tgz" ] || die "no such artifact: $tgz"
  [[ "$name" =~ ^${app}-(v[0-9][0-9A-Za-z.+-]*-[0-9a-f]{7})\.tgz$ ]] \
    || die "artifact must be named $app-<vX.Y.Z>-<sha7>.tgz (got $name)"
  release_id="${BASH_REMATCH[1]}"

  [ -f "$tgz.sha256" ] || die "missing checksum file $name.sha256"
  expected="$(awk 'NR == 1 {print $1}' "$tgz.sha256")"
  actual="$(sha256sum "$tgz" | awk '{print $1}')"
  if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$expected" != "$actual" ]; then
    die "checksum mismatch for $name"
  fi

  listing="$(tar -tzf "$tgz")" || die "cannot read $name as a gzip tarball"
  if grep -qE '(^/|(^|/)\.\.(/|$))' <<<"$listing"; then
    die "$name contains absolute or '..' paths"
  fi
  if grep -E '^(\./)?\.env(\.[^/]*)?$' <<<"$listing" | grep -qvE '\.env\.example$'; then
    die "$name carries env files at its root; artifacts must never contain secrets"
  fi
  grep -qE '^(\./)?server\.js$' <<<"$listing" || die "$name has no server.js at its root"
  grep -qE '^(\./)?RELEASE$' <<<"$listing" || die "$name has no RELEASE file at its root"
}

require_shared_env() {
  local f
  for f in "${ENV_FILES[@]}"; do
    [ -f "$app_dir/shared/$f" ] || die "missing $app_dir/shared/$f; refusing to install a release that cannot start"
  done
}

link_env() {  # link_env <release dir>: relative links into ../../shared
  local f
  for f in "${ENV_FILES[@]}"; do ln -sfn "../../shared/$f" "$1/$f"; done
}

# install_release <tgz>: unpack into releases/<release_id> (never overwrites).
install_release() {
  local tgz="$1" tmp
  mkdir -p "$app_dir/releases" "$app_dir/shared"
  [ ! -e "$app_dir/releases/$release_id" ] \
    || die "release $release_id already exists (releases are immutable; use rollback to go back to it)"
  require_shared_env
  tmp="$app_dir/releases/.incoming-$release_id-$$"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if ! tar -xzf "$tgz" -C "$tmp" --no-same-owner; then
    rm -rf "$tmp"
    die "failed to unpack $(basename "$tgz")"
  fi
  link_env "$tmp"
  mv -T "$tmp" "$app_dir/releases/$release_id"
  touch "$app_dir/releases/$release_id"
}

history_line() {  # history_line <result> <current> <previous>
  mkdir -p "$app_dir"
  printf '%s %s result=%s current=%s previous=%s\n' \
    "$(now)" "$app" "$1" "${2:-none}" "${3:-none}" >>"$app_dir/deploy.log"
}

# record <result> <current> <previous>: history line + deployed.json
record() {
  local result="$1" cur="$2" prev="$3" meta=""
  history_line "$result" "$cur" "$prev"
  if [ -f "$app_dir/releases/$cur/RELEASE" ]; then meta="$(head -c 2000 "$app_dir/releases/$cur/RELEASE")"; fi
  jq -n --arg app "$app" --arg result "$result" --arg current "$cur" --arg previous "$prev" \
    --arg at "$(now)" --arg release "$meta" \
    '{app: $app, current: $current, previous: $previous, result: $result, at: $at, release: $release}' \
    >"$app_dir/.deployed.json.tmp"
  mv -f "$app_dir/.deployed.json.tmp" "$app_dir/deployed.json"
}

# prune <keep...>: keep the newest KEEP_RELEASES releases plus any named ones.
prune() {
  local n=0 r keep
  while IFS= read -r r; do
    n=$((n + 1))
    if [ "$n" -le "$KEEP_RELEASES" ]; then continue; fi
    for keep in "$@"; do
      if [ "$r" = "$keep" ]; then continue 2; fi
    done
    rm -rf "${app_dir:?}/releases/${r:?}"
    log "pruned old release $r"
  done < <(list_releases)
}
