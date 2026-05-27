#!/bin/bash
# setup.sh — first-run bootstrap on a freshly imaged NVL72 testbench.
# Idempotent: safe to re-run.
#
# What it does (in order):
#   1. Verify SSH passwordless any-to-any (assumes [[ project-nvl72-ssh ]] already done)
#   2. Create IMEX channel0 dev nodes on every host that's missing one
#   3. Distribute the bundle to /root/bench-bundle/ on the 17 remote nodes
#
# Run on the launcher node (e.g. pega) AFTER:
#   - ssh keys are shared across all 18 nodes (see docs/one-click.md)
#   - the bundle is unpacked at /root/bench-bundle/

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ROOT="$(dirname "$SCRIPT_DIR")"
HOSTFILE="$SCRIPT_DIR/hostfile.nvl72"

[ -f "$HOSTFILE" ] || { echo "hostfile not found: $HOSTFILE" >&2; exit 1; }
IPS=$(awk '{print $1}' "$HOSTFILE")

echo "===== 1/3 verify SSH passwordless to all nodes ====="
fail=0
for ip in $IPS; do
  ssh -o BatchMode=yes -o ConnectTimeout=4 root@"$ip" 'true' 2>/dev/null \
    && printf '  %-15s OK\n' "$ip" \
    || { printf '  %-15s FAIL\n' "$ip"; fail=$((fail+1)); }
done
[ "$fail" -gt 0 ] && { echo "SSH not ready on $fail node(s); fix that first." >&2; exit 2; }

echo "===== 2/3 fix IMEX channel0 device on all nodes ====="
"$SCRIPT_DIR/fix_imex_channels.sh" "$HOSTFILE"

echo "===== 3/3 distribute bundle to remote nodes ====="
LAUNCHER_IP=$(hostname -I | awk '{print $1}')
for ip in $IPS; do
  if [ "$ip" = "$LAUNCHER_IP" ]; then
    printf '  %-15s skip (launcher)\n' "$ip"; continue
  fi
  rsync -aq --delete "$BUNDLE_ROOT/" root@"$ip":/root/bench-bundle/ \
    && printf '  %-15s OK\n' "$ip" \
    || printf '  %-15s FAIL\n' "$ip"
done

echo
echo "===== ready ====="
echo "  Single-node:   $SCRIPT_DIR/run_parallel_test.sh stream localhost"
echo "  All 18 nodes:  $SCRIPT_DIR/run_parallel_test.sh nvbandwidth all"
echo "  72-GPU NCCL:   $SCRIPT_DIR/run_parallel_test.sh --mode=72gpu all_reduce"
