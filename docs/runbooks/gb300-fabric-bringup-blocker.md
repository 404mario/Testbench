# GB300 NVL72 Compute Node — Fabric bring-up blocker

> **Node**: `pega` (192.168.15.153)
> **Date**: 2026-05-21
> **Status**: ❌ CUDA runtime blocked indefinitely; needs operator/chassis-side action.

## TL;DR for operations

This compute node cannot initialize CUDA. The block is **`fabric.state = "In Progress"`** on all 4 GB300 GPUs, with `CliqueId / ClusterUUID / Partition Assigned` all `N/A`. We installed `nvidia-fabricmanager` (exact-match version `595.58.03`) and tried to start it. **It immediately exited because the local NVSwitch driver reports `NV_WARN_NOTHING_TO_DO`** — i.e. there is no NVSwitch hardware physically present on this compute node, which is expected for the GB300 NVL72 Kyber chassis design.

That means the fabric bring-up that flips `fabric.state` from `In Progress` → `Completed` must come from **chassis-side coordination** (chassis BMC out-of-band sequence, an external Global Fabric Manager, or a cluster orchestrator that owns partition assignment). **There is nothing more this node can do on its own** without that external step.

CUDA `cudaGetDeviceCount()` now **hangs indefinitely** instead of returning the previous `802 (system not yet initialized)` — it is blocking on the same fabric init.

## What is healthy on this node

- 4× NVIDIA GB300 detected by `nvidia-smi`, all P0, persistence mode enabled
- Driver: `nvidia-dkms-open 595.58.03-1ubuntu1` (open kernel module flavor)
- CUDA toolkit 13.2 (`/usr/local/cuda-13`), nvcc working
- All NVLink lanes up at 53.125 GB/s, 18 lanes per GPU bond → `NV18` topology
- `nvidia-imex` active, established gRPC to all 17 peer nodes
- `nvidia-persistenced` active, all 4 GPUs registered + NUMA memory onlined
- `ib_umad`, `mlx5_*` kernel modules loaded; `ibstat`, `nv-fabricmanager` binaries present
- IMEX `nodes_config.cfg` lists 18 nodes (`192.168.15.137`–`192.168.15.154`) — assumed correct, untouched

## What is broken

```
$ nvidia-smi --query-gpu=index,name,fabric.state,fabric.status --format=csv
index, name, fabric.state, fabric.status
0, NVIDIA GB300, In Progress, N/A
1, NVIDIA GB300, In Progress, N/A
2, NVIDIA GB300, In Progress, N/A
3, NVIDIA GB300, In Progress, N/A
```

```
$ nvidia-smi -i 0 -q | grep -A 12 'Fabric'
    Fabric
        State          : In Progress
        Status         : N/A
        CliqueId       : N/A
        ClusterUUID    : N/A
        Health
            Summary    : N/A
            ...
            Partition Assigned : N/A
```

```
$ timeout 30 ./cuda_probe   # 5-line cudaGetDeviceCount probe, aarch64 ELF
[hang ... exit 124 from timeout]
```

## What we tried, what happened

1. **Confirmed no FabricManager installed initially.** `systemctl status nvidia-fabricmanager` → unit not found. `/usr/bin/nv-fabricmanager` missing. No prior install/remove traces in `/var/log/apt/history.log*`.
2. **Located exact-match package.** NVIDIA CUDA SBSA repo (`developer.download.nvidia.com/.../ubuntu2404/sbsa/`) has `nvidia-fabricmanager_595.58.03-1ubuntu1_arm64.deb` (no `-595` suffix; matches `nvidia-imex 595.58.03`, `nvidia-persistenced 595.58.03`, driver `595.58.03`). The Ubuntu-archive `nvidia-fabricmanager-595` package (with `-595` suffix, version `595.71.05`) is for the **proprietary `-server` driver branch**, which conflicts with our installed open driver — wrong package.
3. **Installed exact match cleanly** (`apt install -y nvidia-fabricmanager=595.58.03-1ubuntu1`). Service enabled by postinst, but not auto-started.
4. **Attempted `systemctl start nvidia-fabricmanager`.** Failed within 1 second:
   ```
   nvidia-fabricmanager-start.sh: Detected Pre-NVL5 system
   request to query NVSwitch device information from NVSwitch driver failed
       with error: WARNING Nothing to do [NV_WARN_NOTHING_TO_DO]
   /usr/bin/nv-fabricmanager ... failed! Exit code: 1
   ```
   The "Pre-NVL5 system" line is `nvidia-fabricmanager-start.sh` reporting that no Mellanox PCI device on this host advertises the `SW_MNG` capability — i.e., there is no local NVSwitch management endpoint. The kernel-side `NV_WARN_NOTHING_TO_DO` is the NVSwitch driver telling FM "there are no NVSwitch devices for you to manage."
