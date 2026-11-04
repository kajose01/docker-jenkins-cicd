#!/usr/bin/env bash
# Drill for the Jenkins-level rollback.
# Deploys a "release" whose tasks run fine (so Swarm sees nothing wrong and does NOT roll back) but which does
# not serve the app, then proves: the smoke test catches it, and scripts/rollback.sh restores the previous release.
# This briefly replaces the LIVE service. A trap restores it even if the drill dies halfway.
# Exits 1 if any check fails. Failure log is kept separately from the passing evidence.
set -uo pipefail
cd "$(dirname "$0")/.."
SERVICE=${SERVICE:-cicd_app}
T=$(mktemp -d); RUNLOG="$T/run.log"; : > "$RUNLOG"
PASS=0; FAILN=0

log()   { echo "$*" | tee -a "$RUNLOG"; }
die()   { log "FATAL: $1"; exit 1; }
check() { if [ "$2" = "$3" ]; then log "PASS: $1 (got $2)"; PASS=$((PASS+1)); else log "FAIL: $1 (expected $3, got $2)"; FAILN=$((FAILN+1)); fi; }
img()   { docker service inspect "$SERVICE" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'; }
served(){ curl -s --max-time 3 localhost:8095/version | grep -o '"build":"[^"]*"' | cut -d'"' -f4; }

PREV=$(img 2>/dev/null) || die "service $SERVICE not found"
PREV_TAG=${PREV#*:}; PREV_TAG=${PREV_TAG%%@*}

cleanup() {
  rc=$?
  if [ "$(img 2>/dev/null)" != "$PREV" ]; then
    echo "drill ended with the service on a different image; restoring $PREV"
    bash scripts/rollback.sh "$PREV" >/dev/null 2>&1 || echo "WARNING: automatic restore failed; run: bash scripts/rollback.sh $PREV"
  fi
  mkdir -p evidence
  if [ $rc -eq 0 ]; then cp "$RUNLOG" evidence/rollback-drill.log
  else cp "$RUNLOG" evidence/rollback-drill.failed.log; echo "Failure log kept: evidence/rollback-drill.failed.log"; fi
  rm -rf "$T"
}
trap cleanup EXIT

log "== Before: previous release is $PREV"
docker service ps "$SERVICE" | head -6 | tee -a "$RUNLOG"
SMOKE_CONSECUTIVE=3 bash scripts/smoke-test.sh "$PREV_TAG" "" >/dev/null 2>&1 || die "the current release (build $PREV_TAG) is not healthy; fix that first"
check "P1 before the drill: build $PREV_TAG is serving" "$(served)" "$PREV_TAG"

log; log "== 1. Deploy a bad release (nginx:alpine: tasks run, nothing answers on port 3000)"
docker service update --quiet --image nginx:alpine "$SERVICE" >/dev/null 2>&1 || log "note: update command returned non-zero"
st=""; for _ in $(seq 1 30); do st=$(docker service inspect "$SERVICE" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}'); [ "$st" = completed ] && break; sleep 2; done   # state stays "updating" until the 10s monitor period ends
check "D1 Swarm treats the update as successful (no automatic rollback happened)" "$st" completed
check "D2 the service now runs the bad image" "$(img | cut -d@ -f1)" "nginx:alpine"
docker service ps "$SERVICE" | head -6 | tee -a "$RUNLOG"

log; log "== 2. The smoke test must catch it"
SMOKE_ATTEMPTS=8 SMOKE_SLEEP=2 bash scripts/smoke-test.sh 999 deadbeef >"$T/smoke.out" 2>&1; rc=$?
tail -3 "$T/smoke.out" | tee -a "$RUNLOG"
check "D3 smoke test fails (exit status)" "$rc" 1

log; log "== 3. Roll back"
bash scripts/rollback.sh "$PREV" >"$T/rb.out" 2>&1; rc=$?
tail -12 "$T/rb.out" | tee -a "$RUNLOG"
check "D4 rollback.sh succeeds (exit status)" "$rc" 0
check "D5 the service runs the previous image again" "$(img)" "$PREV"
check "D6 the app serves the previous build again" "$(served)" "$PREV_TAG"
check "D7 all replicas are running" "$(docker service ls --filter name="$SERVICE" --format '{{.Replicas}}')" "2/2"

log; log "RESULT: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
