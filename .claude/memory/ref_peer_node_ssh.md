---
name: ref-peer-node-ssh
description: NVL72 集群 18 compute node 之间 root SSH 互信状态 —— 2026-05-27 已打通，共享单一 ed25519 keypair。
metadata:
  node_type: memory
  type: reference
---

**状态（2026-05-27 起）：18 节点 root any-to-any 免密已通**。所有节点共享一对 ed25519（`pega-bench-20260527`），既是 `/root/.ssh/id_ed25519` 也在自己的 `authorized_keys` 里。`~/.ssh/config` 对 `192.168.15.*` 设了 `StrictHostKeyChecking=accept-new`，`known_hosts` 预填了 18 节点的 ed25519+rsa+ecdsa。

跨节点测试脚本（`run_parallel_test.sh stream node09 node10` 这类）现在可以跑了。

**信任模型 & 操作细节** → [[project-nvl72-ssh]]（包含为什么选共享 key、旁路用 sshpass 的 bootstrap 过程、加新节点的步骤、轮换 key 的步骤、备份位置）。

**节点拓扑**：
- compute IP 段：`192.168.15.137`–`192.168.15.154`（18 个节点）
- pega：`192.168.15.153`（hostname=pega，但**18 个节点 hostname 全是 pega**，靠 IP 区分；`product_serial` 也各不同）
- NVOS NMX-C switch：`192.168.15.171`（见 [[ref-nvos-switch]]）
- SSH port 22 全开（OpenSSH_9.6p1 Ubuntu）

**`authorized_keys` 历史 identity**（除 pega 自己生成的那把外）：
- `root@bu18-nv-ae-01` —— 运维 / 架构工程师 jump host
- `nv_ae@bu18-nv-ae-01` —— 同上，非 root 账号
- `customer001@bu18-xxx-jump-01` —— 客户面 jump host

这三把还在，所以 jump host 路径依旧可用。
