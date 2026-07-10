#!/usr/bin/env bash
# Consolidates the per-target JSON + stats logs produced by
# run-fleet-benchmark.sh into a single markdown table with one row per
# (host, scenario), so a variety of hosts and instance types can be
# compared side by side. Requires jq.
#
# This is the fleet analog of scripts/summarize.sh, which is left
# untouched (it hard-codes the single-host two-row table and is reused
# verbatim by the container and single-host paths). The per-file helpers
# below mirror it, including the STRNUM/regex awk gotcha.
set -euo pipefail

DIR="${1:-results}"
# targets.env lives one level up from results/ (deploy_root/targets.env);
# it maps host name -> instance type + architecture for the table.
TARGETS_FILE="${TARGETS_FILE:-$DIR/../targets.env}"

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
  # Numeric check is a regex match, not "$1+0==$1": gsub() clears awk's
  # STRNUM flag on the field, and $1+0==$1 then falls back to a string
  # comparison that spuriously fails for values like "3.0".
  awk -F',' '{gsub("%","",$1); if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) {sum+=$1; n++}} END {if (n>0) printf "%.1f%%", sum/n; else print "n/a"}' "$f"
}

last_mem() { # last_mem <stats-log> -> "12.3MB" or "n/a"
  local f="$1"
  [ -f "$f" ] || { echo "n/a"; return; }
  [ -s "$f" ] || { echo "n/a"; return; }
  tail -n1 "$f" | awk -F',' '{print $2}' | awk -F' / ' '{print $1}'
}

# params_line prints a one-line summary of the run parameters (concurrent
# connections + duration), read from whichever result JSON exists. The bench
# tool records these identically for every host+scenario in a run.
params_line() {
  local f
  f="$(ls "$DIR"/*-handshake.json 2>/dev/null | head -n1)"
  [ -n "$f" ] || { echo "_Run parameters unavailable._"; return; }
  local conns dur
  conns="$(jq -r '.connections // "n/a"' "$f")"
  dur="$(jq -r '.duration_s // "n/a"' "$f" \
    | awk '{if ($1 ~ /^[0-9]+(\.[0-9]+)?$/) {if ($1==int($1)) printf "%ds",$1; else printf "%.1fs",$1} else print $1}')"
  printf '_Run parameters: %s concurrent connections, %s duration (per host+scenario)._\n' "$conns" "$dur"
}

# host_meta <name> -> "instance_type arch" (or "n/a n/a"), read from targets.env
host_meta() {
  local name="$1"
  if [ -f "$TARGETS_FILE" ]; then
    awk -v n="$name" '$1==n {print $3, $4; found=1} END {if (!found) print "n/a n/a"}' "$TARGETS_FILE"
  else
    echo "n/a n/a"
  fi
}

emit_row() {
  local name=$1 variant=$2 label
  label="$name-$variant"
  local j="$DIR/$label-handshake.json" s="$DIR/$label-handshake-stats.log"
  [ -f "$j" ] || return 0
  local meta itype arch
  meta="$(host_meta "$name")"
  itype="${meta% *}"; arch="${meta#* }"
  local scen; [ "$variant" = pqc ] && scen="PQC" || scen="Classic"
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$name" "$itype" "$arch" "$scen" \
    "$(field "$j" .tls_group)" \
    "$(field "$j" .handshakes_per_sec | awk '{printf "%.0f", $1}')" \
    "$(field "$j" .p50_ms)" "$(field "$j" .p95_ms)" "$(field "$j" .p99_ms)" \
    "$(field "$j" .errors)" \
    "$(avg_cpu "$s")/$(last_mem "$s")"
}

# Ordered list of host names: prefer targets.env order; else derive from
# the result filenames.
hosts() {
  if [ -f "$TARGETS_FILE" ]; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$TARGETS_FILE"
  else
    for f in "$DIR"/*-pqc-handshake.json; do
      [ -e "$f" ] || continue
      local b; b="$(basename "$f")"; echo "${b%-pqc-handshake.json}"
    done
  fi
}

cat <<'EOF'
# NGINX PQC vs ECDHE Handshake Benchmark: fleet results

Handshake rate and latency are measured by the bench client over the
intra-VPC network; Avg CPU / Mem are the target's own nginx master+worker
usage during the run. Compare PQC vs Classic within a host, and hosts
against each other by handshakes/sec and CPU.
EOF
echo
params_line
cat <<'EOF'

| Host | Instance type | Arch | Scenario | TLS Group | Handshakes/sec | p50 (ms) | p95 (ms) | p99 (ms) | Errors | CPU / Mem |
|---|---|---|---|---|---|---|---|---|---|---|
EOF

while read -r name; do
  [ -z "${name:-}" ] && continue
  emit_row "$name" pqc
  emit_row "$name" classic
done < <(hosts)
