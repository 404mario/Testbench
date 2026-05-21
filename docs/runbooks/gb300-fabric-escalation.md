# GB300 Fabric 状态卡住 —— 升级到运维的标准流程

> 适用场景：本节点 `nvidia-smi --query-gpu=fabric.state` 持续显示 `In Progress`；CUDA 程序 `cudaGetDeviceCount` 长时间 hang 或返回 802；`CliqueId / ClusterUUID / Partition Assigned` 全 `N/A`。

## 1. 在 compute node 上先收齐证据

直接跑：
```bash
bash scripts/collect_fabric_evidence.sh
```

会在 `./diagnostics/fabric_evidence_<YYYYMMDD-HHMM>/` 生成一个完整的证据目录（全部只读命令，不动任何配置/服务）：

- `nvidia-smi.txt`、`fabric_state.csv`、`fabric_query.txt`
- `services.txt`（FM/IMEX/persistenced 状态）
- `imex.log.tail`、`imex-verbose.log.tail`
- `fabricmanager.log`（若曾启动）
- `journal.fm.txt`、`journal.imex.txt`、`journal.persistenced.txt`
- `dmesg.nvlink.txt`、`dmesg.nvswitch.txt`
- `lspci.mellanox.txt`、`nvlink_status.txt`、`topo.txt`
- `dpkg.nvidia.txt`、`uname.txt`、`SUMMARY.md`

把整个 `fabric_evidence_*/` 目录脱敏后打包发给运维。**不要**自己删任何节点上的 log。

## 2. 给运维的具体问题清单

把下面这段贴给运维：

> 在 GB300 NVL72 cluster 中，compute node `<HOST>` (`<IP>`) 的 4 个 GPU `fabric.state` 持续为 `In Progress`，CUDA `cudaGetDeviceCount` hang，CliqueId/ClusterUUID/Partition Assigned 全为 N/A。compute node 侧能做的诊断已穷尽（FM 装了精确匹配 driver 的版本，但启动报 `NV_WARN_NOTHING_TO_DO` —— compute node 本机没有 NVSwitch 设备，符合 GB300 NVL72 Kyber 架构预期）。请帮忙在 NVSwitch OS / NMX-C 侧检查：
>
> 1. **GFM 是否在运行**？查看 `/var/log/nmx/nmx-c/fabricmanager.log`；
> 2. **NVLSM 是否在运行**？查看 `/var/log/nmx/nmx-c/nvlsm.log`；
> 3. **当前 SDN partition 状态**：`nv show sdn partition` 输出；
> 4. **本节点 GPU 是否在某个 partition 中**：通过 GPU Fabric GUID（见证据包 `fabric_query.txt`）查 partition 成员；
> 5. **NVLink 链路状态**：`nv show interface link-diagnostics`、`nv show interface acp1 link counters`；
> 6. **该 chassis 上其他 17 个节点的 `fabric.state` 是否都 In Progress**？如果有节点 Completed，差异在哪？
> 7. **GB300 NVL72 部署文档对 partition 创建的要求**：是 chassis bring-up 时自动创建 default partition，还是需要手动通过 `nv action create sdn partition` 触发？
> 8. **节点 17 (`192.168.15.154`) IMEX 抖动** 是否与本卡顿有关？

## 3. 期望的运维操作（参考，**不要自己执行**）

在 NVSwitch OS / NMX-C 侧的操作示例（**chassis admin 才能跑**）：

```bash
# 查看现状
nv show sdn partition
nv show interface link-diagnostics

# 若没有 partition，运维可创建一个含全部 GPU 的 default partition
nv action create sdn partition 1 name "default_bringup" resiliency-mode <mode>

# 按 GPU UUID 把本节点 4 个 GPU 加入 partition
nv action update sdn partition 1 uuid <GPU0-UUID>
nv action update sdn partition 1 uuid <GPU1-UUID>
nv action update sdn partition 1 uuid <GPU2-UUID>
nv action update sdn partition 1 uuid <GPU3-UUID>

# 验证
nv show sdn partition 1
```

GPU UUID 在 compute node 上：`nvidia-smi -L` 输出。

## 4. 收到运维确认 partition 已建后

回到 compute node：

```bash
# 等几秒让 GPU 收到 fabric notification
sleep 10

# 检查
nvidia-smi --query-gpu=fabric.state,fabric.status,fabric.cliqueId,fabric.clusterUuid --format=csv

# 期望：State=Completed，Status=Success，CliqueId 非空，ClusterUUID 非空
```

跑一次 cuda_probe 验证（不需要等待，应该立刻返回）：

```bash
# 已有就直接跑：
timeout 10 /tmp/cuda_probe
# 或者重新编一个最小的：
cat > /tmp/cuda_probe.cu << 'EOF'
#include <cstdio>
#include <cuda_runtime.h>
int main(){
  int n=-1;
  auto e=cudaGetDeviceCount(&n);
  printf("cudaGetDeviceCount: %d (%s) n=%d\n", e, cudaGetErrorString(e), n);
  return 0;
}
EOF
nvcc -arch=sm_100 /tmp/cuda_probe.cu -o /tmp/cuda_probe
timeout 10 /tmp/cuda_probe
```

期望：`cudaGetDeviceCount: 0 (no error) n=4`。

## 5. 之后才能跑 Testbench 烟测

```bash
cd ~/bench
./run_parallel_test.sh stream 127.0.0.1
./run_parallel_test.sh bench_gemm 127.0.0.1 -- --dtype=fp16
./run_parallel_test.sh all_reduce_perf 127.0.0.1 -- -b 8M -e 1G -f 2 -g 4
```

结果在 `~/bench/result/<tool>/`。脱敏后摘要可入 `docs/runbooks/gb300-smoke-<YYYYMMDD>.md`，**完整 result JSON 不入 git**（见 `.gitignore`）。

## 6. 仍然 In Progress 的可能性

如果运维操作后 fabric.state 仍未变 Completed：
- 检查 ACP1 (NVSwitch admin/management) 链路是否健康：`nv show interface acp1 link counters`
- IB 域诊断：`nv action run ib cmd "ibdiagnet --pc --pm_pause_time 600"`
- 系统 tech-support：`nv action generate system tech-support` → 上 case 给 NVIDIA Support
- 不要在 compute node 上 reboot —— 让运维优先检查 chassis 侧
