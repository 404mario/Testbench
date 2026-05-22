---
name: project-gb300-bringup
description: 当前 GB300 NVL72 bring-up 阻塞点（fabric/CUDA）、已完成的工作（aarch64 二进制 + 仓库脚手架 + 上游/容器隔离验证）、下一步等待项。
metadata: 
  node_type: memory
  type: project
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

**事实**：本节点（hostname `pega`，`192.168.15.153`，18 节点 NVL72 之一）**CUDA runtime 不可用**。`fabric.state = In Progress`，`CliqueId/ClusterUUID/Partition Assigned` 全 N/A。

**Why:** GB300 NVL72 Kyber 架构里 NVSwitch 在 chassis（不在 compute node），所有 NVLink 流量（含同节点 GPU0↔GPU1）都走外置 NVSwitch。driver gate `cudaInit` 在 chassis 侧 SDN partition assignment。chassis 不下发 partition 时，**单卡都启动不了**——这是 NVL72 的硬性架构约束（不像 DGX H100 还能丢 NVLink 凑合单卡）。

**API 行为分歧（2026-05-22 修正）**：同一个 fabric blocker 在不同 CUDA API 下表现不同：
- **driver API** `cuInit(0)` → **fast-fail，返 `CUDA_ERROR_SYSTEM_NOT_READY` (errno 802)**
- **runtime API** `cudaGetDeviceCount` / `cudaSetDevice` → **无限 hang**（runtime 内部等 driver ready）
- 实现影响：我们自己的 4 工具（bench_gemm / stream 等）应在 main 顶部加 `cuInit()` early-probe，把 hang 改成 fast-fail；上游 nvbandwidth 已经是这种行为

**How to apply:**
- 任何"绕过 fabric 做本地测试"的提议都不可行：127.0.0.1 模式不行（cudaInit 仍 802/hang），跨节点 master/worker 不行（18 节点共享 chassis fabric，预计全 stuck）
- 解锁的**唯一**路径：进 NVOS switch `192.168.15.171` 跑 `nv action create sdn partition ...`（见 [[ref-nvos-switch]]）；要么自己有凭据，要么走运维
- 同时编译/部署/文档/skill **全部不依赖 fabric**，可以推进到 fabric 修好

**已完成（2026-05-21）**：
- `nvidia-fabricmanager 595.58.03-1ubuntu1` 装了（精确匹配 driver），service `disabled`，包**保留**给运维改 config 后用
- FM 启动验证：`NV_WARN_NOTHING_TO_DO`（本机无 NVSwitch 设备），符合 NVL72 设计；不再尝试本节点 FM
- 4 工具 aarch64 重编完成并部署到 `~/bench/`（`stream`/`bench_gemm`/`nvbandwidth`/`nccl_tests/*_perf`）
- 仓库脚手架入库：CLAUDE.md / .gitignore / 4 runbook / 4 script / 4 skill / 2 spec / vendored run_parallel_test.sh

**新增（2026-05-22）—— mentor 主导的两段隔离实验**（详见 [[feedback-mentor-debug-pattern]]）：
- **隔离 1：上游 vanilla nvbandwidth**。`/root/nvbandwidth-upstream/` clone NVIDIA/nvbandwidth main (HEAD `4a49bda`，v0.9 merge)，native aarch64 cmake+make 一次成功。`cuInit(0)` → 802。**排除我们 Testbench fork 改坏 + 排除我们 build chain 问题**。
- **隔离 2：NGC 官方容器**。装了 `docker.io` (29.1.3) + `nvidia-container-toolkit` (1.19.1)，配 `nvidia` runtime；pull `nvcr.io/nvidia/pytorch:26.04-py3` (arm64/linux, 35 GB on disk)。容器 entrypoint 自检脚本一启动就报 `[[ System not yet initialized (error 802) ]]`；容器内 `nvidia-smi` 正常枚举 4 卡（NVML 不依赖 fabric）；容器内跑 vanilla nvbandwidth → 同样 802。**排除 user-space 一切可能**。
- **结论**：错误源在 kernel driver 层，唯一未排除项 = chassis 侧 NMX-C/GFM/NVLSM 没把本节点 4 卡 onboard 到 fabric。NVIDIA 自己的 NGC 容器自检逻辑等于帮我们打了认证。

**架构认知修正（2026-05-22，来自 NVIDIA IMEX Guide）**：之前 runbook 措辞"等 fabricmanager 起来"不准。NVL72 上 GFM+NVLSM 打包成 **NMX-C 跑在 L1 NVSwitch tray**，**compute node 上不该跑 `nv-fabricmanager` 服务**（这就是为什么我们看到的 service inactive 是正确状态）。IMEX 不是替代 fabricmanager —— 两者职责不同（fabric 管路由 / IMEX 管 cross-node memory）。Runbook 里所有"fabric"措辞应改为"chassis NMX-C 编入 partition"，更精确也更难被运维推回来。Sources：https://docs.nvidia.com/multi-node-nvlink-systems/imex-guide/overview.html

**Pending（等运维或外部条件）**：
- NVOS 凭据 → fabric.state Completed → `cuda_probe` 应返回 4 GPU → Testbench 烟测可跑
- 把今天的容器/上游证据整进 `docs/runbooks/gb300-fabric-escalation.md`（**用户暂缓**，等他回到节点再说）
- commit + push 今天的工作（待用户拍板）

**Docker / 容器状态**：pega 节点上 docker.io + nvidia-container-toolkit 已装且配置好；NGC PyTorch 26.04-py3 镜像 35 GB 已在 `/var/lib/docker/`，修好后可立即用同一镜像复验。`/root/nvbandwidth-upstream/` 保留作干净对照组。

**bringup blocker 完整诊断文档**：`docs/runbooks/gb300-fabric-bringup-blocker.md`（已入仓库）。
**escalation SOP**：`docs/runbooks/gb300-fabric-escalation.md`（已入仓库）。
