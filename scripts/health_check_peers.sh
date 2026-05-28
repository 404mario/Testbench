#!/bin/bash
# health_check_peers.sh — parallel SSH fabric health audit across all 18 NVL72 compute nodes.
#
# Reports per-IP: fabric.state Completed count, "not ready" GPUs, CliqueId match,
# any pending GPU Recovery Action, and dmesg knvlink/nvAssert count in last 5 min.
#
# Use BEFORE running any 72-GPU cluster collective. If any peer shows degraded fabric
# (not_ready > 0, recovery != None, or asserts > 0), STOP and triage that node first
# instead of launching tests that will hang or report misleading data.
#
# Usage: bash health_check_peers.sh [hostfile_or_IPs...]
#   default: uses scripts/hostfile.nvl72 IP list, expects clique id 32766

set -u

CLIQUE_EXPECTED="${CLIQUE_EXPECTED:-32766}"
HOSTFILE="${HOSTFILE:-$(dirname "$0")/hostfile.nvl72}"

if [ $# -gt 0 ]; then
  IPS="$*"
elif [ -f "$HOSTFILE" ]; then
  IPS=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print $1}' "$HOSTFILE")
else
  echo "ERROR: no hostfile at $HOSTFILE and no IPs given" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for ip in $IPS; do
  (
    out=$(timeout 15 ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
      "root@$ip" "
        completed=\$(timeout 5 nvidia-smi -q 2>/dev/null | grep -cE 'State.*Completed')
        not_ready=\$(timeout 5 nvidia-smi -q 2>/dev/null | grep -cE 'System is not in ready state')
        clique=\$(timeout 5 nvidia-smi -q 2>/dev/null | grep -cE 'CliqueId.*${CLIQUE_EXPECTED}')
        recovery=\$(timeout 5 nvidia-smi -q 2>/dev/null | grep -E 'Recovery Action' | grep -v 'None' | wc -l)
        assert=\$(dmesg -T --since '5 min ago' 2>/dev/null | grep -cE 'knvlink|nvAssert')
        echo \"\$completed \$not_ready \$clique \$recovery \$assert\"
      " 2>&1)
    echo "$ip $? $out" > "$TMP/$ip"
  ) &
done
wait

printf "%-16s %3s %10s %10s %7s %14s %14s\n" "IP" "rc" "completed" "not_ready" "clique" "recovery!=None" "asserts/5min"
printf "%-16s %3s %10s %10s %7s %14s %14s\n" "----" "--" "---------" "---------" "------" "--------------" "------------"

unhealthy=0
for f in "$TMP"/*; do
  data=$(cat "$f")
  ip=$(echo "$data" | awk '{print $1}')
  rc=$(echo "$data" | awk '{print $2}')
  rest=$(echo "$data" | cut -d' ' -f3-)
  if [ "$rc" = "0" ] && [ "$(echo $rest | wc -w)" = "5" ]; then
    set -- $rest
    completed=$1; not_ready=$2; clique=$3; recovery=$4; assert=$5
    printf "%-16s %3s %10s %10s %7s %14s %14s\n" "$ip" "$rc" "$completed" "$not_ready" "$clique" "$recovery" "$assert"
    if [ "$completed" -lt 4 ] || [ "$not_ready" -gt 0 ] || [ "$clique" -lt 4 ] || [ "$recovery" -gt 0 ] || [ "$assert" -gt 0 ]; then
      unhealthy=$((unhealthy+1))
    fi
  else
    printf "%-16s %3s  UNREACHABLE/ERR: %s\n" "$ip" "$rc" "$(echo $rest | cut -c1-60)"
    unhealthy=$((unhealthy+1))
  fi
done | sort

echo ""
if [ "$unhealthy" -eq 0 ]; then
  echo "ALL HEALTHY — safe to launch 72-GPU cluster tests."
  exit 0
else
  echo "WARN: $unhealthy node(s) degraded — investigate before running cluster tests."
  echo "See: docs/runbooks/driver-topology-cache-fix.md"
  exit 1
fi
