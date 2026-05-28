# Testbench (404mario/Testbench)

GPU 集群性能测试工具源码 + 运行脚本。当前任务：在 GB300 / NVL72 上做 bring-up 与日常烟测。

## 硬件目标

- **NVL72 机柜**：18 个 compute node × 4 GPU = 72 GPU，Kyber 托盘 + 外置 NVSwitch
- **单节点**：4× NVIDIA GB300 (Blackwell Ultra, sm_100, 288 GiB HBM3e)，NVIDIA Grace (aarch64) CPU, Ubuntu 24.04
- **CUDA**: 13.2 (`/usr/local/cuda-13`), **driver**: `nvidia-dkms-open 595.58.03`（**open** kernel module 分支）
- **NCCL**: 2.29.7 (`/lib/aarch64-linux-gnu/`), **cuBLAS**: 13.4 (`/usr/local/cuda/targets/sbsa-linux/lib/`)
- 本地工作节点示例：`192.168.15.137`（hostname `pega`；注意 18 节点都叫 `pega`，用 IP 区分）；IMEX 集群 `192.168.15.137`–`192.168.15.154`

## 当前关键状态（2026-05-28）

✅ **Bring-up 完成**：72 GPU 全部在 clique 32766；72-GPU 全量测试通过。当日报告 [`docs/reports/2026-05-28-72gpu-full.md`](docs/reports/2026-05-28-72gpu-full.md)。

⚠️ **新风险点**：driver 内 NVLink topology cache 会被 chassis 端 bandwidth 查询不一致触发的 assertion 冻在降级状态（NCCL busbw 可能从 600+ 跌到 48 GB/s）。修复 SOP 见 [`docs/runbooks/driver-topology-cache-fix.md`](docs/runbooks/driver-topology-cache-fix.md) — driver reload + 单 GPU FLR，未 reboot 未动 chassis 即可恢复。长期需 chassis 端修复 bandwidth 查询不一致。

## 仓库 ↔ ~/bench 分工

| 角色 | 路径 | 入 git？ |
|------|------|---------|
| 工具源码 | `gemm_tests/`、`stream_tests/`、`nccl_tests/`、`nvbandwidth_tests/` | ✅ |
| 运行脚本权威源 | `scripts/run_parallel_test.sh` | ✅ |
| 自动化脚本 | `scripts/diagnose_gb300_env.sh`、`collect_fabric_evidence.sh`、`build_aarch64_tools.sh`、`daily_snapshot.sh` | ✅ |
| Spec（运行时契约 + 元数据） | `spec/GB300_specs.json`（扁平契约）、`spec/GB300_specs.full.json`（嵌套元数据） | ✅ |
| Runbook / 协作约定 | `CLAUDE.md`、`docs/runbooks/`、`.claude/skills/` | ✅ |
| **部署/运行工作区** | `~/bench/` (二进制 + spec + result + 部署版脚本) | ❌ 永不入 git |
| 编译产物 | `nccl_tests/build/`、`nvbandwidth_tests/{CMakeCache.txt,CMakeFiles/,nvbandwidth}`、顶层 `bench_gemm` 等 | ❌ 见 `.gitignore` |

部署流程：编完产物 → `cp` 到 `~/bench/` → 在 `~/bench/` 跑 `run_parallel_test.sh`。

## 硬约束（永远不要做）

1. **不要 reboot**
2. **不要重启** `nvidia-imex` / `nvidia-fabricmanager` / `sshd` / `nvidia-persistenced`（`/run/nvidia-imex/persist.dat` 是集群协商状态）
3. **不要修改** `/etc/nvidia-imex/`（特别是 `nodes_config.cfg` 必须保持 18 节点，参考 IP `192.168.15.137`–`192.168.15.154`）
4. **不要修改** `/etc/ssh/`；**不要在跳板机上配置免密**；只在 compute 节点之间互信
5. **不要修改** `/etc/modprobe.d/nvidia.conf`（驱动加载参数）
6. **不要 sudo apt install / apt purge** 任何包，除非用户明确同意
7. **不要 commit**：编译产物、`result/`、token、BMC 密码、私钥、`.env`、ssh 密钥
8. **不要把 127.0.0.1 / localhost** 写进 `node` 文件后再用 `all` 模式跑跨节点测试
9. **不要把跳板机当 master**

## 常用入口

| 想做的事 | 命令 |
|---------|------|
| 只读环境诊断 | `bash scripts/diagnose_gb300_env.sh` |
| 收集 fabric 证据包（给运维） | `bash scripts/collect_fabric_evidence.sh` |
| 编译 4 个工具 aarch64 版本 | `bash scripts/build_aarch64_tools.sh` |
| 当天结束 commit + push | `bash scripts/daily_snapshot.sh` |
| 18 节点 fabric 健康检查 | `bash ~/bench-bundle/scripts/health_check_peers.sh` |
| **72-GPU 全量烟测**（per-node + cluster + 报告） | `bash ~/bench-bundle/scripts/run_72gpu_full.sh` |
| 单节点本地 4-GPU 烟测 | `cd ~/bench-bundle/bin/single-node && ./all_reduce_perf -b 1G -e 8G -f 2 -g 4` |
| NCCL busbw 突然垮（中毒恢复） | 见 `docs/runbooks/driver-topology-cache-fix.md` |

## 已知问题快速索引

详见 `docs/runbooks/gb300-known-issues.md`：

- `ConnectFail` 真正含义（不是 ssh 连接失败，是结果 JSON 没产出）
- x86_64 ELF 在 aarch64 上的 `Exec format error`
- `fabric.state = In Progress` + `cudaGetDeviceCount` hang
- NVL72 compute node **不能本机跑 FabricManager**（NVSwitch 在 chassis）
- spec schema 契约（4 个二进制都按扁平 schema 读）

## 上游 README（Testbench 工具）

`scripts/run_parallel_test.sh` 来自 OSS 包 `bench_parallel_nodes_v1.8.tar.gz`（标注 v8 = v1.8）。原 README 已并入 `docs/runbooks/`。该脚本：
- 第一个参数 = 工具名或 `all_case`；之后到 `--` 之间是节点列表；`--` 后透传给二进制
- 对 `127.0.0.1` / `localhost` 走本地 `cp + exec` 分支（不需 ssh）
- 工具：`bench_gemm` / `stream` / `all_reduce_perf` / `alltoall_perf` / `nvbandwidth`

## Plan 文件

当前 bring-up 任务实施计划：`/root/.claude/plans/gb300-compute-node-jaunty-comet.md`
