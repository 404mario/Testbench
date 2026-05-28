# New-Machine Bring-Up — GB300 / NVL72 compute node

This runbook is for when you receive a fresh NVL72 compute node (or a fresh OS install
on one) and need to validate it, deploy bench tools, and get to the point where you can
run the full 72-GPU acceptance suite.

Audience: someone with no prior context on this cluster. Follow top-to-bottom.

---

## 0. Before you start — sanity questions to ask

- Is this node on the same NVL72 chassis as the other compute nodes (sharing NVSwitch)?
- What IP did the cluster admin assign? (the 18-node fabric expects `192.168.15.137`–`192.168.15.154`)
- Has the chassis-side NMX-C been configured to include this GPU in the partition? If
  not, fabric will never come up no matter what you do on the node — see
  `docs/runbooks/gb300-fabric-escalation.md`.

---

## 1. Inventory the environment (read-only)

```bash
# OS / kernel / arch
uname -a                   # expect: Linux ... aarch64 (Grace CPU)
cat /etc/os-release        # expect: Ubuntu 24.04
nproc; free -h             # CPU/mem sanity

# GPU + driver — DO NOT RESTART ANYTHING YET
nvidia-smi                 # 4× NVIDIA GB300, driver 595.x, CUDA 13.x
nvidia-smi -q | grep -E "Driver Version|CUDA Version|Persistence Mode"

# CUDA / NCCL / cuBLAS install paths
ls /usr/local/cuda-13/bin/nvcc
ls /lib/aarch64-linux-gnu/libnccl.so.2
ls /usr/local/cuda/targets/sbsa-linux/lib/libcublasLt.so

# Fabric (Multi-Node NVLink) state — the critical thing
nvidia-smi -q | grep -iE "fabric|clique|recovery"
# Expect: State = Completed, Status = Success, CliqueId = 32766 (for this cluster)
# If "System is not in ready state" -> chassis side issue, see escalation runbook
# If cudaGetDeviceCount hangs -> fabric is "In Progress" -> chassis side issue

# IMEX (control-plane for cross-node NVLink)
systemctl is-active nvidia-imex
cat /etc/nvidia-imex/nodes_config.cfg | head    # expect 18 IPs
tail /var/log/nvidia-imex.log                   # should show gRPC connections to peers

# Diagnostic one-shot (reads everything above and more)
bash scripts/diagnose_gb300_env.sh
```

If anything looks wrong, STOP and read the relevant runbook in `docs/runbooks/` —
do not "fix" things blindly. The hard constraints in `CLAUDE.md` exist for a reason.

---

## 2. Hard constraints — do NOT do any of these

1. Do not reboot
2. Do not restart `nvidia-imex` / `nvidia-fabricmanager` / `nvidia-persistenced`
   without coordinating with the cluster — these services hold cluster-wide state
   in `/run/nvidia-imex/persist.dat`
3. Do not modify `/etc/nvidia-imex/`
4. Do not `sudo apt install/purge` anything without explicit approval
5. Do not commit binaries, test results, secrets, or `.env` files
6. Do not write `127.0.0.1` into a node-list file and then run `all` mode
   (the runner treats `127.0.0.1` as local-only and will silently skip the cross-node code path)

---

## 3. Build the four bench binaries (aarch64)

The repo ships source for four tools: `bench_gemm`, `stream`, `nvbandwidth`,
and `nccl-tests` (which produces `all_reduce_perf`, `alltoall_perf`, plus the
`*_perf_mpi` variants).

```bash
git clone https://github.com/404mario/Testbench.git
cd Testbench
bash scripts/build_aarch64_tools.sh
```

The build script is the source of truth for the exact compile flags. See
`.claude/memory/ref_build_aarch64.md` for the recorded per-tool parameters.

Expected output:
- `gemm_tests/bench_gemm`         (~300 KB)
- `stream_tests/stream`           (~250 KB)
- `nvbandwidth_tests/nvbandwidth` (~2.2 MB)
- `nccl_tests/build/{all_reduce_perf,alltoall_perf,...}` (~30 MB each, single-node)
- `nccl_tests/build/{all_reduce_perf_mpi,...}`           (the MPI variants for cluster mode)

---

## 4. Deploy to ~/bench-bundle/

`~/bench-bundle/` is the runtime workspace. It is NEVER committed to git. Layout:

