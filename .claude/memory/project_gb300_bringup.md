---
name: project-gb300-bringup
description: GB300 / NVL72 fabric bring-up state — fully online as of 2026-05-27 after weeks of NMX-C partition assignment blocker.
metadata: 
  node_type: memory
  type: project
  originSessionId: 744398e3-0804-4112-909d-65474272ec90
---

**Current state (2026-05-27):** Fabric fully UP on pega (192.168.15.153). Verified: fabric.state=Completed, CliqueId=32766, ClusterUUID=2d5e61c9-2f89-47e8-a163-14eee25d0f15, cuInit=0, dcgmi diag -r 1 software=Pass on all 4 GPUs. Cleared to run real workloads (GEMM / NCCL / nvbandwidth).

**Root cause of prior 3-week blocker:** chassis NMX-C had not pushed partition to compute nodes. Compute side was 100% ready the whole time (driver 595.71.05, IMEX 18/18 mesh UP, NVLink 4×18 links UP with 0 errors). Fix lived entirely on the switch tray: enable cluster + bring up `nmx-controller` running the full `sm / gfm / fib / gw-api` stack; NVLSM then ran `ar_minhop tables configured on all switches`, and Default Partition (32766, 72 GPUs) came up healthy. Config saved as startup Rev 4 so reboot survives.

**Why:** the 5/5 fabric restart took 18 nodes down for 3 weeks because the cluster config wasn't persisted as startup — every restart re-entered the same un-bootstrapped state.

**How to apply:**
- For *any* compute-side fabric symptom (cuInit=802, fabric.state=In Progress, CliqueId/ClusterUUID=N/A), do NOT chase it on the node. Hit the switch tray first: `nv show cluster`, `nv show cluster apps`, `nv show sdn partition`. Compute-side green is necessary but never sufficient.
- DCGM's `dcgmi diag -r 1` "Fabric Manager: training in progress" message is the canonical signature of this exact failure mode — quote it verbatim when escalating.

**A-model architecture lesson (Q1 answered):** one switch in this NVL72 runs sm + gfm + fib + gw-api for all 9 switches. nvlsm on that one node configures routing on all of them. Don't ssh into the other 8 unless that one is broken. See [[ref-nvos-switch]] for SSH details.

**Operational rule (Q2 answered):** **do NOT stop the fabric for end-of-day / overnight.** NVL72 is designed always-on like a datacenter switch — idle GPUs power down on their own, and re-bringup costs far more than steady-state running (the 5/5 incident is the precedent). If a maintenance window genuinely requires stopping: on the active switch run `nv set cluster state disabled && nv config apply && nv config save` (the save is critical — without it the next boot resurrects the prior state). Compute nodes need no action either way; driver/IMEX stay running and re-join automatically when fabric returns.

**Environment facts (do not re-derive):**
- pega: hostname=pega, IP=192.168.15.153, chassis SN=1824625475164, slot=1, tray=0, host_id=1
- NVL72 compute range: 192.168.15.137–154 (18 nodes), all currently READY in IMEX mesh
- Driver/GSP/IMEX version: 595.71.05 (do not mix with SOP's 570.26)
- BIOS: NVIDIA Carlo_Next 00.56.00 (20260317)
- Kernel: 6.17.0-1018-nvidia-64k
- Default Partition ID: 32766 (= CliqueId)
- Cluster UUID: 2d5e61c9-2f89-47e8-a163-14eee25d0f15
