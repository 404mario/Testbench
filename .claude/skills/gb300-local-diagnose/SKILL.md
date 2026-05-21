---
name: gb300-local-diagnose
description: Run read-only environment diagnostic on a GB300/NVL72 compute node. Reports CUDA / Fabric / IMEX / NCCL / cuBLAS / binary-architecture status. Use when the user asks "环境怎么样 / 怎么诊断 / diagnose / check env / 看看 GB300 状态".
---

# GB300 Local Diagnose

**Trigger when**: User asks to check/diagnose/inspect/audit the GB300 compute node environment, or wants a status snapshot before doing other work.

**Action**:

```bash
bash scripts/diagnose_gb300_env.sh
```

This script is **read-only**. It does NOT modify config, restart services, or touch any /etc paths.

**Interpret exit code**:
- `0` — all key items OK
- `1` — some warnings (likely non-blocking); check ⚠ lines
- `2` — severe missing items (likely blocking); check ✗ lines

**What it covers**:
- Host basics (hostname, arch, cores, RAM)
- CUDA toolkit + nvcc version
- 4× GB300 detection + driver version
- `fabric.state` — **this is the #1 thing to check**; if `In Progress`, CUDA will hang
- Services: `nvidia-imex`, `nvidia-persistenced`, `nvidia-fabricmanager` (FM should be absent or disabled on compute nodes)
- IMEX channel + `nodes_config.cfg` size (must be 18 for NVL72)
- NCCL/cuBLAS aarch64 libs
- Build toolchain (gcc/g++/make/cmake/nvcc/ibstat)
- `~/bench/*` binaries — must be aarch64, not x86

**Follow-up routes**:
- If `fabric.state = In Progress` → invoke skill `gb300-fabric-escalation`
- If `~/bench/*` binaries are x86 → invoke skill `gb300-build-aarch64`
- All green → proceed with normal Testbench workflow

**Hard limits**: This skill MUST NOT restart any service, MUST NOT modify `/etc/nvidia-imex/`, MUST NOT `apt install` anything, MUST NOT reboot.