5. **Service disabled, package kept** (`systemctl disable nvidia-fabricmanager`). FM package remains installed and ready for ops to use with the correct config when known. Service will not auto-start at boot.

## Why we believe this is a chassis-side / cluster-side issue, not a node issue

- The default `fabricmanager.cfg` only knows `FABRIC_MODE=0|1|2` (bare-metal NVSwitch, SHARED_FABRIC vGPU, vGPU multitenancy) — **all three assume local NVSwitch hardware**.
- There is no `FABRIC_MODE=<external-GFM>` or `EXTERNAL_GFM=1` flag in the shipped config; `MNNVL_*` fields are GFM-internal tunables, not per-node enablement.
- 18 IMEX peers all reachable on port 50000 → the cluster-control network is fine.
- No `apt` history shows FM ever installed on this node → likely all 18 nodes are equally bare. Either every node is the same, or some "master" node owns FM/GFM — operations should tell us which.
- `Partition Assigned: N/A` confirms no partition has ever been declared for this node's GPUs via the fabric API.

## Specific things we'd like operations to confirm

1. **What is the documented bring-up procedure for GB300 NVL72 compute nodes?**
   In particular: does NVIDIA's deployment guide for the Kyber chassis expect FabricManager on each compute node, or only on a designated controller / chassis BMC / external GFM host?
2. **Are the other 17 compute nodes** (`192.168.15.137`–`152` and `154`) **in the same `fabric.state = In Progress` state**, or are some of them at `Completed`? If any node is Completed, what is different about it?
3. **Is there a chassis-side service** (GFM, BMC OOB sequence, cluster orchestrator job) that should have run during cluster bring-up but did not? If so, can it be triggered post-hoc for this node?
4. **Is there a documented `fabricmanager.cfg`** for GB300 NVL72 compute nodes that we should use instead of the default? Particularly any per-node settings (`NODE_ID`, partition rail policy specifics, MNNVL tuning, topology file pin) tailored to this cluster.
5. **Is the node 17 (`192.168.15.154`) IMEX disconnect/reconnect** (seen in `/var/log/nvidia-imex.log`) related to this fabric blocker, or unrelated?

## What we did NOT do (deliberately preserved cluster state)

- Did **not** touch `/etc/nvidia-imex/` (especially `nodes_config.cfg`). The 18-node configuration is intact.
- Did **not** restart `nvidia-imex` (would force re-handshake with cluster; `/run/nvidia-imex/persist.dat` would re-key).
- Did **not** `systemctl start nvidia-fabricmanager` again after the initial failure (clean rollback to disabled state).
- Did **not** reboot.
- Did **not** modify driver flavor (still `nvidia-dkms-open 595.58.03`, did not consider switching to `-server` proprietary).
- Did **not** unload/reload `nvidia` kernel module.
- Did **not** `apt purge` FM (kept installed so ops can flip the right knobs without re-downloading).
- Did **not** touch SSH config, sudoers, or any user account.

## Current state on this node (post-investigation)

