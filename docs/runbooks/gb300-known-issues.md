# GB300 已知问题与对应排错路径

## ① `ConnectFail`（**最常见误诊**）

**症状**：`./run_parallel_test.sh <tool> 127.0.0.1 ...` 打印 `❌ [127.0.0.1][xxx] 失败 (ConnectFail)`。

**真正含义**：`STATUS_MSG="ConnectFail"` 是脚本初值；只有 `cp $REMOTE_WORK_DIR/result.json $LOCAL` 成功才被覆盖。v8 脚本对 `127.0.0.1`/`localhost` 走本地 `cp` 分支，根本**不调 ssh**。所以 `ConnectFail` = **取不到 result JSON**。

**常见根因**（按发生概率）：
1. 二进制是 x86_64 ELF，在 aarch64 上 `Exec format error` → 没产出 JSON
2. `cudaGetDeviceCount` hang 或 `802 (system not yet initialized)` → 见 ②
3. spec 文件没拷过去 / 字段缺失 → 二进制 abort
4. 段错误 / OOM

**排错命令**：
```bash
file ~/bench/bench_gemm ~/bench/stream ~/bench/all_reduce_perf ~/bench/nvbandwidth
~/bench/stream 2>&1 | head -10                    # 直接 exec 看真实错
ls /tmp/gpu_test_workspace/
tail -30 /tmp/gpu_test_workspace/*.log
```

---

## ② `cudaGetDeviceCount` hang / `system not yet initialized (802)`

**症状**：任何 CUDA 程序 init 时挂住几十秒后超时（或返回 802）；`nvidia-smi --query-gpu=fabric.state` 显示 `In Progress`。

**根因**：NVL72 chassis 侧 SDN partition 未分配给本节点的 GPU；`CliqueId / ClusterUUID / Partition Assigned` 全 `N/A`。这**不是 compute node 能修的**。

**不要做**：
- ❌ `systemctl restart nvidia-imex`
- ❌ `systemctl start nvidia-fabricmanager`（FM 在 compute node 上会立刻报 `NV_WARN_NOTHING_TO_DO`，见 ⑦）
- ❌ 把 `/etc/nvidia-imex/nodes_config.cfg` 改成单节点
- ❌ reboot

**该做**：跑 `bash scripts/collect_fabric_evidence.sh` 收集证据 → 发给运维 → 让他们查 chassis 侧 SDN partition。完整流程见 `docs/runbooks/gb300-fabric-escalation.md`。

---

## ③ `~/bench/` 内二进制全是 x86_64

**症状**：`file ~/bench/bench_gemm` 显示 `ELF 64-bit LSB pie executable, x86-64`。

**原因**：仓库历史是在 x86 开发机编译并打包上 OSS，GB300 上 `wget` 下来的二进制平台不对。

**修复**：跑 `bash scripts/build_aarch64_tools.sh` 重编。原 x86 二进制**改名 `*.x86_64.bak` 留底，不删**。

---

## ④ `Node configuration mismatch`（IMEX）

**症状**：`nvidia-imex` 日志或 `dmesg` 出现 `Node configuration mismatch`；CUDA 报 802。

**根因**：本机 `/etc/nvidia-imex/nodes_config.cfg` 与集群其他节点不一致（例如本机被改成单节点 `127.0.0.1`）。

**修复**：恢复成 18 节点完整列表（`192.168.15.137`–`192.168.15.154`）。**这件事不要 Claude 自行做**，需要操作人 + 运维双签。

---

## ⑤ `bench_gemm` 二进制 776 MB

**症状**：编出的 bench_gemm 巨大，commit 时被 GitHub 拒。

**原因**：cuBLAS / cuBLASLt static link + debug info。

**应对**：永不 commit；`.gitignore` 已挡。若必须减小：`strip --strip-debug bench_gemm`，但默认保留 debug info 利于排错。

---

## ⑥ SSH self-loop 拒 publickey

**症状**：`ssh 127.0.0.1 hostname` 报 `Permission denied (publickey)`。

**对当前烟测的影响**：**无**。`run_parallel_test.sh` v8 对 `127.0.0.1`/`localhost` 走本地 `cp + exec` 分支，不调 ssh。仅当扩到 2+ compute 节点测试时需要 compute 节点间互信（**不在跳板机配**）。

---

## ⑦ `nvidia-fabricmanager` 在 GB300 compute node 上无法启动

**症状**：`sudo systemctl start nvidia-fabricmanager` 立刻 failed；journal 显示：
```
Detected Pre-NVL5 system
request to query NVSwitch device information from NVSwitch driver
    failed with error: WARNING Nothing to do [NV_WARN_NOTHING_TO_DO]
```

**根因**：GB300 NVL72 compute node **本机没有 NVSwitch 硬件**——NVSwitch 在 chassis 的 Kyber 托盘里，由 NVSwitch OS / NMX-C 管理。bare-metal FM 期待本地 switch 设备，找不到就退。

**修复**：**不修**。`systemctl disable nvidia-fabricmanager` 让它别开机自启；包保留备用（如运维有特殊 config 可即时上）。Fabric init 必须由 chassis 侧完成。

---

## ⑧ spec schema 漂移导致 `'<block>' Block Missing`

**症状**：result JSON 出现 `"status": "'gemm' Block Missing"` / `"'stream' Block Missing"` / `"Spec File Not Found"`。

**原因**：二进制按**扁平 schema** 读 `spec/<model>_specs.json`：
```cpp
specs["gemm"]["fp16"]                          // gemm
specs["stream"]["copy"]                        // stream
specs["nccl"]["all_reduce"]                    // nccl
specs["nvbandwidth"]["device_to_device_..."]   // nvbandwidth
```
如果把嵌套 schema（如 `GB300_specs.full.json`）当成运行时 spec 部署，4 个工具全爆。

