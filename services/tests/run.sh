#!/usr/bin/env bash
# End-to-end tests for apply-service and drift-check. They run the real scripts from a
# throwaway git checkout against a stub docker (no containers are touched) and a tiny
# local HTTP endpoint. Needs bash, git, jq, flock, curl, python3.
#
#   services/tests/run.sh
# shellcheck disable=SC2016  # single-quoted bash -c bodies and generated stubs expand later, on purpose
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/.."
T="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null; fi
  rm -rf "$T"
}
trap cleanup EXIT

pass=0
fail=0
check() {  # check <description> <command...>
  local desc="$1"
  shift
  echo "--- $desc" >>"$T/test.log"
  if "$@" >>"$T/test.log" 2>&1; then
    pass=$((pass + 1)); echo "  ok   $desc"
  else
    fail=$((fail + 1)); echo "  FAIL $desc"
  fi
}
expect_exit() {  # expect_exit <code> <command...>
  local want="$1" got
  shift
  "$@"
  got=$?
  if [ "$got" -ne "$want" ]; then echo "expected exit $want, got $got"; return 1; fi
}

mkdir -p "$T"/{bin,state,live/demo}
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
echo 200 >"$T/state/http_status"

# docker stub. Fake compose files are lines like "service: web" and "web: image=web:1";
# a service's config hash is the sha256 of its own "<service>:" lines, so changing one
# service changes only its hash, like real Compose.
cat >"$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STATE/docker.log"
if [ "$1" = ps ]; then
  project="${4#label=com.docker.compose.project=}"
  d="$STATE/running/$project"
  [ -d "$d" ] || exit 0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    read -r h st <"$f"
    echo "$(basename "$f") $h $st"
  done
  exit 0
fi
[ "$1" = compose ] || { echo "stub: unsupported: $*" >&2; exit 99; }
shift
project="" files=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p) project="$2"; shift 2 ;;
    --project-directory) shift 2 ;;
    -f) files+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
hash_of() { grep -h "^$1:" "${files[@]}" | sha256sum | cut -c1-64; }
cmd="$1"
shift
case "$cmd" in
  config)
    if grep -q INVALID "${files[@]}"; then echo "stub: invalid compose" >&2; exit 15; fi
    if [ "${1:-}" = --hash ]; then
      grep -h '^service: ' "${files[@]}" | awk '{print $2}' | sort -u | while read -r s; do echo "$s $(hash_of "$s")"; done
    fi
    ;;
  up)
    svcs=() dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1 ;;
        --wait-timeout) shift ;;
        -*) : ;;
        *) svcs+=("$1") ;;
      esac
      shift
    done
    [ "$dry" -eq 0 ] || { echo "DRY-RUN would recreate ${svcs[*]}"; exit 0; }
    mkdir -p "$STATE/running/$project"
    for s in "${svcs[@]}"; do
      if [ -e "$STATE/fail_up" ]; then
        echo "$(hash_of "$s") exited" >"$STATE/running/$project/$s"
        exit 1
      fi
      echo "$(hash_of "$s") running" >"$STATE/running/$project/$s"
    done
    ;;
  *) echo "stub: unsupported compose $cmd" >&2; exit 99 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/logger"
