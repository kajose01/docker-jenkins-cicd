#!/usr/bin/env bash
# Compares the plugins running in the LIVE Jenkins with jenkins/plugins.txt (the pinned list).
# Exits 1 if a pinned plugin is missing, has another version, or any plugin is inactive. Output goes to evidence/plugin-check.log.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
J=${JENKINS_URL:-http://localhost:8081}
# -g: the square brackets in the tree= filter must not be treated as a curl URL range
JSON=$(curl -sSg -u "admin:$JENKINS_ADMIN_PASSWORD" "$J/pluginManager/api/json?depth=1&tree=plugins[shortName,version,active,enabled]") || { echo "curl failed (exit $?) for $J/pluginManager/api/json"; exit 1; }
case "$JSON" in '{'*) ;; *) echo "unexpected answer from Jenkins (not JSON): ${JSON:0:200}"; exit 1;; esac
mkdir -p evidence
{
  echo "Live Jenkins $(curl -sI "$J/login" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-jenkins"{print $2}') plugin check on $(date -u +%F), against jenkins/plugins.txt"
  PLUGINS_JSON="$JSON" python3 - <<'PY'
import json, os, sys
live = {p["shortName"]: p for p in json.loads(os.environ["PLUGINS_JSON"])["plugins"]}
want = {}
for l in open("jenkins/plugins.txt"):
    l = l.strip()
    if l and not l.startswith("#"):
        n, v = l.split(":", 1); want[n] = v
bad = False
for n, v in sorted(want.items()):
    if n not in live: print("MISSING ", n, v); bad = True
    elif live[n]["version"] != v: print("DIFFERS ", n, "live", live[n]["version"], "pinned", v); bad = True
for n, p in sorted(live.items()):
    if n not in want: print("EXTRA   ", n, p["version"])
    if not p["active"] or not p["enabled"]: print("INACTIVE", n, p["version"]); bad = True
j = live.get("junit", {})
print("junit:", j.get("version"), "active:", j.get("active"))
print("live plugins:", len(live), "pinned:", len(want), "->", "MISMATCH" if bad else "ALL MATCH")
sys.exit(1 if bad else 0)
PY
} | tee evidence/plugin-check.log
exit "${PIPESTATUS[0]}"
