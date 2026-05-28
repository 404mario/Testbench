# Driver NVLink Topology Cache — Reload + Per-GPU FLR Recovery

## When to use this runbook

You're seeing one or more of these on a GB300 NVL72 compute node:

- NCCL `all_reduce` busbw plateaus far below spec (e.g. 48 GB/s on what should hit 600+),
  with `validation = OK` (no data errors)
- `dmesg` flooding with `NVRM: knvlinkUpdatePostRxDetectLinkMask_IMPL: Failed to update Rx Detect Link mask!`
  and/or `NVRM: knvlinkDiscoverPostRxDetLinks_GH100: Getting peer's postRxDetLinkMask failed!`
- One or more GPUs show `Recovery Action: Reset` in `nvidia-smi -q`
- `nvidia-smi nvlink -s -i <id>` reports `all links are inActive` on a specific GPU
  while other GPUs look fine
- `nvidia-smi -q -i <id>` shows `GPU Fabric GUID: System is not in ready state` /
  `CliqueId: 0` after the GPU had previously joined the clique

Physical NVLink is fine (line rate confirmed in `nvidia-smi nvlink -s`), chassis is
fine (peer nodes in clique are healthy), and rebooting is forbidden by the project
constraints.

## Root cause (observed 2026-05-28)

During a high-load benchmark, a chassis-side NVLink bandwidth query returned an
inconsistent value to the host driver (`linkBandwidthMBps1 != linkBandwidthMBps2`).
This triggered `nvAssertFailedNoLog` in `nv_gpu_ops.c`. The driver's self-protection
froze the NVLink topology discovery cache in a degraded state, and downstream NCCL
inherited the degraded topology and degenerated to a long ring.

Reboot would fix it; we are not allowed to reboot. The procedure below is what
worked: driver reload first, then per-GPU FLR for the GPU that didn't rejoin.

## Effect

Brought NCCL `all_reduce -g 4 -b 1G -e 8G` from busbw=48 GB/s back to busbw=687 GB/s
(14× recovery) on a single GB300 NVL72 compute node, without rebooting and without
touching chassis or IMEX configuration.

## Risk and scope

This procedure:
- Affects ONLY the local compute node. The 17 peer nodes are untouched.
- Briefly disconnects this node from the IMEX cluster (~10s). The IMEX gRPC
  channels reconnect automatically when `nvidia-imex` restarts.
- Does NOT modify any persistent file or service config.

It is reversible in the sense that the worst-case failure mode is "still in the
degraded state we started in." It does NOT magically fix chassis-side bugs.

## Hard prerequisites — DO NOT skip

1. Confirm physical NVLink is healthy: `nvidia-smi nvlink -s -i 0` should show
   18 × 53.125 GB/s. If link rate is wrong, this is not the right runbook.
2. Confirm all peer nodes are healthy: `bash scripts/health_check_peers.sh`.
   If peers are also degraded, fix peers first OR escalate — driver-side recovery
   on one node doesn't help if the rest of the cluster is broken.
3. Make sure no user CUDA workload is running. The procedure will briefly take
   down `/dev/nvidia*`.

## Procedure

### Step 1 — Backup IMEX persist state (cheap insurance)

```bash
cp -av /run/nvidia-imex/persist.dat /root/persist.dat.bak.$(date +%Y%m%d-%H%M%S)
```

### Step 2 — Stop the three services that hold `/dev/nvidia*` open

Order matters: dcgm and persistenced hold fds on every GPU; imex holds `/dev/nvidiactl`.

```bash
systemctl stop nvidia-dcgm           # releases nv-hostengine fds
systemctl stop nvidia-imex           # releases imex fds
systemctl stop nvidia-persistenced   # releases persistenced fds
```

Verify nothing is left holding GPU devices:

```bash
lsof /dev/nvidia* 2>/dev/null     # should be empty
lsmod | awk '/^nvidia/ {print $1, "ref="$3}'
# expect: nvidia ref=2 (only uvm + modeset internal),
#         nvidia_uvm ref=0, nvidia_drm ref=0, nvidia_modeset ref=1
```

