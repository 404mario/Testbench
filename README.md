# Testbench — GB300 / NVL72 Acceptance Bundle

GPU 集群性能测试工具 + 脚本 + spec，专为 **NVIDIA GB300 (Blackwell Ultra) on NVL72** 18-节点机柜的 acceptance 测试。

> **本仓库是源码 + 构建脚本 + 文档。**
> 如果你只是想在已配好的 NVL72 上跑测试，**直接用 OSS 上的 `testbench-gb300-2026-05-28.tar.gz`**（含预编 aarch64 binary）—— 见下面"下载"段。
> 想自己从源码 build：`bash scripts/build_aarch64_tools.sh`（需要 GB300 节点 + CUDA 13 + nvcc）。

---

## 下载（OSS 镜像）

国内（上海）：

```bash
curl -LO https://oss-cn-shanghai.siflow.cn/scitix-release/testbench-gb300-2026-05-28.tar.gz
```

海外（马来）：

```bash
curl -LO https://oss-ap-southeast.scitix.ai/scitix-release/testbench-gb300-2026-05-28.tar.gz
```

校验（两个镜像同名同内容，任一即可）：

```bash
sha256sum testbench-gb300-2026-05-28.tar.gz
# 应得: 87dc0ff55705e8fa71bcf9ad7601d0ec53305d62e28f636084c01ee5f43e9af9
```

| 项 | 值 |
|---|---|
| 大小 | 41 MiB（压缩） / 243 MiB（解压） |
| SHA256 | `87dc0ff55705e8fa71bcf9ad7601d0ec53305d62e28f636084c01ee5f43e9af9` |
| ETag (S3 multipart, 3 parts) | `59ea505e73d91b05368abfd5abd69b16-3` |
| 上传日期 | 2026-05-28 |
| 两镜像一致性 | ✅ ETag 完全相同 |

---

## 内容清单

```
testbench-gb300-2026-05-28/
├── README.md                       ← 本文件
├── bin/
│   ├── single-node/                ← 单节点本地跑（每个节点的 4 GPU）
│   │   ├── bench_gemm              cuBLASLt GEMM, 6 dtype (fp64/fp32/tf32/bf16/fp16/fp8_e4m3)
│   │   ├── stream                  HBM3e 带宽 (Copy/Scale/Add/Triad)
│   │   ├── nvbandwidth             NVLink/PCIe/Grace-C2C 带宽
│   │   ├── all_reduce_perf         NCCL 4-GPU 单机 all_reduce
│   │   └── alltoall_perf           NCCL 4-GPU 单机 alltoall
│   └── mpi/                        ← 72-GPU 集群跑（mpirun 协调 18 节点）
│       ├── all_reduce_perf_mpi
│       ├── alltoall_perf_mpi
│       ├── all_gather_perf_mpi
│       ├── broadcast_perf_mpi
│       ├── reduce_perf_mpi
│       ├── reduce_scatter_perf_mpi
│       └── sendrecv_perf_mpi
├── spec/
│   ├── GB300_specs.json            扁平 runtime 阈值（binary 直接读，判 Pass/Fail）
│   └── GB300_specs.full.json       完整 datasheet 元数据（架构、HBM3e、NVLink、PCIe、TDP、全 TFLOPS）
├── scripts/
│   ├── env.sh                      运行前必 source，统一 PATH/LD_LIBRARY_PATH/NCCL/UCX/MPI 环境
│   ├── hostfile.nvl72.example      18 节点 IP × 4 slot 的 MPI hostfile 模板（**用前必改为你的真实 IP**）
│   ├── health_check_peers.sh       并行 SSH 跑 fabric 健康检查（任何 peer 不健康即 abort）
│   ├── run_72gpu_full.sh           ★ 一键：健康检查 + per-node 全 18 节点测 + 72-rank 集群 + 自动汇总 report
│   ├── runner_cluster.sh           单个 collective 的 72-rank mpirun wrapper（targeted 调试用）
│   ├── run_parallel_test.sh        legacy: 单工具跨节点 fan-out runner（每节点独立跑同一工具）
│   ├── aggregate_72gpu.py          解析 raw output → aggregated.json + report.md（被 run_72gpu_full.sh 调用）
│   └── fix_imex_channels.sh        修 IMEX channel0 device 缺失（一些机器从镜像装起 17/18 节点要补）
└── docs/
    ├── driver-topology-cache-fix.md   ★ 如果 NCCL busbw 突然降级（chassis 端 bandwidth query 不一致触发 driver assert），按这个 SOP 修复（rmmod + 单 GPU FLR，不 reboot 不动 chassis）
    ├── gb300-known-issues.md          典型坑/症状索引
    └── gb300-fabric-escalation.md     fabric 出问题需找运维时的证据收集 SOP
```

