#!/usr/bin/env bash
# Builds and runs the PQC-vs-classical nginx handshake benchmark: starts
# both nginx targets, confirms each negotiates the TLS group it's
# supposed to, runs the bench tool against both, collects CPU/memory via
# `stats`, and writes results/*.json plus results/summary.md.
#
# Requires: podman or docker (with Compose support), and curl on the host
# for readiness checks. See README.md for prerequisites and how to read
# the results.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=pqcbench
DURATION="${BENCH_DURATION:-30s}"
CONNS="${BENCH_CONNS:-20}"
RESULTS_DIR="$(pwd)/results"

# --- engine / compose detection -------------------------------------------
if command -v podman >/dev/null 2>&1; then
  ENGINE=podman
elif command -v docker >/dev/null 2>&1; then
  ENGINE=docker
else
  echo "error: podman or docker is required" >&2
  exit 1
fi

if $ENGINE compose version >/dev/null 2>&1; then
  COMPOSE=("$ENGINE" compose -p "$PROJECT")
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE=(podman-compose -p "$PROJECT")
else
  echo "error: no compose provider found (need '$ENGINE compose' or podman-compose)" >&2
  exit 1
fi

echo "==> engine: $ENGINE, compose: ${COMPOSE[*]}"

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.log "$RESULTS_DIR"/summary.md

cleanup() {
  echo "==> tearing down"
  "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- bring up the environment -----------------------------------------------
echo "==> starting nginx-pqc, nginx-classic (certs generated automatically)"
"${COMPOSE[@]}" up -d --build

wait_for() {
  local url=$1 name=$2
  for _ in $(seq 1 30); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" = "200" ]; then
      echo "    $name is ready"
      return 0
    fi
    sleep 1
  done
  echo "error: $name did not become ready in time" >&2
  exit 1
}

echo "==> waiting for targets to accept connections"
wait_for https://localhost:8443/small "nginx-pqc"
wait_for https://localhost:9443/small "nginx-classic"

# --- sanity-check negotiated TLS groups -------------------------------------
echo "==> verifying nginx-pqc negotiates X25519MLKEM768"
if ! "${COMPOSE[@]}" run --rm -T --no-deps --entrypoint openssl nginx-pqc \
    s_client -connect nginx-pqc:443 -groups X25519MLKEM768 -brief </dev/null 2>&1 \
    | grep -q "Negotiated TLS1.3 group: X25519MLKEM768"; then
  echo "error: nginx-pqc did not negotiate X25519MLKEM768 - check nginx/pqc/nginx.conf" >&2
  exit 1
fi
echo "    confirmed"

echo "==> verifying nginx-classic rejects an X25519MLKEM768-only offer"
if "${COMPOSE[@]}" run --rm -T --no-deps --entrypoint openssl nginx-classic \
    s_client -connect nginx-classic:443 -groups X25519MLKEM768 -brief </dev/null >/dev/null 2>&1; then
  echo "error: nginx-classic unexpectedly accepted X25519MLKEM768 - check nginx/classic/nginx.conf" >&2
  exit 1
fi
echo "    confirmed"

# --- run scenarios -----------------------------------------------------------
container_id() {
  $ENGINE ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1"
}

run_scenario() {
  local name=$1 target=$2 pqc=$3 svc=$4
  echo "==> $name: handshake against $target ($CONNS conns, $DURATION)"

  local stats_log="$RESULTS_DIR/$name-stats.log"
  local cid
  cid="$(container_id "$svc")"
  (
    while true; do
      $ENGINE stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}}' "$cid" >> "$stats_log" 2>/dev/null
      sleep 1
    done
  ) &
  local poller=$!

  "${COMPOSE[@]}" run --rm -T --no-deps bench \
    -addr "$target" -pqc="$pqc" -conns "$CONNS" \
    -duration "$DURATION" -scenario "$name" \
    -out "/results/$name.json"

  kill "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true
}

run_scenario pqc-handshake     nginx-pqc:443     true  nginx-pqc
run_scenario classic-handshake nginx-classic:443 false nginx-classic

# --- summarize ---------------------------------------------------------------
echo "==> summarizing results"
scripts/summarize.sh "$RESULTS_DIR" | tee "$RESULTS_DIR/summary.md"

echo "==> done. Results in $RESULTS_DIR/"