```
~/bench-bundle/
├── bin/
│   ├── single-node/           # local-mode binaries (single-host launcher)
│   │   ├── bench_gemm
│   │   ├── stream
│   │   ├── nvbandwidth
│   │   ├── all_reduce_perf
│   │   └── alltoall_perf
│   └── mpi/                   # 72-rank cluster-mode binaries (run via mpirun)
│       ├── all_reduce_perf_mpi
│       ├── alltoall_perf_mpi
│       ├── all_gather_perf_mpi
│       ├── broadcast_perf_mpi
│       ├── reduce_perf_mpi
│       ├── reduce_scatter_perf_mpi
│       └── sendrecv_perf_mpi
├── spec/
│   ├── GB300_specs.json       # runtime pass thresholds (binaries read this)
│   ├── GB300_specs.full.json  # theoretical peak datasheet (metadata)
│   ├── B300_specs.json        # CURRENT bug: binaries map "NVIDIA GB300" here
│   └── ...                    # A100/B200/H100/H200/H20 specs (other clusters)
├── scripts/
│   ├── env.sh                 # source this before running anything
│   ├── hostfile.nvl72         # 18 IPs × 4 slots
│   ├── health_check_peers.sh  # parallel SSH fabric audit
│   ├── run_72gpu_full.sh      # full acceptance suite
│   ├── runner_cluster.sh      # one collective at a time, 72-rank MPI
│   ├── run_parallel_test.sh   # legacy per-node fan-out runner
│   └── aggregate_72gpu.py     # build aggregated.json + report.md from raw outputs
├── results_baseline/          # historical reference runs
└── results_72gpu/<DATE>/      # output of full acceptance runs
```

Deploy the freshly-built binaries:

```bash
mkdir -p ~/bench-bundle/{bin/{single-node,mpi},spec,scripts,results_72gpu,results_baseline}
cp gemm_tests/bench_gemm        ~/bench-bundle/bin/single-node/
cp stream_tests/stream          ~/bench-bundle/bin/single-node/
cp nvbandwidth_tests/nvbandwidth ~/bench-bundle/bin/single-node/
cp nccl_tests/build/all_reduce_perf nccl_tests/build/alltoall_perf ~/bench-bundle/bin/single-node/
cp nccl_tests/build/*_perf_mpi  ~/bench-bundle/bin/mpi/
cp spec/*.json                  ~/bench-bundle/spec/
cp scripts/{env.sh,hostfile.nvl72,health_check_peers.sh,run_72gpu_full.sh,runner_cluster.sh,run_parallel_test.sh,aggregate_72gpu.py} \
   ~/bench-bundle/scripts/
```

Then replicate to the other 17 peers (they each need their own copy because each
node runs `bench_gemm`/`stream`/`nvbandwidth` locally):

```bash
for ip in $(awk '{print $1}' ~/bench-bundle/scripts/hostfile.nvl72); do
  [ "$ip" = "$(hostname -I | awk '{print $1}')" ] && continue
  rsync -a ~/bench-bundle/ "root@$ip:~/bench-bundle/"
done
```

---

## 5. Smoke test — single node

Quick sanity check that one node works before launching cluster mode:

```bash
source ~/bench-bundle/scripts/env.sh
cd ~/bench-bundle/bin/single-node
cp ~/bench-bundle/spec/*.json .

# 1 min: gemm fp64 (~4 sec/GPU)
./bench_gemm --dtype=fp64 --iters=20

# 30 sec: stream 4 ops
./stream

# 30 sec: NVLink dev↔dev bidir
./nvbandwidth -t device_to_device_bidirectional_memcpy_read_ce

# 30 sec: 4-GPU NCCL all_reduce
./all_reduce_perf -b 1G -e 8G -f 2 -g 4
```

Healthy GB300 numbers (approximate):
- fp64 ≈ 1.1 TFLOPS/GPU
- stream copy ≈ 6900 GB/s, triad ≈ 7100 GB/s
- dev↔dev bidir read ≈ 1527 GB/s
- 4-GPU all_reduce peak ≈ 600+ GB/s

If any of these is wildly off (e.g. NCCL busbw < 100 GB/s), driver state may be
corrupted — see `docs/runbooks/driver-topology-cache-fix.md` for the rmmod+modprobe+FLR
recovery procedure.

---

## 6. Full 72-GPU acceptance run

After single-node smoke passes on the launcher node, and you've confirmed all 18
peers are reachable:

```bash
bash ~/bench-bundle/scripts/run_72gpu_full.sh
```

This runs (~12-15 min on a healthy cluster):
1. Parallel SSH health check on all 18 peers (aborts if degraded)
2. Parallel per-node tests on all 18 peers (gemm × 6 dtypes + stream + nvbandwidth)
3. 7 NCCL collectives at 72-rank MPI
4. Aggregation + `report.md` generation

Output: `~/bench-bundle/results_72gpu/$(date +%Y-%m-%d)/`

---

## 7. If anything fails

| Symptom | Runbook |
|---|---|
| `cudaGetDeviceCount` hangs | `gb300-fabric-bringup-blocker.md` |
| fabric.state = "In Progress" or "Not Ready" | `gb300-fabric-escalation.md` |
| NCCL busbw collapses on second run | `driver-topology-cache-fix.md` |
| `ConnectFail` in run_parallel_test.sh output | `gb300-known-issues.md` |
| `Exec format error` | binary is x86_64, rebuild aarch64 — see `ref_build_aarch64.md` |

If you hit something not covered, add it to `gb300-known-issues.md`.
