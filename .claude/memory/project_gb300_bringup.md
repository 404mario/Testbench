---
name: project-gb300-bringup
description: GB300 NVL72 bring-up state — fabric UP since 2026-05-27, 72-GPU full acceptance pass 2026-05-28; new risk class is driver NVLink topology cache vulnerability.
metadata: 
  node_type: memory
  type: project
---

**当前状态（2026-05-28）：bring-up 完成**

72 GPU 全部在 clique 32766。fabric+IMEX+driver+NCCL 全栈跑通。已通过 72-GPU 全量 acceptance（per-node gemm/stream/nvbandwidth + 7 个 NCCL collective 0 wrong）。

**Hostname 误导**：18 节点 hostname 都叫 `pega`（共享镜像漏改），用 IP 区分。本节点示例：`192.168.15.137`。原 CLAUDE.md 记的 `.153` 是另一次会话所在节点。

---

## 历程时间线

### 5/22 之前：fabric blocked
`fabric.state = In Progress`、`cuInit=802`。3 周阻塞。Root cause = chassis NMX-C 没把 partition 下发给 compute 节点（compute 侧 100% ready 全程）。

### 5/27：fabric UP + 72-GPU baseline 跑出
Fix 全在 switch tray：enable cluster + 把 `nmx-controller` 跑全栈 `sm / gfm / fib / gw-api`；NVLSM `ar_minhop tables configured`；Default Partition 32766 (72 GPU) 起来。Config 存 startup Rev 4。验证 fabric.state=Completed, CliqueId=32766, ClusterUUID=`2d5e61c9-2f89-47e8-a163-14eee25d0f15`, cuInit=0, dcgmi diag -r 1 software=Pass。跑了 7 个 NCCL collective，all_reduce peak 747.54 GB/s @ 1 GiB。

### 5/28：driver topology cache 中毒 → 修复 → 全量 acceptance
首次高负载 NCCL 触发 chassis 端 bandwidth 查询不一致 → driver `nvAssertFailedNoLog` → NVLink topology 缓存冻在降级态。NCCL all_reduce busbw 从 baseline 646 跌到 48 GB/s。修复路径（未 reboot、未动 chassis、未动 IMEX 配置）：driver reload (rmmod+modprobe) → GPU 2 单卡 FLR → 14× 恢复到 687 GB/s。流程入 [`docs/runbooks/driver-topology-cache-fix.md`](../../docs/runbooks/driver-topology-cache-fix.md)。修复后跑完 72-GPU 全量，peak all_reduce 881 GB/s @ 8 GiB，72-rank 0 wrong。报告 [`docs/reports/2026-05-28-72gpu-full.md`](../../docs/reports/2026-05-28-72gpu-full.md)。

---

## 关键性能数据（2026-05-28，72 GPU 跨 18 节点）

- GEMM: fp64 1.10 TFLOPS (85% peak)、fp8_e4m3 4342 TFLOPS (85% peak)，72-GPU stddev < 1%
- STREAM: Copy/Scale ~6983 GB/s、Add/Triad ~7097 GB/s (87-89% of HBM3e 8000 peak)
- nvbandwidth dev↔dev bidir read 1527 GB/s (85% of 1800 NVLink peak)
- nvbandwidth Grace-C2C host↔device 211 GB/s 单向（注意是 C2C 不是 PCIe）
- 72-rank NCCL all_reduce 8 GiB peak busbw 881 GB/s（其他 6 个 collective 655-712），0 wrong

---

## 架构关键事实（不要再 derive）

- **A-model switch 架构**（5/27 学到）：本 NVL72 一个 switch 跑 `sm + gfm + fib + gw-api` 全栈，nvlsm 在它上面 config 全部 9 个 switch 的 routing。compute 节点正常运行无需手动登入其他 switch
- **Operational rule（来自 5/5 incident）**：**don't stop fabric**，哪怕过夜也别。NVL72 设计是 always-on，idle GPU 自己 power down，重 bring-up 成本远高于稳态运行。维护窗必须停时：active switch 上 `nv set cluster state disabled && nv config apply && nv config save`（save 必须做，否则下次启动恢复旧态）
- **环境锚定值**：driver/GSP/IMEX 595.71.05；CUDA 13.2；NCCL 2.29.7；BIOS NVIDIA Carlo_Next 00.56.00；Kernel 6.17.0-1018-nvidia-64k；Default Partition 32766；Cluster UUID `2d5e61c9-2f89-47e8-a163-14eee25d0f15`

---

## 已知遗留问题

1. **Binary spec 选错**：`bench_gemm`/`stream`/`nvbandwidth`/`all_reduce_perf` 把 GPU name `NVIDIA GB300` 硬编码映射到 `B300_specs.json` 不是 GB300。修需重编 `detect_spec_filename()`
2. **Driver state 脆弱性**：driver 内 NVLink 拓扑缓存会被 chassis 端一次 bandwidth 查询不一致触发的 assertion 冻在降级状态。运行高负载 NCCL 会再次触发。**长期需要 chassis 端解决 bandwidth 查询不一致**，否则只能反复 driver reload+FLR
3. **NCCL busbw 距 NVLink peak 还有空间**：8 GiB all_reduce 881 GB/s vs NVLink physical 1800 GB/s 双向 ~49%。如要进一步压榨可调 `NCCL_ALGO=NVLS` / `NCCL_PROTO=Simple` / `NCCL_NCHANNELS_PER_PEER`

---

## How to apply

- 任何 NCCL busbw 突然垮（比 baseline 低 50%+）：先查 [[driver-topology-cache-fix]] 而不是怀疑硬件
- 跑 72-GPU 测试前必须先 `bash scripts/health_check_peers.sh`；任何 peer 不健康则停下来报告而不是绕过
- 日常烟测用 `bash scripts/run_72gpu_full.sh`（12-15 分钟，全自动化包含健康检查+per-node+cluster+aggregation）
- 任何 compute-side fabric 症状（cuInit=802, fabric.state=In Progress, CliqueId/ClusterUUID=N/A）：**不要在节点上 chase**，直接 switch tray `nv show cluster / cluster apps / sdn partition`。compute 侧绿是必要不充分条件
- DCGM `dcgmi diag -r 1` "Fabric Manager: training in progress" = 上述 fabric 故障的 canonical signature，escalation 时原样引用
