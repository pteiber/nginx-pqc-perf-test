#!/usr/bin/env bash
# Fleet consolidation runner. Runs on the bench client, benchmarks every
# nginx target listed in targets.env over the network, and consolidates
# all results into one comparison table (results/summary.md).
#
# For each target and each scenario (PQC on 8443, classic on 9443) it:
#   1. opens one SSH call to the target that runs target-stats.sh for the
#      run's duration, capturing per-second CPU/mem on stdout, and
#   2. runs the local bench tool against the target's private IP,
# so the target's own nginx CPU/mem is measured during exactly the window
# the client is hammering it. Handshake rate + latency come straight from
# the local bench tool.
#
# Usage (on the client): ./run-fleet-benchmark.sh
# Tune with BENCH_DURATION (default 30s) and BENCH_CONNS (default 20),
# matching the container and single-host paths.
set -euo pipefail

cd "$(dirname "$0")"

DURATION="${BENCH_DURATION:-30s}"
CONNS="${BENCH_CONNS:-20}"
RESULTS_DIR="$(pwd)/results"
BENCH="$(pwd)/bench/bench"
KEY="$(pwd)/ssh_key.pem"
TARGETS_FILE="$(pwd)/targets.env"
REMOTE_DEPLOY=/opt/nginx-pqc-perf-test
TARGET_USER=rocky

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)

# bench takes a Go duration string; the remote poller takes an integer
# sample count. Convert "30s" / "2m" / "45" -> seconds for the poller.
to_seconds() {
  local d=$1
  case "$d" in
  *m) echo $(( ${d%m} * 60 )) ;;
  *s) echo "${d%s}" ;;
  *) echo "$d" ;;
  esac
}
DURATION_SECS="$(to_seconds "$DURATION")"

[ -x "$BENCH" ] || { echo "error: bench binary not found at $BENCH (was the client provisioned?)" >&2; exit 1; }
[ -f "$TARGETS_FILE" ] || { echo "error: $TARGETS_FILE not found" >&2; exit 1; }

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.log "$RESULTS_DIR"/summary.md

wait_for() {
  local host=$1 port=$2 name=$3
  for _ in $(seq 1 30); do
    if [ "$(curl -sk -o /dev/null -w '%{http_code}' "https://$host:$port/small" 2>/dev/null)" = "200" ]; then
      echo "    $name ($host:$port) is ready"
      return 0
    fi
    sleep 1
  done
  echo "error: $name ($host:$port) did not become ready in time" >&2
  return 1
}

run_scenario() {
  local label=$1 host=$2 port=$3 pqc=$4 conf_match=$5
  local json="$RESULTS_DIR/$label-handshake.json"
  local stats_log="$RESULTS_DIR/$label-handshake-stats.log"

  echo "==> $label: handshake against $host:$port ($CONNS conns, $DURATION)"

  # Start the remote CPU/mem poller for the run's duration; its stdout is
  # the stats log. No sudo needed: /proc and ps of the nginx processes are
  # world-readable.
  ssh "${SSH_OPTS[@]}" "$TARGET_USER@$host" \
    "$REMOTE_DEPLOY/target-stats.sh '$conf_match' $DURATION_SECS" \
    > "$stats_log" 2>/dev/null &
  local poller=$!

  "$BENCH" -addr "$host:$port" -pqc="$pqc" -conns "$CONNS" \
    -duration "$DURATION" -scenario "$label-handshake" -out "$json"

  wait "$poller" 2>/dev/null || true
}

while read -r name priv_ip itype arch; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac

  echo "==> target '$name' ($itype, $arch) at $priv_ip"
  wait_for "$priv_ip" 8443 "$name nginx-pqc"
  wait_for "$priv_ip" 9443 "$name nginx-classic"

  run_scenario "$name-pqc"     "$priv_ip" 8443 true  "nginx-pqc/nginx.conf"
  run_scenario "$name-classic" "$priv_ip" 9443 false "nginx-classic/nginx.conf"
done < "$TARGETS_FILE"

echo "==> consolidating results"
./summarize-fleet.sh "$RESULTS_DIR" | tee "$RESULTS_DIR/summary.md"

echo "==> done. Results in $RESULTS_DIR/"
