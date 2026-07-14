#!/usr/bin/env bash
# Bounded per-instance CPU/mem poller for a fleet nginx target, invoked by
# the bench client over SSH for the duration of a run:
#
#   target-stats.sh <conf_match> <seconds>
#
# <conf_match> uniquely identifies one nginx instance by (a substring of)
# its config path, e.g. "nginx-pqc/nginx.conf". Matching the conf path
# rather than port or process name guarantees we isolate the intended
# instance and can't accidentally sum in the other one running on the same
# host. Prints one CSV line per second, in the exact
#   CPU%,MEMMB / TOTALMB
# shape that summarize-traffic-mix.sh (and summarize.sh) parse, then exits after
# <seconds> samples. The client captures stdout in a single SSH call, so
# there is no background poller PID to manage remotely.
#
# CPU% is a true per-interval measurement: the delta of utime+stime
# jiffies across the instance's master + worker processes over each 1s
# window, normalized to one core. Unlike ps's %cpu (a lifetime
# cputime/realtime average that a long-running, mostly-idle nginx would
# dilute), this reflects load *during* the benchmark. A saturated 4-vCPU
# host reads ~400%, matching how `docker stats` reports the container path.
set -euo pipefail

conf_match=${1:?usage: target-stats.sh <conf_match> <seconds>}
samples=${2:?usage: target-stats.sh <conf_match> <seconds>}

clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
host_total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)

# Master PID for the matching instance, plus its direct children (workers).
master=$(pgrep -f "nginx: master process.*${conf_match}" | head -n1 || true)
if [ -z "$master" ]; then
  echo "error: no nginx master process matching '${conf_match}'" >&2
  exit 1
fi
workers=$(pgrep -P "$master" 2>/dev/null | paste -sd' ' - || true)
# shellcheck disable=SC2206  # deliberate word-split of the space list
pids=($master $workers)
pids_csv=$(IFS=,; echo "${pids[*]}")

# Sum of utime+stime (jiffies) across all target pids, right now. The comm
# field (2) of /proc/<pid>/stat can contain spaces and parens, so strip
# everything up to and including the last ") " before splitting; after
# that, field 12 is utime (stat field 14) and field 13 is stime (15).
cpu_jiffies() {
  local total=0 pid j
  for pid in "${pids[@]}"; do
    [ -r "/proc/$pid/stat" ] || continue
    j=$(awk '{ s=$0; sub(/^.*\) /,"",s); split(s,f," "); print f[12]+f[13] }' "/proc/$pid/stat")
    total=$((total + j))
  done
  echo "$total"
}

prev=$(cpu_jiffies)
for _ in $(seq 1 "$samples"); do
  sleep 1
  cur=$(cpu_jiffies)
  delta=$((cur - prev))
  prev=$cur

  cpu=$(awk -v d="$delta" -v hz="$clk_tck" 'BEGIN { printf "%.1f", (d * 100.0) / hz }')
  rss_mb=$(ps -o rss= -p "$pids_csv" 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
  echo "${cpu:-0.0}%,${rss_mb:-0}MB / ${host_total_mb}MB"
done
