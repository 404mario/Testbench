---
name: gb300-fabric-escalation
description: Handle the case where fabric.state on GB300 compute node is stuck "In Progress" (CUDA hangs/802). Collects diagnostic evidence into diagnostics/fabric_evidence_<ts>/, generates the question packet for cluster ops/NVSwitch OS admins, and guides toward proper escalation. Use when user reports "CUDA hang / 802 / fabric stuck / GPU 不能初始化 / 升级问题给运维".
---

# GB300 Fabric Bring-up Escalation

**Trigger when**: 
- `nvidia-smi --query-gpu=fabric.state` shows `In Progress` and isn't changing
- CUDA programs hang on `cudaGetDeviceCount` or return `802 (system not yet initialized)`
- User wants to send a diagnostic packet to ops / mentor / NVSwitch OS admin
- User asks "怎么升级 fabric 问题"

**Root cause (already verified)**: GB300 NVL72 compute nodes do NOT have local NVSwitch hardware (NVSwitches live in the Kyber chassis, managed by NVSwitch OS / NMX-C). Therefore:
- Running `nvidia-fabricmanager` locally fails with `NV_WARN_NOTHING_TO_DO` (no devices to manage)
- The fix is NOT on the compute node — it requires chassis-side SDN partition assignment
- Compute-node-side: stop trying to fix; collect evidence; escalate

**Action**:

```bash
# 1. Collect evidence (read-only, ~10s)
bash scripts/collect_fabric_evidence.sh

# Outputs: diagnostics/fabric_evidence_<YYYYMMDD-HHMM>/
# Contents: nvidia-smi snapshot, fabric query, services, journals,
#           IMEX log tails, FM log, dmesg, IB state, package list, SUMMARY.md
```

**Then read** `docs/runbooks/gb300-fabric-escalation.md` — that doc has:
- The verbatim question list to send to ops/NVSwitch OS admin
- Expected ops actions on NVSwitch OS side (`nv show sdn partition`, `nv action create sdn partition ...`)
- How to verify on compute node after ops fixes it
- What to do if state still stuck after ops action

**While waiting for ops**, productive work that does NOT need fabric:
- `gb300-build-aarch64` skill — recompile binaries for aarch64
- Write/update docs, scripts, skills
- `gb300-daily-sync` skill — commit + push

**Hard limits — ABSOLUTELY DO NOT**:
- `systemctl start nvidia-fabricmanager` (will fail, confirmed)
- `systemctl restart nvidia-imex` (would re-handshake cluster; `persist.dat` re-keys)
- Modify `/etc/nvidia-imex/nodes_config.cfg` (18-node config must stay intact)
- Modify `/etc/modprobe.d/nvidia.conf`
- `apt purge` the FM package (kept installed for ops to use with correct config)
- reboot

**If user pushes you to "just fix it"**: explain that the SDN partition assignment is owned by NVSwitch OS / NMX-C. Even with full root on compute nodes, that's the wrong layer. Show them `docs/runbooks/gb300-fabric-escalation.md` and the SUMMARY.md from the evidence packet.
