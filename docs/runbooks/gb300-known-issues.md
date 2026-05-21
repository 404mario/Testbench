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
