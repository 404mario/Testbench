---
name: ref-peer-node-ssh
description: NVL72 集群 18 compute node 之间的 SSH 互信状态、authorized_keys 来源；做跨节点测试前必须先解决的依赖。
metadata: 
  node_type: memory
  type: reference
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

**18 个 compute node 之间没有 root ssh 互信**。从 pega (192.168.15.153) 到 192.168.15.137 / 140 / 154 全部返回 `Permission denied (publickey,password)`。

`run_parallel_test.sh` 跨节点测试模式（如 `./run_parallel_test.sh stream node09 node10`）依赖 scp/ssh，所以**当前无法做跨节点测试**。本地 `127.0.0.1` 模式不依赖 ssh，但被 fabric 问题阻塞（见 [[ref-nvos-switch]]）。

**`~/.ssh/authorized_keys` 持有 3 把 key**（来源观察）：
- `root@bu18-nv-ae-01` —— 运维 / 架构工程师 jump host
- `nv_ae@bu18-nv-ae-01` —— 同上，非 root 账号
- `customer001@bu18-xxx-jump-01` —— 客户面 jump host

含义：**`bu18-*` jump host 们能 ssh 进 pega 当 root**。它们极可能也能进其他 17 个 compute node + NVOS。要做跨节点测试或拿 NVOS 凭据，**问运维或经 jump host** 是最快的路径。

**peer node 22 端口都是开的**（SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.16），所以是认证问题不是网络问题。

**Test node IP 段**：`192.168.15.137`–`192.168.15.154` (18 个节点；NVOS = `.171`)。
