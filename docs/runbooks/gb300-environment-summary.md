# GB300 / NVL72 环境快照

> 实测于 hostname `pega` (`192.168.15.153`)，2026-05-21。
> 任何与当前实际状态不一致的部分以 `nvidia-smi` / `systemctl status` 实测为准。

## 物理拓扑

- NVL72 机柜：18× compute node × 4 GPU = 72 GPU
- chassis：Kyber 托盘 + 外置 NVSwitch；NVSwitch OS（NMX-C）独立管理
- 当前本地工作节点：1 个 compute node（不做整柜测试，先做单节点 bring-up）

## 单节点配置

| 项 | 值 |
|----|----|
| Hostname | `pega` |
| IP | `192.168.15.153` |
| OS | Ubuntu 24.04.3 LTS, kernel 6.17.0-1014-nvidia-64k |
| Arch | `aarch64` (NVIDIA Grace) |
| Cores | 144 |
| RAM | 2.0 TiB |
| GPU | 4× NVIDIA GB300 (Blackwell Ultra, sm_100, 288 GiB HBM3e per GPU) |
| TDP | 1400W per GPU |
| Driver | `nvidia-dkms-open 595.58.03-1ubuntu1`（**open** kernel module flavor） |
| FabricManager | 包已装 `595.58.03`，service 已 disable（**不应**在 compute node 跑，详见 fabric-bringup-blocker） |

## 关键路径

| 项 | 路径 |
|----|------|
| CUDA toolkit | `/usr/local/cuda-13`（`/usr/local/cuda` → symlink） |
| nvcc | `/usr/local/cuda-13/bin/nvcc` (v13.2.78) |
| cuBLAS (aarch64) | `/usr/local/cuda/targets/sbsa-linux/lib/libcublas*.so.13.4.0.1` |
| NCCL (aarch64) | `/lib/aarch64-linux-gnu/libnccl.so.2.29.7` |
| IMEX 配置 | `/etc/nvidia-imex/{config.cfg,nodes_config.cfg}` |
| IMEX channel | `/dev/nvidia-caps-imex-channels/channel0` |
| IMEX 持久化 | `/run/nvidia-imex/persist.dat`（**不要删/不要重启 IMEX**） |
| IMEX log | `/var/log/nvidia-imex.log`、`nvidia-imex-verbose.log`、`nvidia-imex-stats.log` |
| FM 配置（默认） | `/usr/share/nvidia/nvswitch/fabricmanager.cfg` |
| FM 拓扑库 | `/usr/share/nvidia/nvswitch/gb300_nvl72r1_c2g4*_topology` |
| FM log（如启动） | `/var/log/fabricmanager.log` |
| 部署/运行工作区 | `~/bench/` (二进制 + `run_parallel_test.sh` + `spec/` + `result/`) |
| 仓库 | `/root/Testbench` |

## chassis 侧 / NVSwitch OS / NMX-C（非 compute node）

下列路径与命令**不在 compute node 上**，在 NVSwitch tray / NMX-C 管理面：

| 项 | 路径 / 命令 |
|----|-------------|
| NVLSM (Subnet Manager) log | `/var/log/nmx/nmx-c/nvlsm.log` |
| GFM (Global Fabric Manager) log | `/var/log/nmx/nmx-c/fabricmanager.log` |
| 查看 SDN partition | `nv show sdn partition` |
| 创建 partition | `nv action create sdn partition <id> name "<name>" resiliency-mode <mode>` |
| 按 location 加 GPU | `nv action update sdn partition <id> location <loc>` |
| 按 UUID 加 GPU | `nv action update sdn partition <id> uuid <uuid>` |
| NVLink 链路状态 | `nv show interface link-diagnostics` |
| NVLink 域诊断 | `nv action run ib cmd "ibdiagnet --pc --pm_pause_time 600"` |
| 系统 tech-support 包 | `nv action generate system tech-support` |

## Fabric / IMEX 状态（巡查时）

| 服务 | 状态 |
|------|------|
| `nvidia-fabricmanager` | 包已装 `595.58.03`，service `disabled`（**不应**在 compute node 上跑） |
| `nvidia-imex` | `active`（已与 17 个对端建 gRPC；不要重启） |
| `nvidia-persistenced` | `active`（4 GPU 已注册，persistence mode 开） |

`fabric.state` 当时为 `In Progress`，`CliqueId / ClusterUUID / Partition Assigned` 全 `N/A` —— **chassis 侧 partition 未下发**。

`/etc/nvidia-imex/nodes_config.cfg` 包含 18 节点（`192.168.15.137`–`192.168.15.154`）。**这份配置必须 18 节点全集群一致**，本地烟测不要改成单节点。

## 工具链

| 工具 | 版本 |
|------|------|
| gcc/g++ | 13.3.0 |
| make | 系统自带 |
| cmake | 3.28.3 |
| nvcc | 13.2.78 |
| python3 | 系统自带（脚本用） |
| ibstat | `/usr/sbin/ibstat`（FM 启动脚本会用到） |

## spec 契约 vs 元数据

- `spec/GB300_specs.json` —— **运行时契约**。4 个二进制（`bench_gemm` / `stream` / `nvbandwidth` / nccl `*_perf`）通过 `gpu_name → <model>_specs.json` 在 cwd 中加载，按扁平 schema 读 `gemm.<dtype>` / `stream.<test>` / `nccl.<test>` / `nvbandwidth.<test>` 计算 pass/fail 阈值。**字段名/层级不可改**。
- `spec/GB300_specs.full.json` —— **权威元数据**。dense/sparse 区分、TDP、PCIe/NVLink 速率、`test_policy` 等，不被二进制读取，仅供人/未来工具参考。

部署：`cp spec/*.json ~/bench/spec/` 后才会被 `run_parallel_test.sh` cp/scp 到 `/tmp/gpu_test_workspace/`。
