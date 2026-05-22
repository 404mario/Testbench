---
name: ref-nvos-switch
description: NVL72 chassis 的 NVSwitch OS / NMX-C 控制器位置；GB300 compute node fabric.state 唯一可解锁入口。
metadata: 
  node_type: memory
  type: reference
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

**`192.168.15.171` = NVOS switch (NVIDIA Networking OS, NMX-C 控制器)**。

确认证据：SSH banner 返回 `NVOS switch`，OpenSSH 9.2p1 Debian。0.12ms ping 延迟（同机柜邻居）。

**作用**：NVL72 chassis 的 SDN partition 管理 + GFM + NVLSM 入口。这是把 fabric.state 从 `In Progress` 变 `Completed` 的**唯一**正路——compute node 本机什么都做不了（见 [[project-gb300-bringup]]）。

**关键命令**（NVOS CLI，不是 bash）：
```
nv show sdn partition                          # 看当前 partition
nv show interface link-diagnostics             # NVLink 链路健康
nv show file /var/log/nmx/nmx-c/fabricmanager.log lines 50
nv show file /var/log/nmx/nmx-c/nvlsm.log lines 50
nv action create sdn partition <id> name "<n>" resiliency-mode <mode>
nv action update sdn partition <id> uuid <GPU-UUID>
nv action delete sdn partition <id>
```

**当前我们没有 admin 凭据**（pubkey + password 都拒）。可能持有凭据的位置：
- `bu18-nv-ae-01` jump host（其 root key 在 pega 的 authorized_keys 里——见 [[ref-peer-node-ssh]]）
- `bu18-xxx-jump-01` jump host
- 公司 wiki / Ansible role / 部署文档
- 运维 / mentor

**SSH 注意**：必须在 Claude Code 之外的真终端做（`!` 前缀不分配 TTY）。