### Step 3 — rmmod the GPU driver modules

In dependency order:

```bash
rmmod nvidia_drm        # ref=0 already
rmmod nvidia_modeset    # ref drops to 0 after drm gone
rmmod nvidia_uvm        # ref=0 after dcgm stopped
rmmod nvidia            # ref drops to 0 after the above
```

(`nvidia_cspmu` — the Grace CPU PMU — is independent and can be left alone.)

### Step 4 — Load the driver modules back

```bash
modprobe nvidia
modprobe nvidia_uvm
modprobe nvidia_modeset
modprobe nvidia_drm
```

`dmesg -T | tail -15` should show clean `[drm] [nvidia-drm] [GPU ID 0x...] Loading driver`
messages for all 4 GPUs. The "NUMA was not set up yet" notes are benign on Grace.

### Step 5 — Restart the three services

```bash
systemctl start nvidia-persistenced
systemctl start nvidia-imex
systemctl start nvidia-dcgm
sleep 10                # let fabric registration complete
```

`tail /var/log/nvidia-imex.log` should show all 17 peer gRPC channels re-establishing.

### Step 6 — Verify fabric state on each GPU

```bash
nvidia-smi -q -i 0,1,2,3 | grep -E "Fabric|State|Status|CliqueId|Recovery"
```

Expected: each GPU should show `State: Completed`, `Status: Success`, `CliqueId: 32766`,
`Recovery Action: None`.

If one or more GPUs come back as `Status: Not Supported` / `CliqueId: 0` /
`Recovery Action: Reset` and `nvidia-smi nvlink -s -i <id>` says `all links are inActive`,
that specific GPU did not re-join the fabric during the driver reload. Move to Step 7.

### Step 7 — Per-GPU FLR for any GPU that didn't rejoin

For each problem GPU id `N`:

```bash
# Stop services again (FLR requires no client holds /dev/nvidiaN)
systemctl stop nvidia-dcgm
systemctl stop nvidia-persistenced
lsof /dev/nvidia$N 2>/dev/null   # must be empty

# FLR
nvidia-smi -r -i $N
# Expect: "GPU 0000XX:06:00.0 was successfully reset. All done."

# Restart services
systemctl start nvidia-persistenced
systemctl start nvidia-dcgm
sleep 10
```

After FLR, re-check Step 6 — the GPU should now be in clique 32766 with all 18 NVLinks
back to 53.125 GB/s.

### Step 8 — Validate with NCCL

```bash
source ~/bench-bundle/scripts/env.sh
cd ~/bench-bundle/bin/single-node
./all_reduce_perf -b 1G -e 8G -f 2 -g 4
```

8 GiB busbw should be 600+ GB/s and `# wrong = 0`. If still degraded, escalate —
the cache-corruption pattern may not be the only thing broken.

## What this procedure does NOT fix

- Chassis-side bugs (NVSwitch SDN, partition assignment) — escalate to NMX-C operator
- Hardware NVLink degradation (line rate < 53.125 GB/s on `nvidia-smi nvlink -s`) — needs RMA
- IMEX cluster configuration drift (`nodes_config.cfg` corruption) — manual fix per CLAUDE.md
- The underlying chassis bandwidth-query inconsistency that triggered the assertion —
  this will recur on the next high-load benchmark until chassis side resolves it

## Telemetry to capture if you run this

Save the following with timestamps so the recurrence can be analyzed:

- `dmesg -T | grep -E "knvlink|nvAssert|Xid"` (before and after)
- `nvidia-smi -q -i 0,1,2,3` (before and after)
- `nvidia-smi nvlink -s` (before and after)
- The exact wall-clock time the issue was first noticed and when the workload that
  triggered it started
- Workload details (which collective, message size range)

This lets the chassis team correlate against their bandwidth-query traces.
