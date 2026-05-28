# Testbench — GB300 / NVL72 acceptance suite

GPU cluster bring-up and acceptance testing tools for NVIDIA GB300 (Blackwell Ultra)
on NVL72 (18 nodes × 4 GPU = 72 GPU per chassis).

## What's in this repo

| Path | Purpose |
|---|---|
| `gemm_tests/` | cuBLASLt GEMM benchmark source (`bench_gemm`) — multi-dtype TFLOPS, JSON output |
| `stream_tests/` | GPU STREAM source (`stream`) — Copy/Scale/Add/Triad HBM bandwidth |
| `nvbandwidth_tests/` | NVIDIA `nvbandwidth` CMake build harness — NVLink + Grace-C2C bandwidth |
| `nccl_tests/` | NCCL collective benchmarks (single-node + MPI variants for cluster mode) |
| `spec/` | Per-GPU acceptance specs (flat runtime threshold + full metadata) |
| `scripts/` | Build / deploy / health-check / test orchestration scripts |
| `docs/runbooks/` | Operational playbooks (bring-up, diagnostics, escalation, fixes) |
| `.claude/` | Claude Code agent context (memory + per-task skills) |
| `CLAUDE.md` | Project ground rules and hard constraints |

## Quick start (you already have a working node)

```bash
git clone https://github.com/404mario/Testbench.git
cd Testbench
bash scripts/build_aarch64_tools.sh           # build 4 tools for aarch64 / GB300
# ... copy binaries to ~/bench-bundle/ ... (see docs/runbooks/new-machine-bringup.md §4)
bash ~/bench-bundle/scripts/health_check_peers.sh   # confirm 18 peers healthy
bash ~/bench-bundle/scripts/run_72gpu_full.sh       # 12-15 min full acceptance
```

Output lands in `~/bench-bundle/results_72gpu/<DATE>/report.md`.

## First-time on a new machine

See **[`docs/runbooks/new-machine-bringup.md`](docs/runbooks/new-machine-bringup.md)** —
top-to-bottom SOP for a fresh GB300 NVL72 compute node, from inventory through full
acceptance run.

## Repo vs. runtime workspace

This repo holds source, scripts, and specs. The runtime workspace is
**`~/bench-bundle/`** on each compute node — it holds the built binaries, deployed
copies of scripts/specs, and test results. `~/bench-bundle/` is NEVER committed.

Deploy from repo → `~/bench-bundle/` after each rebuild. See bring-up runbook §4.

## Scripts

| Script | Purpose | When to use |
|---|---|---|
| `scripts/build_aarch64_tools.sh` | Compile the 4 bench binaries from source | After clone, or after editing tool source |
| `scripts/diagnose_gb300_env.sh` | Read-only environment health snapshot | Whenever something feels off; ALWAYS first |
| `scripts/health_check_peers.sh` | Parallel SSH fabric audit on all 18 peers | Before any 72-GPU cluster run |
| `scripts/run_72gpu_full.sh` | Full per-node + cluster acceptance suite, ~12 min | Daily / weekly / after fixes |
| `scripts/run_parallel_test.sh` | Legacy per-node fan-out runner (single tool at a time) | One-off per-tool runs |
| `scripts/runner_cluster.sh` | One NCCL collective at 72-rank MPI | Targeted NCCL debugging |
| `scripts/aggregate_72gpu.py` | Aggregate raw outputs → `aggregated.json` + `report.md` | Auto-called by `run_72gpu_full.sh` |
| `scripts/collect_fabric_evidence.sh` | Bundle dmesg + nvidia-smi + IMEX log into a tarball | Before escalating to chassis team |
| `scripts/daily_snapshot.sh` | End-of-day `git add` + commit + push | Anytime, but at least daily |

## Specs

| File | Schema | Role |
|---|---|---|
| `spec/GB300_specs.json` | Flat runtime thresholds | What binaries read for Pass/Fail (calibrated from 2026-05-27 bring-up baseline) |
| `spec/GB300_specs.full.json` | Nested metadata | Theoretical peak datasheet (architecture, memory, NVLink, all TFLOPS dense + sparse, TDP) |
| `spec/B300_specs.json` | Flat runtime thresholds | Reference for discrete B300 (NOT the same GPU as GB300) |
| `spec/{A100,B200,H100,H200,H20}_specs.json` | Flat | Other-cluster references |

**Known issue**: Current binary `detect_spec_filename()` maps GPU name `NVIDIA GB300`
to `B300_specs.json`, not `GB300_specs.json`. Until binaries are rebuilt with corrected
logic, mentally substitute GB300 spec values when reading `target_spec_file: "B300_specs.json"`
in the JSON output. See `spec/GB300_specs.json` `_spec_selection_note` field.

## Runbooks index

| Runbook | When to read it |
|---|---|
| [`new-machine-bringup.md`](docs/runbooks/new-machine-bringup.md) | Fresh node, never been benched on |
| [`gb300-environment-summary.md`](docs/runbooks/gb300-environment-summary.md) | Reference snapshot of expected environment |
| [`gb300-known-issues.md`](docs/runbooks/gb300-known-issues.md) | Specific symptoms → causes |
| [`gb300-fabric-bringup-blocker.md`](docs/runbooks/gb300-fabric-bringup-blocker.md) | `cudaGetDeviceCount` hangs, `fabric.state = In Progress` |
| [`gb300-fabric-escalation.md`](docs/runbooks/gb300-fabric-escalation.md) | Need to send evidence to chassis / NMX-C team |
| [`driver-topology-cache-fix.md`](docs/runbooks/driver-topology-cache-fix.md) | NCCL busbw collapsed; dmesg flooded with `knvlink` errors |

## Hard constraints (excerpt — full list in CLAUDE.md)

1. Do not reboot
2. Do not restart `nvidia-imex` / `nvidia-fabricmanager` / `nvidia-persistenced` without explicit approval
3. Do not modify `/etc/nvidia-imex/` (especially `nodes_config.cfg`)
4. Do not `apt install/purge` without approval
5. Do not commit: build artifacts, `result/`, tokens, BMC passwords, private keys, `.env`
6. Do not put `127.0.0.1` in a node-list file and then run `all` mode (silently skips cross-node path)