---

## 环境要求

测试节点必须满足：

| 项 | 要求 | 检查命令 |
|---|---|---|
| 硬件 | NVIDIA GB300 × 4，NVL72 chassis（18 节点共享 NVSwitch tray） | `nvidia-smi --query-gpu=name --format=csv` 应有 4 行 `NVIDIA GB300` |
| OS | Linux aarch64（Grace CPU），推荐 Ubuntu 24.04 | `uname -m` = `aarch64` |
| Driver | `nvidia-dkms-open` 595.x | `nvidia-smi --query-gpu=driver_version --format=csv,noheader -i 0` |
| CUDA | 13.x，安装在 `/usr/local/cuda-13/` | `ls /usr/local/cuda-13/bin/nvcc` |
| NCCL | 2.29.x（`/lib/aarch64-linux-gnu/libnccl.so.2`） | `ls /lib/aarch64-linux-gnu/libnccl.so.2` |
| OpenMPI | 4.1.9a1（NVIDIA HPC-X 风格安装在 `/usr/mpi/gcc/openmpi-4.1.9a1/`） | `ls /usr/mpi/gcc/openmpi-4.1.9a1/bin/mpirun` |
| Fabric | clique 32766 已分配；`nvidia-smi -q` 看 `State: Completed` | `nvidia-smi -q \| grep -E 'fabric\|clique\|State' \| head -5` |
| IMEX | `nvidia-imex` active 且与其他 17 个 peer 节点 gRPC 通 | `systemctl is-active nvidia-imex && tail /var/log/nvidia-imex.log` |
| SSH 互信 | 18 个 compute 节点之间 root any-to-any 免密 | `ssh -o BatchMode=yes root@<peer-ip> hostname` |

如果不满足 fabric / IMEX / SSH 互信，**不要尝试运行集群测试** — 先看 `docs/runbooks/gb300-fabric-escalation.md`。

---

## 部署（在任一节点上）

```bash
# 1. 解压到 ~/bench-bundle/
mkdir -p ~/bench-bundle
tar xzf testbench-gb300-2026-05-28.tar.gz -C ~/
mv ~/testbench-gb300-2026-05-28 ~/bench-bundle
ls ~/bench-bundle/                # 应看到 bin/ spec/ scripts/ docs/ README.md

# 2. 改 hostfile 为你的真实 IP（默认假设 192.168.15.137–154，按需修改）
cp ~/bench-bundle/scripts/hostfile.nvl72.example ~/bench-bundle/scripts/hostfile.nvl72
$EDITOR ~/bench-bundle/scripts/hostfile.nvl72   # 改成你环境里的 18 个 IP

# 3. 同步整个 bundle 到其他 17 个节点（per-node 测试需要每个节点本地有 binary）
for ip in $(awk '{print $1}' ~/bench-bundle/scripts/hostfile.nvl72); do
  # skip self
  hostname -I | grep -q "$ip" && continue
  rsync -a ~/bench-bundle/ "root@$ip:~/bench-bundle/"
done
```

---

