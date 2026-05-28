---
name: feedback-driver-state-repair
description: 用户授权下做 driver reload + 单 GPU FLR 修复 NVLink topology cache 中毒的操作模式：升档要逐档停下报告，FLR 比 driver reload 更轻，永远不直接跳 reboot
metadata:
  node_type: memory
  type: feedback
---

**规则**：当 NCCL busbw 因 driver 内 NVLink topology cache 中毒严重降级（dmesg `knvlinkUpdatePostRxDetectLinkMask` 风暴 + `Recovery Action: Reset`），按 **A (单 GPU FLR) → D (driver reload) → E (reboot)** 升档，每档结果都先停下报告再决定是否升档。

**Why**: 2026-05-28 实战验证了这个升档表能 14× 恢复 NCCL busbw (48→687 GB/s)，未 reboot 未动 chassis。用户当时把"驱动 reload + 服务重启"的权限明确授权给我（覆盖了 CLAUDE.md 的"不要重启 imex / persistenced"约束），但要求"随时可中断"。如果不是逐档停下报告，可能会过度操作（直接跳 reboot 信息增益最低，反而失去定位价值）。FLR 是最轻的（只影响 1 个 GPU 几秒钟），driver reload 中等（影响 1 个节点几十秒），reboot 最重。

**How to apply**:
1. 用户授权打破硬约束（reboot / 重启 imex 等）后，仍按风险从轻到重逐档执行，每档结果先停下报告再请用户拍下一步
2. 修复前先建 backup：`cp /run/nvidia-imex/persist.dat /root/persist.dat.bak.$(date +%Y%m%d-%H%M%S)`
3. 修复后必跑 NCCL 4-GPU smoke test 验证 busbw 恢复（`./all_reduce_perf -b 1G -e 8G -f 2 -g 4`，看 peak busbw 是否 600+ GB/s）
4. 修复后让 user 看 dmesg 5 分钟新增 assert 计数 → 0 表示 driver state 稳定；偶发 `knvlinkSendInbandData_IMPL` 是 IMEX 跨节点同步偶发失败，不是同一类问题
5. 完整 SOP 在 `docs/runbooks/driver-topology-cache-fix.md`，**不要从头复述，直接引用**

**相关**：[[feedback-operational-boundaries]] 的硬约束在用户明确授权下可以暂时打破，但必须明确说明范围（"今天授权 driver reload+FLR" ≠ "永久允许 reboot"），下次相同场景再次确认。
