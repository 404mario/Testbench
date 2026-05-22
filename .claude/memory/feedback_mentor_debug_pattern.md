---
name: feedback-mentor-debug-pattern
description: 用户的 mentor 推崇的硬件 bring-up debug 隔离顺序：vanilla 上游 → NGC 容器 → 升级运维。已被用户两次明确执行。
metadata:
  node_type: memory
  type: feedback
---

**Rule**：硬件 bring-up 撞 CUDA / driver / fabric 类问题时，按这个顺序做隔离实验，**不要跳级**：

1. **拉上游 vanilla 源码 build native**（不要复用项目 fork，不要复用项目脚本） → 排除"我们这边代码 / build chain 改坏了"
2. **跑 NVIDIA NGC 官方容器**（与目标硬件架构匹配的 tag，如 GB300 用 arm64 的 `nvcr.io/nvidia/pytorch:YY.MM-py3`） → 排除"宿主机用户态环境 / 系统库污染"
3. **同样错 → 上升给运维**（chassis / NVSwitch OS / 物理层）

**Why**：
- 用户 2026-05-22 明确执行了第 1 步（"试试能不能在宿主机上跑，nvbandwidth 在 github 的开源脚本跑一下看看到底行不行？这是我 mentor 给我的办法"）
- 紧接着明确执行了第 2 步（"拉 docker，拉 NV 的标准 NGC 镜像，然后在镜像里测一下开源的 nvbandwidth — 这是我 mentor 的建议"），并 override 了硬约束 6（不 sudo apt install）
- 这套流程的价值是**给运维一个无法推回的证据链**：vanilla + NGC 容器都失败 = 99.9% 不是 software 问题。NVIDIA 自己的 NGC entrypoint 报 802 等于帮我们打认证
- 我曾建议过"NGC 测试信息增益≈0，错误在 kernel driver 层容器跨不过去"——这个建议**技术上正确但流程上错了**。mentor 要的不是新信息，是**完整的证据链**给运维 / NVIDIA support。流程意义 > 单次信息增益。

**How to apply**：
- 撞 CUDA init 失败 / driver error / fabric 类问题，**不要**第一反应就说"是运维的事"。先按 1→2→3 走一遍隔离
- 第 1 步：用 git clone --depth 1 拉 NVIDIA 上游 main，**不要拉项目里现有的 submodule**（可能已 fork 改过）；放在 `/root/<tool>-upstream/` 这种 scratch 路径，不污染项目仓库
- 第 2 步：NGC tag 必须挑对架构 manifest（aarch64 节点必须 arm64 tag）；用 `docker image inspect ... --format '{{.Architecture}}/{{.Os}}'` 验
- 容器内最好 bind-mount 上游 build 进去复用（`-v /root/<tool>-upstream:/host/<tool>:ro`），避免再装一遍依赖
- 写汇报给 mentor 时用矩阵：「假设 / 测试方式 / 结果 / 是否排除」表格 + 关键 log 节选 + 唯一未排除项 → mentor 喜欢这种结构
- 不要省略第 2 步即使第 1 步已经证明结论 —— mentor 要完整证据链
