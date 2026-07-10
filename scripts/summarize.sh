#!/usr/bin/env bash
# Renders results/*.json + results/*-stats.log produced by
# run-benchmark.sh into a markdown comparison table. Requires jq.
set -euo pipefail

DIR="${1:-results}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to summarize results (raw JSON is still in $DIR/*.json)" >&2
  exit 1
fi

field() { # field <json-file> <jq-expr> -> value or "n/a"
  local f="$1" expr="$2"
  if [ -f "$f" ]; then
    jq -r "$expr // \"n/a\"" "$f"
  else
    echo "n/a"
  fi
}

avg_cpu() { # avg_cpu <stats-log> -> "12.3%" or "n/a"
  local f="$1"
  [ -f "$f" ] || { echo "n/a"; return; }
  # Note: numeric check is a regex match, not "$1+0==$1" - gsub() clears
  # awk's STRNUM flag on the field, and $1+0==$1 then falls back to a
  # string comparison that spuriously fails for values like "3.0" (whose
  # number->string round-trip is "3", not "3.0").
  awk -F',' '{gsub("%","",$1); if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) {sum+=$1; n++}} END {if (n>0) printf "%.1f%%", sum/n; else print "n/a"}' "$f"
}

last_mem() { # last_mem <stats-log> -> "12.3MB" or "n/a"
  local f="$1"
  [ -f "$f" ] || { echo "n/a"; return; }
  tail -n1 "$f" | awk -F',' '{print $2}' | awk -F' / ' '{print $1}'
  [ -s "$f" ] || echo "n/a"
}

# params_line prints a one-line summary of the run parameters (concurrent
# connections + duration), read from whichever result JSON exists. The
# bench tool records these identically for every scenario in a run, so one
# line above the table covers them all.
params_line() {
  local f
  f="$(ls "$DIR"/*-handshake.json 2>/dev/null | head -n1)"
  [ -n "$f" ] || { echo "_Run parameters unavailable._"; return; }
  local conns dur
  conns="$(jq -r '.connections // "n/a"' "$f")"
  dur="$(jq -r '.duration_s // "n/a"' "$f" \
    | awk '{if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) {if ($1==int($1)) printf "%ds",$1; else printf "%.1fs",$1} else print $1}')"
  printf '_Run parameters: %s concurrent connections, %s duration (per scenario)._\n' "$conns" "$dur"
}

row_handshake() {
  local name=$1 label=$2
  local j="$DIR/$name.json" s="$DIR/$name-stats.log"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$label" \
    "$(field "$j" .tls_group)" \
    "$(field "$j" .handshakes_per_sec | awk '{printf "%.0f", $1}')" \
    "$(field "$j" .p50_ms)" "$(field "$j" .p95_ms)" "$(field "$j" .p99_ms)" \
    "$(field "$j" .errors)" \
    "$(avg_cpu "$s")" "$(last_mem "$s")"
}

echo "# NGINX PQC vs ECDHE Handshake Benchmark Results"
echo
params_line
cat <<'EOF'

| Scenario | TLS Group | Handshakes/sec | p50 (ms) | p95 (ms) | p99 (ms) | Errors | Avg CPU | Mem (last sample) |
|---|---|---|---|---|---|---|---|---|
EOF
row_handshake pqc-handshake     "PQC (X25519MLKEM768)"
row_handshake classic-handshake "Classic (X25519)"
