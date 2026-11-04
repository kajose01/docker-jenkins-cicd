#!/usr/bin/env bash
# Restore the previous release after a failed deployment, then verify it is really serving.
# Usage: scripts/rollback.sh <previous-image-reference>     e.g. kaj1/cicd-demo:6@sha256:...
# Safe to run when Swarm has already rolled back: updating to the image the service already runs changes nothing.
# (Do not use "docker service rollback" here: after a Swarm automatic rollback it would re-apply the bad release.)
set -uo pipefail
PREV=${1:-}
SERVICE=${SERVICE:-cicd_app}
HERE=$(dirname "$0")

fail() { echo "ROLLBACK FAILED: $1" >&2; exit 1; }
[ -n "$PREV" ] || fail "no previous image was recorded (first deployment?), nothing to restore"

PREV_TAG=${PREV#*:}; PREV_TAG=${PREV_TAG%%@*}
echo "Rolling $SERVICE back to $PREV (build $PREV_TAG)"
echo "--- service tasks before rollback"
docker service ps "$SERVICE" | head -8

docker service update --quiet --image "$PREV" "$SERVICE" >/dev/null || fail "docker service update to $PREV failed"

echo "--- verifying the restored release"
SMOKE_CONSECUTIVE=${SMOKE_CONSECUTIVE:-5} bash "$HERE/smoke-test.sh" "$PREV_TAG" "" || fail "previous release (build $PREV_TAG) is not serving after rollback"

echo "--- service tasks after rollback"
docker service ps "$SERVICE" | head -8
echo "ROLLBACK OK: build $PREV_TAG is serving again"