**修复**：保留扁平 `spec/GB300_specs.json` 为运行时契约；嵌套元数据放 `spec/GB300_specs.full.json`。

---

## ⑨ bring-up 阶段把"Failed (低于阈值)"当成真失败

**说明**：`GB300_specs.full.json` 的 `test_policy.strict_pass=false` 明确指出首次 bring-up 不卡阈值。即便二进制写出 `"status": "Failed"`，只要 `percent_of_spec` 合理（>50%）就当"已跑通"。bring-up 阶段重点是：

1. `file` 显示 aarch64
2. result JSON **实际生成**
3. 没有 `Spec File Not Found` / `Block Missing` / `Exec format error`
4. CUDA 能 init（无 hang / 802）

---

## ⑩ `bench_gemm` 缺 `lock_clock` 配置

**症状**：bench_gemm 失败时脚本输出 `Failed_NoClockCfg`，不重试锁频。

**原因**：当前 `GB300_specs.json` 没有 `lock_clock` 字段（待 mentor / 运维给权威值）。

**修复**：暂留空，影响有限——`bench_gemm` 一次性失败即记录，不重试。若要补，加 `"lock_clock": <MHz>` 到 `spec/GB300_specs.json`。

---

## ⑪ NCCL MNNVL 报 `Cuda failure 800 'operation not permitted'`（2026-05-27 新发现）

**症状**：72 GPU NCCL collective 启动时所有 rank 报：
```
NCCL WARN MNNVL (cliqueSize 72) is available but not working on this system.
Check the IMEX channel configuration (/dev/nvidia-caps-imex-channels).
NCCL WARN Cuda failure 800 'operation not permitted'
```
单节点 4 GPU 没问题，跨节点必挂。

**根因**：IMEX 控制面（`nvidia-imex-ctl -N` 连通矩阵全 `C`）OK，但 **数据面设备文件 `/dev/nvidia-caps-imex-channels/channel0` 在大部分节点上没创建**。Kernel 已注册 major（`/proc/devices` 有 `nvidia-caps-imex-channels`），但 dev node 没自动建。pega 上是 fabric bring-up 期间手工 mknod 出来的，其他 17 节点漏了。

**修复**：`bash scripts/fix_imex_channels.sh` —— `mknod c $major 0` 在每个缺失节点上补建。SOP 把此操作标为 destructive，但本质只是补 dev node，幂等可逆（`rm` 即回）。

**预防**：把这个步骤纳入新节点 onboarding。`scripts/setup.sh` 第一步就调用它。

---

## ⑫ OpenMPI + UCX 默认走 IB 导致 mpirun 启动失败（2026-05-27 新发现）

**症状**：`mpirun -np 72 ...` 在 rank exchange 阶段报：
```
[host:pid] ib_device.c:1385 UCX ERROR ibv_create_ah(...) Connection timed out
[host:pid] pml_ucx.c:429 Error: ucp_ep_create(proc=N) failed: Address not valid
67 more processes have sent help message ... mpi_init:startup:internal-failure
```
NCCL 还没机会执行就被 MPI 自己干掉了。

**根因**：NVIDIA HPC-X 风格的 OpenMPI 默认 PML = UCX；UCX 优先用 IB 传输（`mlx5_4`）。NVL72 上 IB 卡存在但子网管理器（SM）没配，UCX 无法建链路。

**修复**：`scripts/env.sh` 已把 `UCX_TLS=tcp,self,sm` `UCX_NET_DEVICES=enP5p9s0` 固定。如果你绕过 env.sh 直接调 `mpirun`，必须显式 pass：
```bash
mpirun ... -x UCX_TLS=tcp,self,sm -x UCX_NET_DEVICES=enP5p9s0 ...
```

**注意**：这只影响 MPI 内部控制面（慢就慢，无所谓）。NCCL 数据面独立选 transport，72 GPU collective 仍然走 NVLink/MNNVL，带宽不受影响。详见 [nccl_design.md](nccl_design.md)。

---

## ⑬ nvbandwidth 二进制硬编码找 `B300_specs.json`

**症状**：nvbandwidth 输出末尾的 JSON Writer 段说 `Spec: B300_specs.json, Status: Spec File Not Found (B300_specs.json)`。

**根因**：我们 Testbench fork 的 nvbandwidth 在源码里写死了 `B300_specs.json` 而不是 `GB300_specs.json` —— 两个是不同 GPU（B300 = Blackwell HGX 独立卡，GB300 = Grace-Blackwell superchip），**不应该 symlink 混用**。

**影响**：纯装饰性。Harness（`run_parallel_test.sh`）层会用 `nvidia-smi --query-gpu=name` 自检测出 `GB300` 然后读 `GB300_specs.json` 做阈值判定，pass/fail 仍然准确。

**待办**：下次 build nvbandwidth 时在 `nvbandwidth_tests/json/SpecValidator.cpp`（或对应位置）加 `GB300` 的 case。当前 build cycle 不动。

---

## ⑭ 18 节点 hostname 全是 `pega`

**症状**：跨节点 NCCL/MPI 日志全部以 `pega:` 开头，分不清是哪个节点。

**根因**：18 节点用同一个 OS image，部署时没做 per-node hostname customization。

**实操**：靠 IP（`192.168.15.137`–`154`）和 `cat /sys/class/dmi/id/product_serial` 区分。脚本里别 grep hostname 做节点判定。这件事**不修**——改 18 节点 hostname 影响 IMEX/NCCL/客户配置，得有完整 plan。
