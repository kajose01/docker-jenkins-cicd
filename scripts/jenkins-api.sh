#!/usr/bin/env bash
# usage: jenkins-api.sh wait | trigger | status | log
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
J=http://localhost:8081; U="admin:$JENKINS_ADMIN_PASSWORD"; C=$(mktemp)
crumb() { curl -s -c "$C" -u "$U" "$J/crumbIssuer/api/json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])'; }
case "${1:-}" in
  wait)    for i in $(seq 1 100); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$J/login")" = 200 ] && { echo "jenkins is up"; exit 0; }; sleep 3; done; echo "jenkins did not come up"; exit 1;;
  trigger) curl -s -b "$C" -u "$U" -H "$(crumb)" -X POST "$J/job/docker-cicd/build" -o /dev/null -w 'trigger HTTP %{http_code}\n';;
  status)  curl -s -u "$U" "$J/job/docker-cicd/lastBuild/api/json?tree=number,result,building,duration" ; echo;;
  log)     curl -s -u "$U" "$J/job/docker-cicd/lastBuild/consoleText";;
  *) echo "usage: $0 wait|trigger|status|log"; exit 1;;
esac
