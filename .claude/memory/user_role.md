---
name: user-role
description: 用户在 404mario/Testbench 项目里的角色、协作偏好、技术语境。
metadata: 
  node_type: memory
  type: user
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

用户是在 GB300 NVL72 compute node 上做 Testbench bring-up 的工程师。项目创始人是李铁铮（用户提到的第三方），用户自己是当下做实际操作的人。

**技术语境**：
- 熟悉 GPU 集群环境（NVL72 / IMEX / NVSwitch / fabricmanager 概念都懂）
- 中文沟通
- 知道项目历史（OSS 包打包流程、x86 二进制传统）
- 对自己机器有 root（也对所有"测试节点"——指 18 个 compute node——有 root），但**没有 NVOS 凭据**
- 不是"上来就让 Claude 全自动跑"那种用户——更倾向 review + 拍板

**协作偏好**：
- "改动前先给方案"——任何修改性命令都要先列出来等点头
- 中文清单 + 表格化呈现易接受
- 不喜欢冗余总结；技术细节愿意看
- 接受"我先验证再做"的节奏（不催）
- 允许 Claude 主动诊断 + 提建议执行命令（不是纯只读）

**项目硬约束**（用户明确给的）：
- 不要 reboot / 重启 nvidia-imex / nvidia-fabricmanager / sshd / nvidia-persistenced
- 不要修改 /etc/nvidia-imex/ /etc/ssh/ /etc/modprobe.d/nvidia.conf
- 不要在跳板机配免密
- 不要 commit 大产物 / 密码 / 私钥 / token
- 不要把 127.0.0.1 写进 node 文件后用 all 模式
- 用 `git add -p` 不用 `git add -A`
