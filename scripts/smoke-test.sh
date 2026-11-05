#!/usr/bin/env bash
# Post-deployment verification.
# Usage: scripts/smoke-test.sh <expected-build> [<expected-commit>]
# Passes only if ALL of these hold:
#   1. /version reports the expected build (and commit, if given) for N consecutive requests
#   2. /health answers HTTP 200
#   3. every replica of the Swarm service is running the expected image tag
#   4. (optional) SMOKE_GREET_PATH answers HTTP 200 and contains SMOKE_GREET_EXPECT
# Tunable by environment: SMOKE_URL SERVICE IMAGE SMOKE_ATTEMPTS SMOKE_SLEEP SMOKE_CONSECUTIVE
set -uo pipefail
EXPECT_BUILD=${1:?usage: smoke-test.sh <expected-build> [<expected-commit>]}
EXPECT_COMMIT=${2:-}
URL=${SMOKE_URL:-http://localhost:8095}
SERVICE=${SERVICE:-cicd_app}
IMAGE=${IMAGE:-kaj1/cicd-demo}
ATTEMPTS=${SMOKE_ATTEMPTS:-60}; SLEEP=${SMOKE_SLEEP:-2}; NEED=${SMOKE_CONSECUTIVE:-10}

fail() { echo "SMOKE TEST FAILED: $1" >&2; exit 1; }

# http <path>: prints "<status> <body>"; status is 000 when nothing answered
http() {
  local out st body
  out=$(docker run --rm --network host busybox:1.36 wget -S -q -T 3 -O - "$URL$1" 2>&1) || true
  st=$(echo "$out" | grep -m1 -o 'HTTP/[0-9.]* [0-9]*' | awk '{print $2}')
  body=$(echo "$out" | grep -m1 '^{' || true)
  echo "${st:-000} $body"
}
field() { echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }

# 1. version
ok=0
for i in $(seq 1 "$ATTEMPTS"); do
  r=$(http /version); st=${r%% *}; body=${r#* }
  b=$(field "$body" build); c=$(field "$body" commit)
  if [ "$st" = 200 ] && [ "$b" = "$EXPECT_BUILD" ] && { [ -z "$EXPECT_COMMIT" ] || [ "$c" = "$EXPECT_COMMIT" ]; }; then
    ok=$((ok+1))
  else
    ok=0
  fi
  echo "attempt $i/$ATTEMPTS: HTTP $st build=${b:-none} commit=${c:-none} (consecutive matches $ok/$NEED)"
  [ "$ok" -ge "$NEED" ] && break
  sleep "$SLEEP"
done
[ "$ok" -ge "$NEED" ] || fail "/version did not report build $EXPECT_BUILD${EXPECT_COMMIT:+ commit $EXPECT_COMMIT} $NEED times in a row within $ATTEMPTS attempts (last: HTTP $st, build=${b:-none}, commit=${c:-none})"
echo "OK: /version reports build $EXPECT_BUILD${EXPECT_COMMIT:+ commit $EXPECT_COMMIT} $NEED times in a row"

# 2. health
r=$(http /health); st=${r%% *}
echo "/health -> HTTP $st ${r#* }"
[ "$st" = 200 ] || fail "/health returned HTTP $st"

# 3. optional functional check
if [ -n "${SMOKE_GREET_PATH:-}" ]; then
  r=$(http "$SMOKE_GREET_PATH"); st=${r%% *}; body=${r#* }
  echo "$SMOKE_GREET_PATH -> HTTP $st $body"
  [ "$st" = 200 ] || fail "$SMOKE_GREET_PATH returned HTTP $st"
  case "$body" in *"${SMOKE_GREET_EXPECT:-}"*) ;; *) fail "$SMOKE_GREET_PATH response does not contain '${SMOKE_GREET_EXPECT}'";; esac
fi

# 4. every replica runs the expected image
want=$(docker service inspect "$SERVICE" --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null) || fail "service $SERVICE not found"
have=0
for _ in $(seq 1 15); do
  have=$(docker service ps "$SERVICE" --filter desired-state=running --format '{{.CurrentState}} {{.Image}}' 2>/dev/null \
         | grep -cE "^Running .* ${IMAGE}:${EXPECT_BUILD}(@.*)?$" || true)
  [ "$have" = "$want" ] && break
  sleep 2
done
echo "replicas running ${IMAGE}:${EXPECT_BUILD}: $have of $want"
[ "$have" = "$want" ] || fail "only $have of $want replicas run ${IMAGE}:${EXPECT_BUILD}"

# 5. (optional) every replica runs exactly the image digest that was pushed
if [ -n "${EXPECT_DIGEST:-}" ]; then
  nd=$(docker service ps "$SERVICE" --filter desired-state=running --no-trunc --format '{{.Image}}' 2>/dev/null | grep -c "@${EXPECT_DIGEST}\$" || true)
  echo "replicas running digest ${EXPECT_DIGEST:0:19}...: $nd of $want"
  [ "$nd" = "$want" ] || fail "only $nd of $want replicas run the pushed digest ${EXPECT_DIGEST}"
fi

echo "SMOKE TEST PASSED: build $EXPECT_BUILD${EXPECT_COMMIT:+ (commit $EXPECT_COMMIT)} is serving on all $want replicas"
