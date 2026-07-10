#!/usr/bin/env bash
# Bare-metal analog of scripts/run-benchmark.sh (repo root) for a native
# Rocky Linux 9 deployment - no containers, so no `docker/podman stats`.
# nginx-pqc and nginx-classic run continuously as systemd services (same
# as the two containers run continuously in the compose setup), so each
# scenario's CPU/mem poller must isolate the target instance's own
# master+worker processes rather than summing across both instances.
#
# Usage: ./run-benchmark.sh   (run this on the VM, as installed by
# ansible's playbook.yml at /opt/nginx-pqc-perf-test/run-benchmark.sh)
set -euo pipefail

cd "$(dirname "$0")"

DURATION="${BENCH_DURATION:-30s}"
CONNS="${BENCH_CONNS:-20}"
RESULTS_DIR="$(pwd)/results"
BENCH="$(pwd)/bench/bench"

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json "$RESULTS_DIR"/*.log "$RESULTS_DIR"/summary.md

for svc in nginx-pqc nginx-classic; do
  if ! systemctl is-active --quiet "$svc"; then
    echo "error: $svc is not running (systemctl status $svc)" >&2
    exit 1
  fi
done

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

echo "==> verifying nginx-pqc negotiates X25519MLKEM768"
if ! (echo | openssl s_client -connect localhost:8443 -groups X25519MLKEM768 -brief 2>&1) \
    | grep -q "Negotiated TLS1.3 group: X25519MLKEM768"; then
  echo "error: nginx-pqc did not negotiate X25519MLKEM768" >&2
  exit 1
fi
echo "    confirmed"

echo "==> verifying nginx-classic rejects an X25519MLKEM768-only offer"
if (echo | openssl s_client -connect localhost:9443 -groups X25519MLKEM768 2>&1) \
    | grep -q "Negotiated TLS1.3 group"; then
  echo "error: nginx-classic unexpectedly accepted X25519MLKEM768" >&2
  exit 1
fi
echo "    confirmed"

host_total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)

# Resolves the master PID for the instance whose conf path contains
# $1 (e.g. "nginx-pqc/nginx.conf"), then its direct children (nginx's
# worker processes) - matches conf path rather than port/name so it
# can't accidentally pick up the *other* instance.
target_pids() {
  local conf_match=$1
  local master
  master="$(pgrep -f "nginx: master process.*${conf_match}" | head -n1)"
  if [ -z "$master" ]; then
    echo "error: could not find nginx master process matching ${conf_match}" >&2
    return 1
  fi
  local workers
  workers="$(pgrep -P "$master" | paste -sd, -)"
  if [ -n "$workers" ]; then
    echo "${master},${workers}"
  else
    echo "$master"
  fi
}

run_scenario() {
  local name=$1 target=$2 pqc=$3 conf_match=$4
  echo "==> $name: handshake against $target ($CONNS conns, $DURATION)"

  local pids
  pids="$(target_pids "$conf_match")"

  local stats_log="$RESULTS_DIR/$name-stats.log"
  (
    while true; do
      # Sum %cpu and rss (KB) across master+workers, format to match
      # scripts/summarize.sh's expected "CPU%,MEM / MEM" CSV shape.
      read -r cpu_sum rss_sum < <(ps -o %cpu=,rss= -p "$pids" 2>/dev/null \
        | awk '{cpu+=$1; rss+=$2} END {printf "%.1f %.0f\n", cpu, rss/1024}')
      echo "${cpu_sum:-0.0}%,${rss_sum:-0}MB / ${host_total_mb}MB" >> "$stats_log"
      sleep 1
    done
  ) &
  local poller=$!

  "$BENCH" -addr "$target" -pqc="$pqc" -conns "$CONNS" \
    -duration "$DURATION" -scenario "$name" \
    -out "$RESULTS_DIR/$name.json"

  kill "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true
}

run_scenario pqc-handshake     localhost:8443 true  "nginx-pqc/nginx.conf"
run_scenario classic-handshake localhost:9443 false "nginx-classic/nginx.conf"

echo "==> summarizing results"
./summarize.sh "$RESULTS_DIR" | tee "$RESULTS_DIR/summary.md"

echo "==> done. Results in $RESULTS_DIR/"
