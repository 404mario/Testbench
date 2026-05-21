#!/bin/bash
# GB300 只读环境诊断。不修改任何配置，不重启服务，不 reboot。
# Usage: bash scripts/diagnose_gb300_env.sh
# 输出：屏幕摘要 + 退出码（0 = 所有关键项 OK；1 = 有警告；2 = 严重缺失）

set -u
WARN=0
ERR=0

hdr() { printf "\n\033[1;36m==[ %s ]==\033[0m\n" "$*"; }
ok()  { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn(){ printf "  \033[33m⚠\033[0m %s\n" "$*"; WARN=$((WARN+1)); }
err() { printf "  \033[31m✗\033[0m %s\n" "$*"; ERR=$((ERR+1)); }

hdr "Host"
echo "  $(hostname) | $(date -Is) | $(uname -m) | $(. /etc/os-release; echo $PRETTY_NAME)"
echo "  cores: $(nproc) | mem: $(free -h | awk '/Mem:/ {print $2}')"

hdr "CUDA / nvcc"
if command -v nvcc >/dev/null; then
    ok "nvcc: $(nvcc --version | awk '/release/ {print $0}' | xargs)"
else
    err "nvcc not found in PATH"
fi
ls -d /usr/local/cuda-* 2>/dev/null | sed 's/^/  /'

hdr "GPU / Driver"
if ! command -v nvidia-smi >/dev/null; then
    err "nvidia-smi not found"
else
    nvidia-smi --query-gpu=index,name,driver_version,pstate,persistence_mode,fabric.state,fabric.status \
        --format=csv 2>&1 | sed 's/^/  /'
fi

hdr "Fabric / NVLink / NVSwitch"
FAB_STATE=$(nvidia-smi --query-gpu=fabric.state --format=csv,noheader 2>/dev/null | head -1 | xargs)
case "$FAB_STATE" in
    Completed) ok "fabric.state = Completed (CUDA should init)" ;;
    "In Progress") err "fabric.state = In Progress (CUDA will hang). See docs/runbooks/gb300-fabric-escalation.md" ;;
    *) warn "fabric.state = '$FAB_STATE' (unexpected)" ;;
esac
nvidia-smi -i 0 -q 2>/dev/null | grep -A 6 'Fabric' | head -10 | sed 's/^/  /' || true

hdr "Services"
for svc in nvidia-imex nvidia-persistenced nvidia-fabricmanager; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        STATE=$(systemctl is-active "$svc" 2>&1)
        ENAB=$(systemctl is-enabled "$svc" 2>&1)
        case "$svc:$STATE" in
            nvidia-imex:active|nvidia-persistenced:active) ok "$svc: $STATE / $ENAB" ;;
            nvidia-fabricmanager:active) warn "$svc: $STATE / $ENAB (FM 不该在 GB300 compute node 上跑)" ;;
            nvidia-fabricmanager:*) ok "$svc: $STATE / $ENAB (符合预期：FM 不应在 compute node 跑)" ;;
            *) warn "$svc: $STATE / $ENAB" ;;
        esac
    else
        case "$svc" in
            nvidia-fabricmanager) ok "$svc: 未装 (符合 GB300 compute node 预期)" ;;
            *) err "$svc: 未装 (异常)" ;;
        esac
    fi
done

hdr "IMEX channel / nodes_config"
[ -e /dev/nvidia-caps-imex-channels/channel0 ] && ok "/dev/nvidia-caps-imex-channels/channel0 OK" || err "channel0 missing"
if [ -f /etc/nvidia-imex/nodes_config.cfg ]; then
    NC=$(grep -cE '^[0-9]+\s+[0-9.]+' /etc/nvidia-imex/nodes_config.cfg 2>/dev/null)
    if [ "${NC:-0}" -ge 2 ]; then ok "nodes_config.cfg: $NC 条节点"
    else warn "nodes_config.cfg 只有 $NC 条 (NVL72 应该是 18 条)"; fi
else
    err "/etc/nvidia-imex/nodes_config.cfg 不存在"
fi

hdr "NCCL / cuBLAS (aarch64)"
ls /lib/aarch64-linux-gnu/libnccl.so.* 2>/dev/null | sed 's/^/  /' || warn "libnccl not found"
ls /usr/local/cuda/targets/sbsa-linux/lib/libcublas.so.* 2>/dev/null | head -3 | sed 's/^/  /' || warn "libcublas not found"

hdr "工具链"
for t in gcc g++ make cmake ibstat; do
    if command -v "$t" >/dev/null; then ok "$t: $($t --version 2>&1 | head -1)"; else warn "$t 缺失"; fi
done

hdr "~/bench 二进制架构"
for bin in bench_gemm stream all_reduce_perf alltoall_perf nvbandwidth; do
    p="$HOME/bench/$bin"
    if [ -x "$p" ]; then
        ARCH=$(file -b "$p" | grep -oE 'aarch64|x86-64|x86_64' | head -1)
        case "$ARCH" in
            aarch64) ok "$bin: aarch64 ✓" ;;
            x86*) err "$bin: $ARCH (在 GB300 上不能跑！scripts/build_aarch64_tools.sh)" ;;
            *) warn "$bin: 未知架构 '$ARCH'" ;;
        esac
    else
        warn "$bin: 不存在于 ~/bench/"
    fi
done

hdr "结论"
echo "  WARN=$WARN  ERR=$ERR"
if [ "$ERR" -gt 0 ]; then
    echo "  → 有严重缺失，先看上面 ✗ 行"
    exit 2
elif [ "$WARN" -gt 0 ]; then
    echo "  → 有警告，可能不阻塞 bring-up；查 ⚠ 行决定"
    exit 1
else
    echo "  → 基础环境 OK"
    exit 0
fi