## 跑测试

### Step 1. source 环境（每次新 shell 都要）

```bash
source ~/bench-bundle/scripts/env.sh
```

这会设 `PATH`（加 mpirun）、`LD_LIBRARY_PATH`（CUDA + MPI）、`NCCL_SOCKET_IFNAME=enP5p9s0`、`UCX_TLS=tcp,self,sm` 等。**所有后续命令都假设你已经 source 过**。

> 注意：`env.sh` 里 `enP5p9s0` 是 NVL72 默认管理网卡名。如果你环境不一样，先 `ip -4 addr` 看一下再改 `env.sh`。

### Step 2. 18 节点 fabric 健康检查（30s）

```bash
bash ~/bench-bundle/scripts/health_check_peers.sh
```

输出表格列出每节点的 fabric State / CliqueId / Recovery Action / 最近 5 分钟 dmesg assert 计数。

预期：所有 18 行都是 `completed=4 not_ready=0 clique=4 recovery=0 asserts=0`，最后一行 `ALL HEALTHY — safe to launch 72-GPU cluster tests.`

**如果有 peer 不健康**：不要继续，先看 `docs/runbooks/driver-topology-cache-fix.md`（最常见原因是 driver topology cache 中毒，可在节点内修复，不需 reboot）。

### Step 3. 单节点烟测（1-2 min，确认本机 binary + spec 工作）

```bash
cd ~/bench-bundle/bin/single-node
cp ~/bench-bundle/spec/*.json .                                  # binary 在 CWD 找 spec 文件
./bench_gemm --dtype=fp64 --iters=10                             # ~1 min, ≈1.10 TFLOPS/GPU
./stream                                                          # ~10s, Copy ≈6900 GB/s, Triad ≈7100 GB/s
./nvbandwidth -t device_to_device_bidirectional_memcpy_read_ce   # ~30s, ≈1527 GB/s
./all_reduce_perf -b 1G -e 8G -f 2 -g 4                          # ~30s, 8 GiB busbw ≥ 600 GB/s
```

检查 `gemm_result.json` 等输出：`gpu_info.target_spec_file` 应该是 **`GB300_specs.json`**（不是 B300）。

### Step 4. 完整 72-GPU 全量 acceptance（12-15 min）

```bash
bash ~/bench-bundle/scripts/run_72gpu_full.sh
```

自动执行：
1. 18 节点 fabric 健康检查（任何不健康即 abort）
2. Per-node 并行测试：18 节点 × (gemm 6 dtype + stream + nvbandwidth 6 test)，约 3-4 min
3. 集群 7 个 NCCL collective（72-rank MPI），约 7 min
4. 聚合 raw output → `aggregated.json` + `report.md`

完成后查报告：

```bash
RESULTS=~/bench-bundle/results_72gpu/$(date +%Y-%m-%d)
cat $RESULTS/report.md
```

**预期峰值参考（健康集群）**：

| 测试 | 单节点 / 单 GPU | 72-GPU 集群 |
|---|---|---|
| GEMM fp64 | ~1.10 TFLOPS | — |
| GEMM fp8_e4m3 | ~4340 TFLOPS | — |
| STREAM Triad | ~7100 GB/s | — |
| nvbandwidth NVLink dev↔dev bidir | ~1527 GB/s | — |
| nvbandwidth Grace-C2C host↔device | ~211 GB/s | — |
| NCCL all_reduce @ 8 GiB | ~687 GB/s (4-GPU) | **~881 GB/s** (72-rank) |
| NCCL alltoall @ 8 GiB | — | ~655 GB/s |

如果 NCCL busbw 比预期低 50% 以上，**先查 `docs/runbooks/driver-topology-cache-fix.md`** —— 这是已知的高负载触发 driver topology cache 中毒，可在节点内修复。

---

## 单工具运行（targeted 调试）

### 只跑一个 NCCL collective 在 72 rank 上

