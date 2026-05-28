#!/bin/bash
# run_72gpu_full.sh — full 72-GPU NVL72 acceptance test.
#
# Runs:
#   1. Health check on all 18 peer nodes (aborts if any degraded)
#   2. Per-node: bench_gemm (6 dtypes), stream (4 ops), nvbandwidth (NVLink + Grace-C2C)
#      — fanned out in parallel across all 18 nodes via SSH
#   3. Cluster: 7 NCCL collectives at 72 ranks via single mpirun
#   4. Aggregation + report.md generation
#
# Total wall time: ~12-15 min when fabric is healthy.
#
# Output: $BUNDLE_ROOT/results_72gpu/<YYYY-MM-DD>/
#   per_node/<ip>/{gemm_*.log,stream.log,nvbandwidth.log,*_result.json}
#   cluster/{all_reduce,alltoall,all_gather,broadcast,reduce,reduce_scatter,sendrecv}.log
#   aggregated.json
#   report.md

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

DATE="${RUN_DATE:-$(date +%Y-%m-%d)}"
RESULTS_DIR="$BUNDLE_ROOT/results_72gpu/$DATE"
HOSTFILE="$SCRIPT_DIR/hostfile.nvl72"
MPIRUN="${MPIRUN:-/usr/mpi/gcc/openmpi-4.1.9a1/bin/mpirun}"
NCCL_IF="${NCCL_SOCKET_IFNAME:-enP5p9s0}"
TCP_IF="${MPI_TCP_IF:-enP5p9s0}"

mkdir -p "$RESULTS_DIR"/{per_node,cluster}

echo "==== 72-GPU NVL72 full test — $DATE ===="
echo "results_dir: $RESULTS_DIR"
echo ""

# ===== Step 1: health check =====
echo "==== [1/4] Health check on 18 peer nodes ===="
if ! bash "$SCRIPT_DIR/health_check_peers.sh"; then
  echo "ABORT: peer health check failed. Fix before continuing."
  exit 1
fi
echo ""

# ===== Step 2: per-node tests (parallel) =====
echo "==== [2/4] Per-node tests (gemm + stream + nvbandwidth, 18 nodes parallel) ===="
echo "start: $(date +%H:%M:%S)"

NODES=$(awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ {next} {print $1}' "$HOSTFILE")

REMOTE_SCRIPT='
set -e
cd /root/bench-bundle/bin/single-node
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
WORK=/tmp/bench_run_$$
mkdir -p "$WORK"
cp bench_gemm stream nvbandwidth "$WORK/"
cp /root/bench-bundle/spec/*.json "$WORK/"
cd "$WORK"
for dt in fp64 fp32 tf32 bf16 fp16 fp8_e4m3; do
  timeout 180 ./bench_gemm --dtype=$dt --iters=20 > gemm_$dt.log 2>&1 || echo "gemm $dt FAILED"
done
timeout 180 ./stream > stream.log 2>&1 || echo "stream FAILED"
timeout 300 ./nvbandwidth -t device_to_device_bidirectional_memcpy_read_ce \
                          -t device_to_device_bidirectional_memcpy_write_ce \
                          -t host_to_device_memcpy_ce \
                          -t device_to_host_memcpy_ce \
                          -t all_to_host_memcpy_ce \
                          -t host_to_all_memcpy_ce > nvbandwidth.log 2>&1 || echo "nvbandwidth FAILED"
tar czf "/tmp/bench_results_$$.tgz" -C "$WORK" $(cd "$WORK" && ls *.log gemm_result.json stream_result.json nvbandwidth_result.json 2>/dev/null)
echo "TARBALL_PATH=/tmp/bench_results_$$.tgz"
'

TMP_DIR=$(mktemp -d)
for ip in $NODES; do
  (
    node_dir="$RESULTS_DIR/per_node/$ip"
    mkdir -p "$node_dir"
    encoded=$(echo "$REMOTE_SCRIPT" | base64 -w 0)
    tarball=$(timeout 600 ssh -o BatchMode=yes -o ConnectTimeout=10 \
      "root@$ip" "echo $encoded | base64 -d | bash 2>&1 | grep TARBALL_PATH | cut -d= -f2")
    if [ -n "$tarball" ]; then
      scp -q "root@$ip:$tarball" "$node_dir/r.tgz" && {
        tar xzf "$node_dir/r.tgz" -C "$node_dir/"
        rm "$node_dir/r.tgz"
        ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" "rm -rf /tmp/bench_run_* /tmp/bench_results_*.tgz" 2>/dev/null
        echo "$ip OK"
      } || echo "$ip SCP_FAIL"
    else
      echo "$ip REMOTE_FAIL"
    fi
  ) > "$TMP_DIR/$ip.out" 2>&1 &
done
wait

cat "$TMP_DIR"/*.out | sort
rm -rf "$TMP_DIR"
echo "end: $(date +%H:%M:%S)"
echo ""

# ===== Step 3: cluster collectives =====
echo "==== [3/4] Cluster 7 NCCL collectives (72-rank MPI) ===="
run_one() {
  local tool=$1
  echo "-- $tool"
  local t0=$(date +%H:%M:%S)
  timeout 360 "$MPIRUN" -np 72 \
    --hostfile "$HOSTFILE" --allow-run-as-root \
    -mca pml ob1 -mca btl tcp,self \
    -mca btl_tcp_if_include "$TCP_IF" \
    --mca plm_rsh_args "-o StrictHostKeyChecking=accept-new" \
    -x LD_LIBRARY_PATH -x NCCL_SOCKET_IFNAME="$NCCL_IF" -x NCCL_DEBUG=WARN \
    "$BUNDLE_ROOT/bin/mpi/${tool}_perf_mpi" -b 8 -e 8G -f 2 -g 1 \
    > "$RESULTS_DIR/cluster/${tool}.log" 2>&1
  local rc=$?
  local peak=$(awk '/^ *[0-9]/ {if ($7+0 > max) max=$7+0} END {if (max) printf "%.2f", max; else print "N/A"}' "$RESULTS_DIR/cluster/${tool}.log")
  local wrong=$(grep "Out of bounds" "$RESULTS_DIR/cluster/${tool}.log" | awk '{print $7}')
  echo "   $t0 -> $(date +%H:%M:%S)  rc=$rc  peak=${peak} GB/s  wrong=${wrong:-?}"
}
for t in all_reduce alltoall all_gather broadcast reduce reduce_scatter sendrecv; do
  run_one "$t"
done
echo ""

# ===== Step 4: aggregate + report =====
echo "==== [4/4] Aggregating and generating report ===="
python3 "$SCRIPT_DIR/aggregate_72gpu.py" "$RESULTS_DIR" || echo "aggregate script failed (non-fatal)"

echo ""
echo "==== DONE ===="
echo "Results: $RESULTS_DIR"
[ -f "$RESULTS_DIR/report.md" ] && echo "Report:  $RESULTS_DIR/report.md"
