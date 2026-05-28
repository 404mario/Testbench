---
name: project-gb300-bringup
description: GB300 NVL72 bring-up 当前状态（2026-05-28）：fabric 已 unblock，72-GPU 全量测试完成；新风险点是 driver NVLink topology cache 中毒。
metadata: 
  node_type: memory
  type: project
---

**当前状态（2026-05-28）：bring-up 完成**

本节点（`192.168.15.137`，18 节点 NVL72 之一）4 GPU 全部加入 clique 32766，72-GPU 全量测试通过。

**注意 hostname 误导**：所有 18 节点 hostname 都叫 `pega`（共享 hostname 配置），用 IP 区分。原 CLAUDE.md 把本节点写成 `.153`，实测是 `.137`。

**今天完成的工作（2026-05-28）**：

1. **Spec 更新**：`spec/GB300_specs.full.json` 写入完整 datasheet 元数据（架构/HBM3e/NVLink/PCIe6.0/全 dtype TFLOPS dense+sparse/TDP 1400W）；`GB300_specs.json` 加注释说明 binary 选 spec 的 bug
2. **Driver topology cache 修复**：成功用 driver reload + GPU 2 FLR 把 NCCL all_reduce 4-GPU busbw 从降级 48 GB/s 恢复到 687 GB/s，未 reboot 未动 chassis。详见 `docs/runbooks/driver-topology-cache-fix.md`
3. **72-GPU 全量测试**：18 节点 × per-node (gemm 6 dtype + stream + nvbandwidth 含 PCIe) + 72-rank MPI 7 个 NCCL collective 全过。报告 `docs/reports/2026-05-28-72gpu-full.md`
4. **新机器 bring-up SOP**：`docs/runbooks/new-machine-bringup.md` + `README.md` + 一键脚本 `scripts/run_72gpu_full.sh` / `scripts/health_check_peers.sh` / `scripts/aggregate_72gpu.py`

**关键性能数据（2026-05-28，72 GPU 跨 18 节点）**：

- GEMM: fp64 1.10 TFLOPS (85% peak)、fp8_e4m3 4342 TFLOPS (85% peak)，72-GPU stddev < 1%
- STREAM: Copy/Scale ~6983 GB/s、Add/Triad ~7097 GB/s (87-89% of HBM3e 8000 peak)
- nvbandwidth dev↔dev bidir read 1527 GB/s (85% of 1800 NVLink peak)
- nvbandwidth Grace-C2C host↔device 211 GB/s 单向（注意是 C2C 不是 PCIe）
- 72-rank NCCL all_reduce 8 GiB peak busbw **881 GB/s**（其他 6 个 collective 655-712），0 wrong

**已知遗留问题**：

1. **Binary spec 选错**：`bench_gemm`/`stream`/`nvbandwidth`/`all_reduce_perf` 把 GPU name `NVIDIA GB300` 硬编码映射到 `B300_specs.json` 不是 GB300。修需重编 `detect_spec_filename()`
2. **Driver state 脆弱性**：driver 内 NVLink 拓扑缓存会被 chassis 端一次 bandwidth 查询不一致触发的 assertion 冻在降级状态。运行高负载 NCCL 会再次触发。**长期需要 chassis 端解决 bandwidth 查询不一致**，否则只能反复 driver reload+FLR
3. **NCCL busbw 距 NVLink peak 还有空间**：8 GiB all_reduce 881 GB/s vs NVLink physical 1800 GB/s 双向 ~49%。如要进一步压榨可调 `NCCL_ALGO=NVLS` / `NCCL_PROTO=Simple` / `NCCL_NCHANNELS_PER_PEER`

**Why:** 5/22 之前 fabric 一直 In Progress (chassis 侧 SDN partition 未下发)；后续 chassis 端解决了。5/27 跑出 baseline。5/28 跑首次高负载触发了上述 driver state 中毒，今天用 driver reload + FLR 恢复并完成全量测试。

**How to apply:**
- 任何 NCCL busbw 突然垮（比 baseline 低 50%+）：先查 [[driver-topology-cache-fix]] 而不是怀疑硬件
- 跑 72-GPU 测试前必须先 `bash scripts/health_check_peers.sh`；任何 peer 不健康则停下来报告而不是绕过
- 日常烟测用 `bash scripts/run_72gpu_full.sh`（12-15 分钟，全自动化包含健康检查+per-node+cluster+aggregation）
