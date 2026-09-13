#!/usr/bin/env bash
# End-to-end tests for deploy-release, deploy-gate and migrate-app. They run the
# real scripts against a throwaway tree with a stub systemctl and a tiny local HTTP
# "app" whose health follows the release that is "running". Nothing outside a temp
# dir is touched. Needs bash, python3, curl, jq, flock, rsync, tar.
#
#   deploy/tests/run.sh
# shellcheck disable=SC2016  # single-quoted bash -c bodies and generated stubs expand later, on purpose
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="$here/../bin"
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
cur() { basename "$(readlink "$T/apps/$1/current")"; }

mkdir -p "$T"/{apps,conf,units,templates,state,incoming,build,bin}
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"

# systemctl stub: "restart" resolves the unit's WorkingDirectory like systemd does
# at start time and records it as the running app's directory.
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STATE/systemctl.log"
case "$1" in
  restart)
    wd="$(sed -n 's/^WorkingDirectory=//p' "$UNIT_DIR/$2.service")"
    readlink -f "$wd" >"$STATE/active_dir"
    ;;
  is-active) echo active ;;
  *) : ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/logger"
printf '#!/usr/bin/env bash\necho "$*" >"$STATE/rrsync.args"\n' >"$T/bin/rrsync"
chmod +x "$T"/bin/*

# The "app": answers every path with the status stored in <running dir>/HEALTH_STATUS.
cat >"$T/server.py" <<'EOF'
import http.server, os, sys
state = sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            active = open(os.path.join(state, "active_dir")).read().strip()
            code = int(open(os.path.join(active, "HEALTH_STATUS")).read().strip())
        except Exception:
            code = 503
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
EOF
python3 "$T/server.py" "$port" "$T/state" &
server_pid=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done

export PATH="$T/bin:$PATH" STATE="$T/state" UNIT_DIR="$T/units" TEMPLATE_DIR="$T/templates" \
  APPS_ROOT="$T/apps" CONF_DIR="$T/conf" SYSTEMCTL="$T/bin/systemctl" SUDO="" \
  HEALTH_TIMEOUT=3 HEALTH_INTERVAL=1 INCOMING_DIR="$T/incoming"

for a in demo demo2; do
  cat >"$T/conf/$a.conf" <<EOF
UNIT=$a
PORT=$port
ENV_FILES=(.env)
HEALTH_PATHS=(/ /booking)
KEEP_RELEASES=3
EOF
  printf '[Service]\nWorkingDirectory=%s\n' "$T/apps/$a/current" >"$T/templates/$a.service"
  mkdir -p "$T/old/$a"
  printf '[Service]\nWorkingDirectory=%s\n' "$T/old/$a" >"$T/units/$a.service"
  echo 'console.log("old")' >"$T/old/$a/server.js"
  echo 200 >"$T/old/$a/HEALTH_STATUS"
  echo 'SECRET=from-old-dir' >"$T/old/$a/.env"
done

make_artifact() {  # make_artifact <app> <tag> <sha7> <health-status> [extra root file]
  local d="$T/build/$1-$2" name="$1-$2-$3.tgz"
  rm -rf "$d"
  mkdir -p "$d/.next/static"
  echo 'console.log("new")' >"$d/server.js"
  printf 'tag=%s\nsha=%s\n' "$2" "$3" >"$d/RELEASE"
  echo "$4" >"$d/HEALTH_STATUS"
  if [ -n "${5:-}" ]; then echo leak >"$d/$5"; fi
  tar -czf "$T/incoming/$name" -C "$d" .
  (cd "$T/incoming" && sha256sum "$name" >"$name.sha256")
  echo "$T/incoming/$name"
}

echo "migrate-app --seed-from-live"
export OLD_DIR="$T/old/demo"
"$T/bin/systemctl" restart demo
check "dry run exits 0" expect_exit 0 "$bin/migrate-app" demo --seed-from-live --dry-run
check "dry run changes nothing" test ! -e "$T/apps/demo"
check "migration succeeds" expect_exit 0 "$bin/migrate-app" demo --seed-from-live
check "current is a legacy release" bash -c '[[ "$(basename "$(readlink "$1")")" == legacy-* ]]' _ "$T/apps/demo/current"
check "env copied to shared/ with mode 600" test "$(stat -c %a "$T/apps/demo/shared/.env")" = 600
check "release links the shared env file" test "$(readlink "$T/apps/demo/current/.env")" = ../../shared/.env
check "unit replaced by template" cmp -s "$T/units/demo.service" "$T/templates/demo.service"
check "old dir untouched" test -f "$T/old/demo/.env"
check "second migration refused" expect_exit 1 "$bin/migrate-app" demo --seed-from-live
legacy="$(cur demo)"

echo "deploy-release"
a1="$(make_artifact demo v1.0.0 aaaaaaa 200)"
check "good deploy succeeds" expect_exit 0 "$bin/deploy-release" deploy demo "$a1"
check "current -> v1.0.0" test "$(cur demo)" = v1.0.0-aaaaaaa
check "previous recorded in deployed.json" test "$(jq -r .previous "$T/apps/demo/deployed.json")" = "$legacy"
a2="$(make_artifact demo v1.1.0 bbbbbbb 500)"
check "unhealthy deploy exits 1" expect_exit 1 "$bin/deploy-release" deploy demo "$a2"
check "auto-rolled back to v1.0.0" test "$(cur demo)" = v1.0.0-aaaaaaa
check "history shows rolled-back" grep -q 'result=rolled-back current=v1.0.0-aaaaaaa' "$T/apps/demo/deploy.log"
a3="$(make_artifact demo v1.1.1 ccccccc 200 .env.production)"
check "artifact with a root env file refused" expect_exit 1 "$bin/deploy-release" deploy demo "$a3"
check "refused artifact not installed" test ! -e "$T/apps/demo/releases/v1.1.1-ccccccc"
a4="$(make_artifact demo v1.1.2 ddddddd 200)"
echo 0000 >"$a4.sha256"
check "checksum mismatch refused" expect_exit 1 "$bin/deploy-release" deploy demo "$a4"
check "badly named artifact refused" bash -c 'cp "$1" "$2" && cp "$1.sha256" "$2.sha256" && ! "$3" deploy demo "$2"' _ "$a1" "$T/incoming/demo-latest.tgz" "$bin/deploy-release"
check "redeploying an existing release refused" expect_exit 1 "$bin/deploy-release" deploy demo "$a1"
a5="$(make_artifact demo v1.1.3 eeeeeee 200)"
mv "$T/apps/demo/shared/.env" "$T/env.aside"
check "missing shared env refused before switching" expect_exit 1 "$bin/deploy-release" deploy demo "$a5"
check "current unchanged after refusal" test "$(cur demo)" = v1.0.0-aaaaaaa
mv "$T/env.aside" "$T/apps/demo/shared/.env"
check "rollback to previous" expect_exit 0 "$bin/deploy-release" rollback demo
check "current -> legacy" test "$(cur demo)" = "$legacy"
check "second rollback flips back" expect_exit 0 "$bin/deploy-release" rollback demo
check "current -> v1.0.0 again" test "$(cur demo)" = v1.0.0-aaaaaaa
check "rollback to unknown release refused" expect_exit 1 "$bin/deploy-release" rollback demo ../../etc
exec 8>"$T/apps/demo/.deploy.lock"
flock -n 8
check "concurrent deploy refused (exit 3)" expect_exit 3 "$bin/deploy-release" deploy demo "$a5"
exec 8>&-
for v in 2 3 4; do
  a="$(make_artifact demo "v1.$v.0" "f${v}f${v}f${v}f" 200)"
  "$bin/deploy-release" deploy demo "$a" >>"$T/test.log" 2>&1
done
check "current -> v1.4.0" test "$(cur demo)" = v1.4.0-f4f4f4f
check "pruned to KEEP_RELEASES=3" test "$(find "$T/apps/demo/releases" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)" -eq 3
check "status exits 0" expect_exit 0 "$bin/deploy-release" status demo

echo "deploy-gate"
check "interactive shell refused" expect_exit 126 env SSH_ORIGINAL_COMMAND="bash -i" "$bin/deploy-gate"
check "empty request refused" expect_exit 126 env SSH_ORIGINAL_COMMAND= "$bin/deploy-gate"
check "path traversal in artifact name refused" expect_exit 126 env SSH_ORIGINAL_COMMAND="deploy demo ../../etc/passwd" "$bin/deploy-gate"
check "chained command refused" expect_exit 126 env SSH_ORIGINAL_COMMAND="status demo; id" "$bin/deploy-gate"
check "status allowed" expect_exit 0 env SSH_ORIGINAL_COMMAND="status demo" "$bin/deploy-gate"
check "rsync upload goes to write-only rrsync" bash -c 'SSH_ORIGINAL_COMMAND="rsync --server -logDtpre.iLsfxCIvu . x" RRSYNC="$1" "$2" && grep -qxF -- "-wo -no-del $3" "$STATE/rrsync.args"' _ "$T/bin/rrsync" "$bin/deploy-gate" "$T/incoming"
a6="$(make_artifact demo v1.5.0 abcdef0 200)"
check "deploy through the gate" expect_exit 0 env SSH_ORIGINAL_COMMAND="deploy demo $(basename "$a6")" "$bin/deploy-gate"
check "current -> v1.5.0" test "$(cur demo)" = v1.5.0-abcdef0

echo "migrate-app --from-tarball (failure restores the old unit)"
export OLD_DIR="$T/old/demo2"
"$T/bin/systemctl" restart demo2
cp "$T/units/demo2.service" "$T/demo2.old.service"
b1="$(make_artifact demo2 v2.0.0 1234567 500)"
check "unhealthy migration exits 1" expect_exit 1 "$bin/migrate-app" demo2 --from-tarball "$b1"
check "old unit restored" cmp -s "$T/units/demo2.service" "$T/demo2.old.service"
check "old app serving again" test "$(cat "$T/state/active_dir")" = "$(readlink -f "$T/old/demo2")"
check "current removed so migration can be retried" test ! -e "$T/apps/demo2/current"

echo
echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  cp "$T/test.log" "${TEST_LOG_OUT:-$PWD/deploy-tests.log}"
  echo "log: ${TEST_LOG_OUT:-$PWD/deploy-tests.log}"
  exit 1
fi