- `nvidia-fabricmanager` package: **installed**, version `595.58.03-1ubuntu1`
- `nvidia-fabricmanager.service`: **disabled** (will not auto-start at boot)
- `nv-fabricmanager` process: **not running**
- `nvidia-imex.service`: **active** (untouched)
- `nvidia-persistenced.service`: **active** (untouched)
- `fabric.state`: **In Progress** on all 4 GPUs (unchanged throughout investigation)
- CUDA runtime: **non-functional** (`cudaGetDeviceCount` hangs)

## What we can still do while waiting

Cross-compiling aarch64 Testbench binaries (`bench_gemm`, `stream`, `all_reduce_perf`, `alltoall_perf`, `nvbandwidth`) **does not require CUDA runtime** — only `nvcc`. We can build, package, and stage everything in `~/bench/` so that **the moment `fabric.state` becomes `Completed`, the smoke tests run immediately**. Smoke-test scripts and runbooks are also being committed to this repo in parallel.

## Key log evidence (verbatim excerpts)

### FM startup failure
```
[2026-05-21 08:21:00 UTC] Detected Pre-NVL5 system
[2026-05-21 08:21:00 UTC] request to query NVSwitch device information from NVSwitch driver
                         failed with error:WARNING Nothing to do [NV_WARN_NOTHING_TO_DO]
[2026-05-21 08:21:00 UTC] /usr/bin/nv-fabricmanager -c /usr/share/nvidia/nvswitch/fabricmanager.cfg
                         failed! Exit code: 1
```

### FM config snapshot (defaults that prove no external-GFM mode)
```
Fabric Mode = 0
Fabric Mode Restart = 0
Continue to run when facing failures = 0
Abort CUDA jobs when FM exits = 1
FM Library communication bind interface = 127.0.0.1
Disabling RPC mode for single node configuration.
```

### IMEX healthy multi-node state
```
[2026-05-21 06:59:12 UTC] Connection established to node 0..17 with addresses 192.168.15.137..154
[2026-05-21 06:59:12 UTC] IMEX_WAIT_FOR_QUORUM != FULL, continuing initialization without waiting
                          for connections to all nodes.
[2026-05-21 06:59:12 UTC] GPU event successfully subscribed
[2026-05-21 06:59:22 UTC] Connection lost to node 17: 192.168.15.154:50000  (recovered 4s later)
```

### Mellanox device scan (no SW_MNG anywhere)
```
$ for bdf in $(lspci -D | grep Mellanox | awk '{print $1}'); do
      lspci -s "$bdf" -vvv | grep -q SW_MNG && echo "$bdf SW_MNG" || echo "$bdf (no SW_MNG)"
  done
0000:01:00.0   (no SW_MNG)
0000:03:00.0   (no SW_MNG)   <-- ConnectX-8 IB controller
...                          (54 devices total, all "no SW_MNG")
```

## Reproducer for ops

```bash
# Read-only commands; safe to run on any GB300 NVL72 compute node
nvidia-smi --query-gpu=name,fabric.state,fabric.status --format=csv
nvidia-smi -i 0 -q | grep -A 12 'Fabric'
systemctl is-active nvidia-fabricmanager nvidia-imex nvidia-persistenced
ls /usr/bin/nv-fabricmanager 2>&1  # is FM even installed?
dpkg -l | grep -E 'nvidia-fabricmanager|nvidia-dkms|nvidia-imex'
journalctl -u nvidia-fabricmanager --no-pager | tail -50  # if FM was ever attempted
```

## Contact / next steps

When ops confirms what should change, the on-node actions we expect to perform are some subset of:

- Drop in a chassis-tuned `fabricmanager.cfg` (path: `/usr/share/nvidia/nvswitch/fabricmanager.cfg` — override via `FM_CONFIG_FILE` env in unit file rather than editing the shipped file).
- `systemctl enable --now nvidia-fabricmanager` (if per-node FM with non-default mode is required).
- Or do nothing on-node and rely on chassis-side trigger to flip `fabric.state`.

We will not run any of these without explicit instruction.
