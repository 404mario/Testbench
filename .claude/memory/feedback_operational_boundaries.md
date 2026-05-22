---
name: feedback-operational-boundaries
description: "用户对 GB300 测试节点上\"什么不能动\"的硬性约束清单。"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

**Rule**: 在 GB300 测试节点上**严禁**下列动作，除非用户明确二次确认：

- `reboot` / 任何让系统重启的动作
- `systemctl restart` / `systemctl stop` 任何 `nvidia-*` 服务（特别是 `nvidia-imex`、`nvidia-persistenced` —— `/run/nvidia-imex/persist.dat` 是集群协商状态，重启会让 IMEX 重新协商）
- 修改 `/etc/nvidia-imex/`（特别是 `nodes_config.cfg` 必须保持 18 节点列表 `192.168.15.137`–`192.168.15.154`）
- 修改 `/etc/ssh/` 或 `~/.ssh/authorized_keys`
- 修改 `/etc/modprobe.d/nvidia.conf`（影响驱动加载参数，需要模块 reload 或 reboot 才生效）
- 在跳板机上配免密 / 加 key
- `git add -A` 或 `git add .`（必须用 `git add -p` 或 `git add <文件名>` 显式）
- commit 大体积编译产物、result 目录、token、BMC 密码、公司密钥、私钥
- `sudo apt install/purge` 任何包（即便方便也要先问）
- 把 `127.0.0.1` / `localhost` 写进 `node` 文件然后用 `all` 模式跑跨节点测试

**Why**：
- 测试节点是 18 个 compute node 的成员，状态影响集群协调
- 用户之前实操踩过坑（比如把 `nodes_config.cfg` 改成单节点触发 `Node configuration mismatch`）
- 仓库公开，敏感物入 git 是不可逆事故
- `set -u + ZSH_VERSION snapshot` 冲突这种"工具自身的脆弱"会让自动化"看似成功"实则失败（部署 x86→aarch64 时备份逻辑被静默跳过，原 x86 被覆盖；2026-05-21 实例）

**How to apply**：
- 凡涉及上述任何一项的命令，都先打印计划等用户 OK 再执行
- 即便用户授权"主动诊断"，修改性命令仍需逐条确认
- 写 bash 脚本时 `set -u` 要小心 shell snapshot 注入；多变量条件判断要 default-empty 保护
- 用 systemctl status / journalctl / log tail 这类只读方式优先
