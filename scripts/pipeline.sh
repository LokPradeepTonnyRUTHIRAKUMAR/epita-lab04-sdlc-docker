#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE_NAME="${1:-}"

if [[ -z "$IMAGE_NAME" ]]; then
  echo "Usage: $0 <image-name>"
  exit 1
fi

PROD_API_KEY="${PROD_API_KEY:-lab-secret}"
GATE_CONTAINER="citybike-gate"
GATE_URL="http://localhost:4174"
PROD_URL="http://localhost:4173"

cleanup_gate() {
  docker rm -f "$GATE_CONTAINER" >/dev/null 2>&1 || true
}

trap cleanup_gate EXIT

wait_for_health() {
  local url="$1"

  echo "Waiting for service health at ${url}/health..."

  for attempt in $(seq 1 30); do
    if curl -fsS "${url}/health" >/dev/null 2>&1; then
      echo "Service is healthy."
      return 0
    fi
    sleep 1
  done

  echo "FAIL: Service did not become healthy within 30 seconds."
  docker logs "$GATE_CONTAINER" 2>/dev/null || true
  return 1
}

run_gate() {
  local gate="$1"
  local environment="$2"
  local test_script="$3"
  shift 3

  echo ""
  echo "========================================"
  echo "Starting ${gate} gate"
  echo "========================================"

  cleanup_gate

  docker run -d \
    --name "$GATE_CONTAINER" \
    -p 4174:4173 \
    -e APP_ENV="$environment" \
    "$@" \
    "$IMAGE_NAME" >/dev/null

  wait_for_health "$GATE_URL"

  if [[ "$gate" == "PREPROD" ]]; then
    IMAGE_NAME="$IMAGE_NAME" \
    TARGET_URL="$GATE_URL" \
    PROD_API_KEY="$PROD_API_KEY" \
      "$test_script"
  else
    TARGET_URL="$GATE_URL" "$test_script"
  fi

  cleanup_gate
  echo "${gate} gate PASSED."
}

echo "Deploying image: $IMAGE_NAME"

run_gate "STAGING" "staging" "./scripts/test-staging.sh"
run_gate "UAT" "uat" "./scripts/test-uat.sh"
run_gate "OAT" "oat" "./scripts/test-oat.sh"
run_gate "PREPROD" "preprod" "./scripts/test-preprod.sh" \
  -e PROD_API_KEY="$PROD_API_KEY"

echo ""
echo "========================================"
echo "Starting PROD gate"
echo "========================================"

# Replace production only after all previous gates pass.
docker rm -f citybike-prod >/dev/null 2>&1 || true

docker run -d \
  --name citybike-prod \
  -p 4173:4173 \
  -e APP_ENV=production \
  -e PROD_API_KEY="$PROD_API_KEY" \
  "$IMAGE_NAME" >/dev/null

if ! wait_for_health "$PROD_URL"; then
  docker rm -f citybike-prod >/dev/null 2>&1 || true
  exit 1
fi

if ! TARGET_URL="$PROD_URL" ./scripts/test-prod.sh; then
  docker rm -f citybike-prod >/dev/null 2>&1 || true
  exit 1
fi

echo ""
echo "========================================"
echo "ALL FIVE GATES PASSED"
echo "Production is running at $PROD_URL"
echo "========================================"
