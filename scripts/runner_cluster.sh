#!/bin/bash
# runner_cluster.sh - 72-GPU (or N-node) cluster-mode runner.
#
# This is the launcher for tightly-coupled MPI workloads: ONE mpirun on the
# launcher node coordinates all 72 ranks across 18 nodes. Fundamentally
# different from runner_per_node.sh (which runs same test N times independently).
#
# Usage: runner_cluster.sh <tool> [-- mpi_test_args]
#   tool: all_reduce | alltoall | all_gather | broadcast | reduce | reduce_scatter | sendrecv
#   default test args: -b 8 -e 1G -f 2 -g 1

set -e
TOOL=$1; shift || true
[ "$1" = "--" ] && shift

# defaults: power-of-2 sweep 8B -> 1GiB, 1 GPU per rank
ARGS=("$@")
[ ${#ARGS[@]} -eq 0 ] && ARGS=(-b 8 -e 1G -f 2 -g 1)

# Load env (PATH, NCCL_*, UCX_*, BUNDLE_ROOT)
source "$(dirname "$0")/env.sh"

BIN="$BUNDLE_ROOT/bin/mpi/${TOOL}_perf_mpi"
HOSTFILE="$BUNDLE_ROOT/scripts/hostfile.nvl72"
[ -x "$BIN" ] || { echo "binary not found: $BIN" >&2; exit 2; }
[ -f "$HOSTFILE" ] || { echo "hostfile not found: $HOSTFILE" >&2; exit 3; }

# Total ranks = (lines in hostfile) * (slots per line). Assumes uniform slots.
NP=$(awk '{
  for (i=1;i<=NF;i++) if ($i~/^slots=/) { sub("slots=","",$i); s=$i }
  total += (s ? s : 1)
} END {print total}' "$HOSTFILE")

OUT_DIR="$BUNDLE_ROOT/results_${NP}gpu"
mkdir -p "$OUT_DIR"
OUT_LOG="$OUT_DIR/${TOOL}.log"

echo ">>> ${TOOL}_perf_mpi -np ${NP} | hostfile=$(basename "$HOSTFILE") | args=${ARGS[*]}"
echo ">>> log: $OUT_LOG"

mpirun -np "$NP" \
  --hostfile "$HOSTFILE" \
  --allow-run-as-root \
  --mca plm_rsh_args "-o StrictHostKeyChecking=accept-new" \
  -x LD_LIBRARY_PATH \
  -x UCX_TLS \
  -x UCX_NET_DEVICES \
  -x NCCL_SOCKET_IFNAME \
  -x NCCL_DEBUG \
  "$BIN" "${ARGS[@]}" 2>&1 | tee "$OUT_LOG"

# Summary line
peak=$(awk '/^ *[0-9]/ {if ($7+0 > max) max=$7+0} END {printf "%.2f", max}' "$OUT_LOG")
wrong=$(grep -E 'Out of bounds' "$OUT_LOG" | awk '{print $7}')
echo ">>> SUMMARY  ${TOOL}_perf_mpi @ ${NP} GPU:  peak busbw = ${peak} GB/s   #wrong = ${wrong:-?}"
