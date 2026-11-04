#!/usr/bin/env bash
# Swarm-level automatic rollback test.
# Updates the LIVE service to a release that pulls and starts fine but FAILS ITS HEALTH CHECK, and proves:
#   - Swarm rolls the update back by itself (failure_action: rollback in docker-stack.yml)
#   - the previous release is restored
#   - the app keeps answering HTTP 200 during the whole failed update
# This is different from the Jenkins-level rollback (scripts/rollback.sh), which handles a release whose tasks are
# healthy but whose smoke test fails (see scripts/rollback-drill.sh).
# A trap restores the previous release if the test dies halfway. Exits 1 if any check fails.
set -uo pipefail
cd "$(dirname "$0")/.."
SERVICE=${SERVICE:-cicd_app}
T=$(mktemp -d); RUNLOG="$T/run.log"; : > "$RUNLOG"; : > "$T/probe.log"
PASS=0; FAILN=0; PROBE=""

log()   { echo "$*" | tee -a "$RUNLOG"; }
die()   { log "FATAL: $1"; exit 1; }
check() { if [ "$2" = "$3" ]; then log "PASS: $1 (got $2)"; PASS=$((PASS+1)); else log "FAIL: $1 (expected $3, got $2)"; FAILN=$((FAILN+1)); fi; }
img()   { docker service inspect "$SERVICE" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'; }
state() { docker service inspect "$SERVICE" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}'; }
served(){ curl -s --max-time 3 localhost:8095/version | grep -o '"build":"[^"]*"' | cut -d'"' -f4; }
tasks() { docker service ps "$SERVICE" --format 'table {{.Name}}\t{{.Image}}\t{{.DesiredState}}\t{{.CurrentState}}\t{{.Error}}' | head -"${1:-10}"; }

PREV=$(img 2>/dev/null) || die "service $SERVICE not found"
PREV_TAG=${PREV#*:}; PREV_TAG=${PREV_TAG%%@*}

cleanup() {
  rc=$?
  [ -n "$PROBE" ] && kill "$PROBE" 2>/dev/null
  if [ "$(img 2>/dev/null)" != "$PREV" ]; then
    echo "test ended with the service on a different image; restoring $PREV"
    bash scripts/rollback.sh "$PREV" >/dev/null 2>&1 || echo "WARNING: automatic restore failed; run: bash scripts/rollback.sh $PREV"
  fi
  mkdir -p evidence
  if [ $rc -eq 0 ]; then cp "$RUNLOG" evidence/swarm-rollback.log
  else cp "$RUNLOG" evidence/swarm-rollback.failed.log; echo "Failure log kept: evidence/swarm-rollback.failed.log"; fi
  rm -rf "$T"
}
trap cleanup EXIT

log "== Before: release $PREV"
log "update_config: $(docker service inspect "$SERVICE" --format 'parallelism={{.Spec.UpdateConfig.Parallelism}} order={{.Spec.UpdateConfig.Order}} failure_action={{.Spec.UpdateConfig.FailureAction}} monitor={{.Spec.UpdateConfig.Monitor}}')"
tasks 6 | tee -a "$RUNLOG"
SMOKE_CONSECUTIVE=3 bash scripts/smoke-test.sh "$PREV_TAG" "" >/dev/null 2>&1 || die "the current release (build $PREV_TAG) is not healthy; fix that first"
check "S1 before: build $PREV_TAG is serving" "$(served)" "$PREV_TAG"

# availability probe: one request per second for the whole test
( while true; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 localhost:8095/version || true)
    echo "$(date +%s) ${c:-000}" >> "$T/probe.log"; sleep 1
  done ) &
PROBE=$!

log; log "== 1. Update to a release that fails its health check (nginx:alpine, health check on port 3000)"
docker service update --image nginx:alpine \
  --health-cmd 'wget -qO- http://localhost:3000/health || exit 1' \
  --health-interval 5s --health-timeout 3s --health-retries 2 --health-start-period 2s \
  "$SERVICE" >"$T/update.out" 2>&1
log "docker service update exit status: $?"
tail -5 "$T/update.out" | tee -a "$RUNLOG"

st=""
for _ in $(seq 1 60); do
  st=$(state)
  case "$st" in rollback_completed|completed|rollback_paused|paused) break;; esac
  sleep 3
done
kill "$PROBE" 2>/dev/null; PROBE=""
log "update status: $(docker service inspect "$SERVICE" --format '{{json .UpdateStatus}}')"
tasks 12 | tee -a "$RUNLOG"

log; log "== 2. Swarm must have rolled back by itself"
check "S2 update status is rollback_completed" "$st" rollback_completed
check "S3 the service runs the previous image again" "$(img)" "$PREV"
check "S4 the app serves the previous build again" "$(served)" "$PREV_TAG"
r=""; for _ in $(seq 1 15); do r=$(docker service ls --filter name="$SERVICE" --format '{{.Replicas}}'); [ "$r" = "2/2" ] && break; sleep 2; done
check "S5 all replicas are running" "$r" "2/2"
total=$(wc -l < "$T/probe.log"); bad=$(awk '$2 != 200' "$T/probe.log" | wc -l)
log "availability probe: $total requests to /version during the test, $bad not answered with HTTP 200"
check "S6 every request during the failed update was answered with 200" "$bad" 0

log; log "RESULT: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