```bash
bash ~/bench-bundle/scripts/runner_cluster.sh all_reduce -- -b 8 -e 8G -f 2 -g 1
# 工具名：all_reduce | alltoall | all_gather | broadcast | reduce | reduce_scatter | sendrecv
# 参数透传给 *_perf_mpi 二进制
```

### 只在某些节点跑某个工具

```bash
bash ~/bench-bundle/scripts/run_parallel_test.sh nvbandwidth 192.168.15.137 192.168.15.138
# 工具名：bench_gemm | stream | nvbandwidth | all_reduce_perf | alltoall_perf
# 节点后可加 -- <args> 透传
```

---

## 输出 / 结果文件结构

```
~/bench-bundle/results_72gpu/<YYYY-MM-DD>/
├── per_node/<ip>/                  ← 每节点本地结果
│   ├── gemm_fp64.log, gemm_fp32.log, gemm_tf32.log, ...
│   ├── gemm_result.json            最后一个 dtype 的 JSON（每 dtype 会覆盖，所以以 .log 为准）
│   ├── stream.log + stream_result.json    （4 op 都在 JSON 里）
│   └── nvbandwidth.log + nvbandwidth_result.json   （6 test 都在 JSON 里）
├── cluster/                        ← 72-rank MPI 结果
│   ├── all_reduce.log
│   ├── alltoall.log
│   └── ...                         （7 个 collective 各一个 log）
├── aggregated.json                 ← 跨节点 stats（gemm/stream/nvbandwidth 各 dtype 的 min/mean/median/max/stddev + cluster peak/avg/wrong）
└── report.md                       ← 人类可读汇总（贴这个给 mentor）
```

---

## 常见问题快速索引

| 症状 | 文档 |
|---|---|
| NCCL busbw 突然降级 50%+；dmesg `knvlink/nvAssert` 风暴 | `docs/runbooks/driver-topology-cache-fix.md` |
| `cudaGetDeviceCount` 永久 hang；`fabric.state = In Progress` | `docs/runbooks/gb300-fabric-escalation.md` |
| `Exec format error` 跑 binary | 你拿到的不是 aarch64 包；`file bin/single-node/bench_gemm` 验证 |
| `ConnectFail` 在 `run_parallel_test.sh` 里 | 不是 SSH 连接失败，是结果 JSON 没产出；看 `docs/runbooks/gb300-known-issues.md` |
| `nvbandwidth` 报 `B300_specs.json not found` | 装饰性 warning，可忽略；harness 实际判定仍准确 |
| 18 节点 hostname 全是 `pega` | 共享镜像导致，靠 IP 区分。`docs/runbooks/gb300-known-issues.md` |
| MPI 启动 hang / UCX 走 IB 超时 | `env.sh` 已经固定 `UCX_TLS=tcp,self,sm`；若仍有问题查 `docs/runbooks/gb300-known-issues.md` |

---

## 重要提醒（操作硬约束）

NVL72 是个共享资源，错误操作会让 18 节点全断：

1. ⛔ **不要 reboot 节点**（除非有 driver state 修复的明确授权）
2. ⛔ **不要 stop fabric** (`nv set cluster state disabled`) 即使只是过夜 —— NVL72 设计 always-on，重 bringup 成本极高（详见 `docs/runbooks/gb300-known-issues.md`）
3. ⛔ **不要重启 `nvidia-imex` / `nvidia-fabricmanager` / `nvidia-persistenced`**（除非按 `docs/runbooks/driver-topology-cache-fix.md` SOP）
4. ⛔ **不要修改 `/etc/nvidia-imex/nodes_config.cfg`**（必须保持 18 节点 IP）
5. ⛔ **不要把 `127.0.0.1` 写进 hostfile 然后用 `all` 模式跑集群测试** —— runner 会走本地分支，集群跑不通
6. ⛔ **不要在跳板机上跑测试** —— 跳板机不在 fabric 里