chmod +x "$T"/bin/*

cat >"$T/server.py" <<'EOF'
import http.server, sys
status_file = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(int(open(status_file).read().strip()))
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
python3 "$T/server.py" "$port" "$T/state/http_status" &
server_pid=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done

# Throwaway "pinned checkout": the real scripts plus one demo service.
R="$T/repo"
mkdir -p "$R/services/bin" "$R/services/lib" "$R/services/demo"
cp "$src/bin/apply-service" "$src/bin/drift-check" "$R/services/bin/"
cp "$src/lib/common.sh" "$R/services/lib/"
cat >"$R/services/demo/compose.yml" <<'EOF'
service: db
service: web
service: worker
db: image=db:1
web: image=web:1
worker: image=worker:1
EOF
cat >"$R/services/demo/apply.conf" <<'EOF'
PROJECT=demo-proj
LIVE_DIR="$SERVICES_LIVE_ROOT/demo"
COMPOSE_FILES=("$REPO/services/demo/compose.yml")
SERVICES=(db web)
REQUIRE_FILES=(.env)
HTTP_CHECKS=("http://127.0.0.1:$TEST_PORT/")
EOF
echo 'SECRET=x' >"$T/live/demo/.env"
git -C "$R" init -q
commit() { git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"; }
commit init

export PATH="$T/bin:$PATH" STATE="$T/state" DOCKER="$T/bin/docker" SERVICES_LIVE_ROOT="$T/live" \
  SERVICES_STATE_DIR="$T/state/services" HTTP_TIMEOUT=2 HTTP_INTERVAL=1 TEST_PORT="$port"
apply="$R/services/bin/apply-service"
drift="$R/services/bin/drift-check"
ups() { grep -c ' up -d --no-deps --wait' "$T/state/docker.log" 2>/dev/null || true; }
set_image() {  # set_image <service> <image>
  sed -i "s|^$1: image=.*|$1: image=$2|" "$R/services/demo/compose.yml"
  commit "$1 -> $2"
}

echo "apply-service"
check "unknown service refused" expect_exit 1 "$apply" nope
check "usage error" expect_exit 64 "$apply" demo --force
check "dry run exits 0" expect_exit 0 "$apply" demo --dry-run
check "dry run starts nothing" test ! -e "$T/state/running/demo-proj"
check "first apply recreates the managed services" expect_exit 0 "$apply" demo
check "db and web running" test -f "$T/state/running/demo-proj/db" -a -f "$T/state/running/demo-proj/web"
check "unmanaged service never started" test ! -e "$T/state/running/demo-proj/worker"
check "state records the applied sha" test "$(jq -r .sha "$T/state/services/demo.json")" = "$(git -C "$R" rev-parse HEAD)"
before="$(ups)"
check "second apply is a no-op" expect_exit 0 "$apply" demo
check "no-op did not call up" test "$(ups)" = "$before"
recreates() { grep -c -- ' up -d --no-deps --force-recreate --wait' "$T/state/docker.log" 2>/dev/null || true; }
check "--dry-run --recreate exits 0" expect_exit 0 "$apply" demo --dry-run --recreate
check "--dry-run --recreate recreates nothing" test "$(recreates)" = 0
check "--recreate with no drift exits 0" expect_exit 0 "$apply" demo --recreate
check "--recreate force-recreated every managed service" bash -c 'grep -- " up -d --no-deps --force-recreate --wait" "$1" | tail -1 | grep -qE " db web$"' _ "$T/state/docker.log"
check "--recreate never touches unmanaged services" test ! -e "$T/state/running/demo-proj/worker"
check "options in either order" expect_exit 0 "$apply" demo --recreate --dry-run
set_image web web:2
check "changed service applies" expect_exit 0 "$apply" demo
check "only web was recreated" bash -c 'grep " up -d --no-deps --wait" "$1" | tail -1 | grep -qE " web$"' _ "$T/state/docker.log"
echo "# local edit" >>"$R/services/demo/compose.yml"
check "dirty checkout refused" expect_exit 1 "$apply" demo
git -C "$R" checkout -q -- services/demo/compose.yml
mv "$T/live/demo/.env" "$T/env.aside"
check "missing required live file refused" expect_exit 1 "$apply" demo
mv "$T/env.aside" "$T/live/demo/.env"
echo INVALID >>"$R/services/demo/compose.yml"
commit invalid
check "invalid compose refused" expect_exit 1 "$apply" demo
git -C "$R" reset -q --hard HEAD~1
sed -i 's/^SERVICES=.*/SERVICES=(db web cache)/' "$R/services/demo/apply.conf"
commit "bad conf"
check "conf listing an undefined service refused" expect_exit 1 "$apply" demo
git -C "$R" reset -q --hard HEAD~1
good_sha="$(jq -r .sha "$T/state/services/demo.json")"
touch "$T/state/fail_up"
set_image db db:2
check "failed up exits 2" expect_exit 2 "$apply" demo
check "state keeps the last good sha" test "$(jq -r .sha "$T/state/services/demo.json")" = "$good_sha"
check "failure logged" grep -q 'result=unhealthy' "$T/state/services/apply.log"
rm -f "$T/state/fail_up"

echo "drift-check"
check "exited container reported as drift (exit 1)" expect_exit 1 "$drift"
check "report names the exited service" bash -c '"$1" | grep -q "DRIFT demo (demo-proj): db exited"' _ "$drift"
exec 8>"$T/state/services/demo.lock"
flock -n 8
check "apply while locked exits 3" expect_exit 3 "$apply" demo
exec 8>&-
echo 500 >"$T/state/http_status"
check "failing HTTP check exits 2" expect_exit 2 "$apply" demo
echo 200 >"$T/state/http_status"
set_image web web:3
check "apply after recovery succeeds" expect_exit 0 "$apply" demo
check "in sync (exit 0)" expect_exit 0 "$drift"
echo "deadbeef running" >"$T/state/running/demo-proj/web"
check "hand-changed container reported (exit 1)" expect_exit 1 "$drift"
check "report says config-differs" bash -c '"$1" | grep -q "DRIFT demo (demo-proj): web config-differs"' _ "$drift"
check "ALERT_CMD receives the report" bash -c 'ALERT_CMD="cat > $2" "$1"; grep -q "config-differs" "$2"' _ "$drift" "$T/alert.txt"
rm -f "$T/state/running/demo-proj/web"
check "missing container reported" bash -c '"$1" | grep -q "DRIFT demo (demo-proj): web missing"' _ "$drift"
"$apply" demo >>"$T/test.log" 2>&1
echo junk >"$R/untracked.txt"
check "dirty checkout reported as drift" bash -c '! "$1" >/dev/null && "$1" | grep -q "DRIFT checkout"' _ "$drift"
rm -f "$R/untracked.txt"
check "back in sync" expect_exit 0 "$drift"

echo
echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  cp "$T/test.log" "${TEST_LOG_OUT:-$PWD/services-tests.log}"
  echo "log: ${TEST_LOG_OUT:-$PWD/services-tests.log}"
  exit 1
fi
