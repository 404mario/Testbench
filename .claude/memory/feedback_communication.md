---
name: feedback-communication
description: 用户对沟通节奏、草稿审批、命令呈现方式的偏好。
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

**Rule**: 改动前先给方案 + 分批 review + 等用户拍板。

**Why**：
- 用户明确说过"请准备但不要立即写入以下文件的内容，先展示 diff/草稿让我确认"
- 用户在选择"分三批，每批等你 OK 再下一批"时，明确选了"推荐"那项
- 大段一次性输出（16 个文件草稿一口气贴）会让用户难以聚焦反馈

**How to apply**：
- 多文件改动：默认分批（基础文件 / 脚本 / skill / 文档），等批次 OK 再下一批
- 单个修改性命令：先方案 + 风险评估 + 回滚方案，再问 Y/N
- 用 AskUserQuestion 给 2-4 个明确选项（含 "Other" 由系统自动加）而非开放问题
- 命令清单用 ```bash 块 + 注释 "我不会自动执行"，让用户可以直接复制
- 表格优于段落；中文 + 简短 emoji（✅ ❌ ⚠ 🟡）
- 用户用 `!cmd` 前缀让命令在他终端跑——**注意 `!` 是半角不是全角 `！`**，且 `!` 不分配 TTY（ssh 密码 prompt 失败）
- 不喜欢冗余收尾总结；end-of-turn 只一两句话点睛
