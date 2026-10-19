#!/usr/bin/env bash
# 1) push a commit that breaks the tests  2) pipeline must stop before Deploy  3) revert  4) pipeline must deploy again
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=evidence/failing-test-demo.log; : > $OUT
log() { echo "$*" | tee -a $OUT; }
last() { ./scripts/jenkins-api.sh status | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["number"], d["result"] or "RUNNING", d["building"])'; }
ver() { curl -s --max-time 3 localhost:8095/version | grep -o '"build":"[^"]*"'; }
wait_build() {   # wait_build <previous build number>; prints "<number> <result>"
  local n0=$1 n res b
  for i in $(seq 1 120); do
    read -r n res b <<<"$(last)"
    if [ "$n" -gt "$n0" ] && [ "$b" = False ]; then echo "$n $res"; return; fi
    # if polling has not noticed the push after ~2 minutes, start the build by hand
    if [ "$i" -eq 40 ] && [ "$n" -le "$n0" ]; then ./scripts/jenkins-api.sh trigger >/dev/null; fi
    sleep 3
  done
  echo "$n TIMEOUT"
}

read -r N0 R0 _ <<<"$(last)"
log "== BEFORE: last build #$N0 = $R0, app serving $(ver)"

log; log "== 1. Push a commit that breaks the greeting tests"
sed -i 's/Hello, ${n}!/Hi, ${n}!/' app/src/lib.js
git diff --stat app/src/lib.js | tee -a $OUT
git commit app/src/lib.js -m "Change greeting text (breaks the tests on purpose)" >/dev/null && git push origin main
read -r N1 R1 <<<"$(wait_build "$N0")"
log "build #$N1 result: $R1"
./scripts/jenkins-api.sh log | grep -E "# (pass|fail)|skipped due to earlier|Finished:" | tee -a $OUT
log "app still serving: $(ver)   (must still be build #$N0)"
docker stack services cicd --format '{{.Name}} {{.Replicas}} {{.Image}}' | tee -a $OUT

log; log "== 2. Revert the bad commit"
git revert HEAD --no-edit >/dev/null && git push origin main
read -r N2 R2 <<<"$(wait_build "$N1")"
log "build #$N2 result: $R2"
./scripts/jenkins-api.sh log | grep -E "# (pass|fail)|smoke test|Finished:" | tee -a $OUT
log "app now serving: $(ver)   (must be build #$N2)"
docker stack services cicd --format '{{.Name}} {{.Replicas}} {{.Image}}' | tee -a $OUT
log; log "DONE"
