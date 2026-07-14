#!/usr/bin/env bash
# Traffic-mix runner. Runs on the client, drives a realistic mixed
# workload against every nginx target listed in targets.env over the
# network, and consolidates all results into one table (results/summary.md).
#
# The workload has four independent knobs (all env vars, see below): an
# HTTP request rate over a warm keep-alive pool, a new-connection TLS
# handshake rate, the percentage of those handshakes that resume a TLS 1.3
# session, and a random response-size range. This is the counterpart to
# the handshake-only aws/fleet/ runner.
#
# For each target and each scenario (PQC on 8443, classic on 9443) it:
#   1. opens one SSH call to the target that runs target-stats.sh for the
#      run's duration, capturing per-second CPU/mem on stdout, and
#   2. runs the local trafficmix tool against the target's private IP,
# so the target's own nginx CPU/mem is measured during exactly the window
# the client is loading it.
#
# Usage (on the client): ./run-traffic-mix-benchmark.sh
# Tune with these env vars (defaults in parentheses):
#   BENCH_DURATION        (30s)   run length per target+scenario
#   BENCH_RPS             (200)   HTTP request rate over the keep-alive pool
#   BENCH_HANDSHAKE_RATE  (50)    new TLS connections per second
#   BENCH_RESUME_PCT      (50)    percent of those handshakes that resume
#   BENCH_MIN_BYTES       (1024)  min response body size
#   BENCH_MAX_BYTES       (65536) max response body size (<= payload.bin)
#   BENCH_CONNS           (50)    warm keep-alive pool size
#   BENCH_HANDSHAKE_CONNS (50)    handshake-churn worker pool size
set -euo pipefail

cd "$(dirname "$0")"

DURATION="${BENCH_DURATION:-30s}"
RPS="${BENCH_RPS:-200}"
HANDSHAKE_RATE="${BENCH_HANDSHAKE_RATE:-50}"
RESUME_PCT="${BENCH_RESUME_PCT:-50}"
MIN_BYTES="${BENCH_MIN_BYTES:-1024}"
MAX_BYTES="${BENCH_MAX_BYTES:-65536}"
CONNS="${BENCH_CONNS:-50}"
HANDSHAKE_CONNS="${BENCH_HANDSHAKE_CONNS:-50}"

RESULTS_DIR="$(pwd)/results"
TRAFFICMIX="$(pwd)/trafficmix/trafficmix"
KEY="$(pwd)/ssh_key.pem"
TARGETS_FILE="$(pwd)/targets.env"
REMOTE_DEPLOY=/opt/nginx-pqc-perf-test
TARGET_USER=rocky

# -n redirects ssh's stdin from /dev/null. This is load-bearing: the poller
# ssh is backgrounded inside the `while read ... done < targets.env` loop and
# would otherwise inherit the loop's stdin and slurp the remaining target
# lines, so only the first target would ever run.
SSH_OPTS=(-n -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)

# trafficmix takes a Go duration string; the remote poller takes an integer
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

[ -x "$TRAFFICMIX" ] || { echo "error: trafficmix binary not found at $TRAFFICMIX (was the client provisioned?)" >&2; exit 1; }
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
  local json="$RESULTS_DIR/$label.json"
  local stats_log="$RESULTS_DIR/$label-stats.log"

  echo "==> $label: traffic-mix against $host:$port"
  echo "    rps=$RPS handshake-rate=$HANDSHAKE_RATE resume-pct=$RESUME_PCT bytes=$MIN_BYTES-$MAX_BYTES for $DURATION"

  # Start the remote CPU/mem poller for the run's duration; its stdout is
  # the stats log. No sudo needed: /proc and ps of the nginx processes are
  # world-readable.
  ssh "${SSH_OPTS[@]}" "$TARGET_USER@$host" \
    "$REMOTE_DEPLOY/target-stats.sh '$conf_match' $DURATION_SECS" \
    > "$stats_log" 2>/dev/null &
  local poller=$!

  "$TRAFFICMIX" -addr "$host:$port" -pqc="$pqc" \
    -duration "$DURATION" -rps "$RPS" -handshake-rate "$HANDSHAKE_RATE" \
    -resume-pct "$RESUME_PCT" -min-bytes "$MIN_BYTES" -max-bytes "$MAX_BYTES" \
    -connections "$CONNS" -handshake-conns "$HANDSHAKE_CONNS" \
    -scenario "$label" -out "$json"

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
./summarize-traffic-mix.sh "$RESULTS_DIR" | tee "$RESULTS_DIR/summary.md"

echo "==> done. Results in $RESULTS_DIR/"
