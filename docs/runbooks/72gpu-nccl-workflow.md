# 72-GPU NCCL bench workflow

End-to-end runbook for running the NVL72 cluster-wide NCCL collective tests
on a fresh testbench. Assumes you start from a clean machine with the OSS
bundle downloaded.

## Prereqs (machine-level, NOT in the bundle)

- NVIDIA driver `595.71.05` + CUDA 13.2 + NCCL 2.29.7 already installed on
  every node (uniform versions are mandatory — version mismatch breaks IMEX).
- OpenMPI `4.1.9a1` already at `/usr/mpi/gcc/openmpi-4.1.9a1/` on every node
  (NVIDIA HPC-X-style location).
- Chassis NVSwitch fabric UP (`nvidia-smi --query-gpu=fabric.state` returns
  `Completed` on every node). If `In Progress`, fix on the switch tray
  first — see `gb300-fabric-escalation.md`.
- Root SSH any-to-any across all 18 nodes. If not, set up first via
  `ssh-copy-id`/`sshpass`. See [project-nvl72-ssh memory note](../../.claude/memory/project_nvl72_ssh.md)
  for the shared-keypair model used on this testbench.

## One-time bootstrap on a fresh machine

```bash
# 1. download bundle from OSS (see oss-restore.md for ossutil details)
ossutil cp oss://<bucket>/<prefix>/nvl72-bench-bundle.tar.gz /tmp/

# 2. extract to canonical location
tar xf /tmp/nvl72-bench-bundle.tar.gz -C /root/
mv /root/nvl72-bench-bundle /root/bench-bundle

# 3. edit hostfile if your IP range differs from .137-.154
cp /root/bench-bundle/scripts/hostfile.nvl72.example /root/bench-bundle/scripts/hostfile.nvl72
$EDITOR /root/bench-bundle/scripts/hostfile.nvl72

# 4. propagate bundle + create IMEX channel0 on missing nodes (idempotent)
cd /root/bench-bundle
./scripts/setup.sh
```

`setup.sh` does three things:
1. Verifies SSH passwordless to every node in hostfile (fails fast if missing)
2. Runs `fix_imex_channels.sh` — creates `/dev/nvidia-caps-imex-channels/channel0`
   on every node missing it
3. rsyncs the entire bundle to `/root/bench-bundle/` on each remote node

## Daily smoke (ascending difficulty)

The convention: every higher tier is gated by all lower tiers passing first.
If a higher tier fails but a lower one passes, the failure is in the new
component (cross-tier transport), not in the components shared with the
lower tier.

### Tier 1 — single GPU compute (~5 s)
```bash
./scripts/run_parallel_test.sh bench_gemm localhost \
    -- --dtype=bf16 --M=8192 --N=8192 --K=8192 --iters=100
```
Expect ≥ 2200 TFLOPS bf16 per GPU. Failure mode: cuBLAS init error, fabric
not Completed.

### Tier 2 — single GPU memory (~3 s)
```bash
./scripts/run_parallel_test.sh stream localhost
```
Expect Copy/Scale ≥ 6500 GB/s, Add/Triad ≥ 6700 GB/s. Failure mode: HBM
clock lock, defective GPU.

### Tier 3 — intra-node NVLink (~30 s)
```bash
./scripts/run_parallel_test.sh nvbandwidth localhost \
    -- -t device_to_device_bidirectional_memcpy_read_ce
./scripts/run_parallel_test.sh nvbandwidth localhost \
    -- -t device_to_device_bidirectional_memcpy_write_ce
```
Expect ≥ 1450 GB/s per pair bidir. Failure mode: NVLink link down, peer
access denied (check `nvidia-smi nvlink --status`).

### Tier 4 — single-node 4-GPU NCCL (~30 s)
```bash
./scripts/run_parallel_test.sh all_reduce_perf localhost -- -b 8 -e 1G -f 2 -g 4
```
Expect peak busbw ≥ 600 GB/s @ 1 GiB. Failure mode: NCCL P2P transport
init error.

### Tier 5 — full NVL72 72-GPU NCCL (~15 s per collective)
```bash
./scripts/run_parallel_test.sh --mode=72gpu all_reduce
./scripts/run_parallel_test.sh --mode=72gpu alltoall
./scripts/run_parallel_test.sh --mode=72gpu all_gather
./scripts/run_parallel_test.sh --mode=72gpu broadcast
./scripts/run_parallel_test.sh --mode=72gpu reduce
./scripts/run_parallel_test.sh --mode=72gpu reduce_scatter
./scripts/run_parallel_test.sh --mode=72gpu sendrecv
```
Expect peak busbw ≥ 600 GB/s @ 1 GiB for all\_reduce, ≥ 400 GB/s for alltoall.
Output goes to `results_72gpu/<collective>.log` with a SUMMARY line.

Failure modes specific to Tier 5:
- `MNNVL (cliqueSize 72) is available but not working` → run
  `./scripts/fix_imex_channels.sh` and retry.
- `Permission denied (publickey,password)` mid-mpirun → SSH key not
  on some node; re-run setup.
- `ucp_ep_create` / `ibv_create_ah` timeouts → UCX transport selection;
  `env.sh` should be sourced; verify `echo $UCX_TLS` shows `tcp,self,sm`.

### Optional — full sweep across 18 nodes independently
For sanity-checking that every node performs identically (catches one bad
GPU among 72):
```bash
./scripts/run_parallel_test.sh nvbandwidth all     # expects ./node file with 18 IPs
./scripts/run_parallel_test.sh stream all
./scripts/run_parallel_test.sh bench_gemm all
```

This is the v8 per-node mode — different from `--mode=72gpu`. Each node runs
the same test independently and produces its own JSON; results aggregated to
`./result/<tool>/`.

## Custom hostfile for partial cluster

Want to test only a subset of nodes (e.g. 4 nodes × 4 = 16 GPUs)?

```bash
# create hostfile with only the nodes you want
cat > /tmp/my_hostfile <<EOF
192.168.15.137 slots=4
192.168.15.138 slots=4
192.168.15.139 slots=4
192.168.15.140 slots=4
EOF

# point runner at it via the env var (runner_cluster.sh respects this)
HOSTFILE=/tmp/my_hostfile ./scripts/runner_cluster.sh all_reduce
```
or directly:
```bash
mpirun -np 16 --hostfile /tmp/my_hostfile --allow-run-as-root \
    -x UCX_TLS=tcp,self,sm -x NCCL_SOCKET_IFNAME=enP5p9s0 \
    /root/bench-bundle/bin/mpi/all_reduce_perf_mpi -b 8 -e 1G -f 2 -g 1
```

## Comparing against baseline

Reference numbers from this hardware on 2026-05-27 are in
`docs/reports/2026-05-27-nvl72-baseline.md`. After any driver update, fabric
event, or hardware swap, re-run the full Tier 1–5 sweep and diff your busbw
numbers against the reference. A regression of >5% on any single collective
warrants investigation.
