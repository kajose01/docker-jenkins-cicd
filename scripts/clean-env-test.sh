#!/usr/bin/env bash
# Clean-environment test: builds the Jenkins image from the repo and starts a throwaway instance
# (no volume, no Docker socket, dummy credentials, 127.0.0.1:8082). Exits 1 if any check fails.
set -euo pipefail
export LC_ALL=C   # same sort order for both plugin lists
cd "$(dirname "$0")/.."

IMG=jenkins-cleanenv; C=jenkins-cleanenv-test; PORT=8082; J=http://127.0.0.1:$PORT
T=$(mktemp -d); RUNLOG="$T/run.log"; : > "$RUNLOG"
PW=$(python3 -c 'import secrets; print(secrets.token_hex(12))')   # random, used once, never stored
PASS=0; FAILN=0

log()   { echo "$*" | tee -a "$RUNLOG"; }
die()   { log "FATAL: $1"; exit 1; }
check() { if [ "$2" = "$3" ]; then log "PASS: $1 (got $2)"; PASS=$((PASS+1)); else log "FAIL: $1 (expected $3, got $2)"; FAILN=$((FAILN+1)); fi; }
code()  { curl -s -o /dev/null -w '%{http_code}' "$@" || true; }

cleanup() {
  rc=$?
  docker rm -f $C >/dev/null 2>&1 || true
  mkdir -p evidence
  if [ $rc -eq 0 ]; then cp "$RUNLOG" evidence/clean-env-test.log
  else cp "$RUNLOG" evidence/clean-env-test.failed.log; echo "Failure log kept: evidence/clean-env-test.failed.log"; fi
  rm -rf "$T"
}
trap cleanup EXIT

ss -ltn | grep -q ":$PORT " && die "port $PORT already in use"
docker rm -f $C >/dev/null 2>&1 || true

log "== Build from the repository"
docker build -q -t $IMG ./jenkins >/dev/null || die "image build failed"

log; log "== Start a throwaway instance"
docker run -d --name $C -p 127.0.0.1:$PORT:8080 \
  -e JENKINS_ADMIN_PASSWORD="$PW" -e DOCKERHUB_TOKEN=dummy-not-a-secret $IMG >/dev/null
UP=no
for _ in $(seq 1 90); do [ "$(code $J/login)" = 200 ] && { UP=yes; break; }; sleep 3; done
check "T1 Jenkins boots from the repo configuration" "$UP" yes
[ "$UP" = yes ] || die "Jenkins did not start; see: docker logs $C"
log "     Jenkins version: $(curl -sI $J/login | tr -d '\r' | awk -F': ' 'tolower($1)=="x-jenkins"{print $2}')"

log; log "== Configuration as Code and plugins"
check "T2 docker-cicd job was created from casc.yaml" "$(code -u "admin:$PW" $J/job/docker-cicd/api/json)" 200
check "T3 anonymous access is refused" "$( [ "$(code $J/job/docker-cicd/api/json)" = 403 ] || [ "$(code $J/job/docker-cicd/api/json)" = 401 ] && echo yes || echo no)" yes
docker exec $C jenkins-plugin-cli --list 2>/dev/null | grep -E '^[a-z0-9-]+ [0-9]' | awk '{print $1":"$2}' | sort > "$T/got"
grep -v '^#' jenkins/plugins.txt | grep -v '^$' | sort > "$T/want"
check "T4 installed plugins match jenkins/plugins.txt exactly" "$(diff -q "$T/got" "$T/want" >/dev/null && echo identical || echo different)" identical
[ "$(diff -q "$T/got" "$T/want" >/dev/null && echo identical || echo different)" = identical ] || { log "     diff (< installed, > plugins.txt):"; diff "$T/got" "$T/want" | tee -a "$RUNLOG" || true; }
check "T5 junit plugin is installed" "$(grep -c '^junit:' "$T/got")" 1
log "     plugins installed: $(wc -l < "$T/got")"

log; log "RESULT: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
