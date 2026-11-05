#!/usr/bin/env bash
# Demo with assertions: a deliberately broken release must be stopped at the Test stage, the running release must
# keep serving, and the revert must deploy as the next build with the matching commit.
# Scenario 1: push a commit that breaks the greeting tests
# Scenario 2: revert exactly that commit and push
# Every expectation prints PASS/FAIL; the script exits 1 if any fails. It refuses to start unless the Git tree is
# clean, on main, in sync with origin, and Jenkins and the service are healthy. Original Jenkins console logs of both
# builds are kept in evidence/demo-<timestamp>/ and never overwritten. A trap reverts the bad commit if the script
# dies after pushing it, so the repository is never left broken.
set -uo pipefail
cd "$(dirname "$0")/.."
TS=$(date +%Y%m%d-%H%M%S); DIR=evidence/demo-$TS; mkdir -p "$DIR"; OUT=$DIR/demo.log; : > "$OUT"
PASS=0; FAILN=0; BAD=""; REVERTED=0

log()   { echo "$*" | tee -a "$OUT"; }
die()   { log "FATAL: $1"; exit 1; }
check() { if [ "$2" = "$3" ]; then log "PASS: $1 (got $2)"; PASS=$((PASS+1)); else log "FAIL: $1 (expected $3, got $2)"; FAILN=$((FAILN+1)); fi; }
has()   { if grep -Eq "$2" "$3"; then echo yes; else echo no; fi; }

cleanup() {
  rc=$?
  if [ -n "$BAD" ] && [ "$REVERTED" = 0 ]; then
    echo "demo ended before the revert; reverting the bad commit $BAD so the repository is not left broken"
    git revert --no-edit "$BAD" >/dev/null 2>&1 && git push origin main || echo "WARNING: automatic revert failed; revert $BAD by hand"
  fi
  if [ "$FAILN" -gt 0 ] || [ "$rc" -ne 0 ]; then mv "$DIR" "$DIR-FAILED" 2>/dev/null; fi
}
trap cleanup EXIT

last()   { ./scripts/jenkins-api.sh status | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["number"], d["result"] or "RUNNING", d["building"])'; }
desc()   { ./scripts/jenkins-api.sh status | python3 -c 'import sys,json; print(json.load(sys.stdin).get("description") or "")'; }
served() { curl -s --max-time 3 localhost:8095/version | grep -o "\"$1\":\"[^\"]*\"" | cut -d'"' -f4; }
img()    { docker service inspect cicd_app --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'; }
reps()   { docker service ls --filter name=cicd_app --format '{{.Replicas}}'; }
wait_build() {   # wait_build <previous build number> <commit>; waits for the build OF THAT COMMIT; prints "<number> <result>"
  local n0=$1 sha=$2 n res b L seen=$1
  for i in $(seq 1 120); do
    read -r n res b <<<"$(last)"
    if [ "$n" -gt "$seen" ] && [ "$b" = False ]; then
      L=$(./scripts/jenkins-api.sh log)   # read the whole log first: "log | grep -q" can fail under pipefail (SIGPIPE)
      case "$L" in *"building commit $sha as build $n"*) echo "$n $res"; return;; esac
      seen=$n   # that build was for a different commit; keep waiting for ours
    fi
    if [ "$i" -eq 40 ] && [ "$n" -le "$n0" ]; then ./scripts/jenkins-api.sh trigger >/dev/null; fi   # polling never noticed the push
    sleep 3
  done
  echo "$n TIMEOUT"
}

log "== Preconditions (the script is safe to re-run only from a clean, synced main)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "working tree has uncommitted changes; commit or stash first"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
git fetch origin >/dev/null 2>&1 || die "git fetch failed"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin/main; push or pull first"
grep -qF 'Hello, ${n}!' app/src/lib.js || die "app/src/lib.js does not contain the expected greeting text; the demo cannot break it"
read -r N0 R0 B0 <<<"$(last)"
[ "$R0" = SUCCESS ] && [ "$B0" = False ] || die "last Jenkins build #$N0 is $R0 (building=$B0); it must be an idle SUCCESS"
PREV_IMAGE=$(img)
GOOD=$(git rev-parse HEAD)
check "P1 the app is serving the last build (#$N0)" "$(served build)" "$N0"
check "P2 all replicas are running" "$(reps)" "2/2"
check "P3 the app serves the commit at HEAD (the last push has been built and deployed)" "$(served commit)" "$(git rev-parse --short HEAD)"
[ "$FAILN" -eq 0 ] || die "a precondition failed; wait for Jenkins to finish building the latest push, then run again"

log; log "== Scenario 1: push a commit that breaks the greeting tests"
sed -i 's/Hello, ${n}!/Hi, ${n}!/' app/src/lib.js
git diff --quiet app/src/lib.js && die "the edit changed nothing"
git commit app/src/lib.js -m "Change greeting text (breaks the tests on purpose)" >/dev/null || die "commit failed"
BAD_LOCAL=$(git rev-parse HEAD)
if git push origin main; then BAD=$BAD_LOCAL; else git reset --hard "$GOOD" >/dev/null; die "push failed; the local bad commit was removed"; fi
read -r N1 R1 <<<"$(wait_build "$N0" "$(git rev-parse --short "$BAD")")"
./scripts/jenkins-api.sh log > "$DIR/scenario1-broken-release.console.log"
log "build #$N1 result: $R1 (full console log: $DIR/scenario1-broken-release.console.log)"
grep -E "(pass|fail) [0-9]+[[:space:]]*$|skipped due to earlier|Finished:" "$DIR/scenario1-broken-release.console.log" | tee -a "$OUT"
check "B1 the broken build failed" "$R1" FAILURE
check "B2 tests failed (the fail count is not 0)" "$(has x 'fail [1-9][0-9]*[[:space:]]*$' "$DIR/scenario1-broken-release.console.log")" yes
check "B3 build description names the stage" "$(desc | grep -c 'test failure, stage Test')" 1
check "B4 the Deploy stage never ran (no previous-release line in the log)" "$(has x 'previous release:' "$DIR/scenario1-broken-release.console.log")" no
check "B5 the running image is unchanged" "$(img)" "$PREV_IMAGE"
check "B6 the old build (#$N0) is still serving" "$(served build)" "$N0"
check "B7 all replicas are running" "$(reps)" "2/2"

log; log "== Scenario 2: revert the bad commit"
git revert --no-edit "$BAD" >/dev/null || die "revert failed"
REVERTED=1
git push origin main || die "push of the revert failed"
HEAD_SHORT=$(git rev-parse --short HEAD)
read -r N2 R2 <<<"$(wait_build "$N1" "$HEAD_SHORT")"
./scripts/jenkins-api.sh log > "$DIR/scenario2-revert.console.log"
log "build #$N2 result: $R2 (full console log: $DIR/scenario2-revert.console.log)"
grep -E "(pass|fail) [0-9]+[[:space:]]*$|SMOKE TEST|replicas running|Finished:" "$DIR/scenario2-revert.console.log" | tee -a "$OUT"
check "R1 the revert build succeeded" "$R2" SUCCESS
check "R2 build description confirms deployment" "$(desc | grep -c "^SUCCESS: build $N2 (commit $HEAD_SHORT)")" 1
check "R3 the app serves the new build (#$N2)" "$(served build)" "$N2"
check "R4 the app serves the reverted commit ($HEAD_SHORT)" "$(served commit)" "$HEAD_SHORT"
check "R5 the service runs image tag $N2" "$(img | sed 's/@.*//; s/.*://')" "$N2"
check "R6 all replicas are running" "$(reps)" "2/2"

log; log "RESULT: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
