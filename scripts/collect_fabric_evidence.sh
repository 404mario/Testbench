#!/bin/bash
# 收集 fabric/IMEX/NVSwitch 相关证据到 diagnostics/fabric_evidence_<ts>/
# 全部只读命令，不动任何配置/服务。可重复跑。
# Usage: bash scripts/collect_fabric_evidence.sh

set -u

TS=$(date +%Y%m%d-%H%M)
OUT="diagnostics/fabric_evidence_$TS"
mkdir -p "$OUT"

run() { echo "+ $*" >&2; "$@" > "$OUT/$1" 2>&1 || true; }

echo "[+] 收集到 $OUT/"

# Host
{ hostname; date -Is; uname -a; cat /etc/os-release; } > "$OUT/host.txt" 2>&1
nproc > "$OUT/cores.txt" 2>&1
free -h > "$OUT/mem.txt" 2>&1

# GPU + Fabric
nvidia-smi > "$OUT/nvidia-smi.txt" 2>&1 || true
nvidia-smi --query-gpu=index,name,uuid,driver_version,pstate,persistence_mode,fabric.state,fabric.status,fabric.cliqueId,fabric.clusterUuid \
    --format=csv > "$OUT/fabric_state.csv" 2>&1 || true
nvidia-smi -L > "$OUT/gpu_uuids.txt" 2>&1 || true
nvidia-smi -q > "$OUT/fabric_query_full.txt" 2>&1 || true
nvidia-smi -i 0 -q | grep -A 20 'Fabric\|NVLink' > "$OUT/fabric_query.txt" 2>&1 || true
nvidia-smi nvlink --status > "$OUT/nvlink_status.txt" 2>&1 || true
nvidia-smi topo --matrix > "$OUT/topo.txt" 2>&1 || true

# Services
{
    echo "=== is-active / is-enabled ==="
    for s in nvidia-imex nvidia-persistenced nvidia-fabricmanager; do
        printf "%-25s active=%s enabled=%s\n" "$s" \
            "$(systemctl is-active $s 2>&1)" \
            "$(systemctl is-enabled $s 2>&1)"
    done
    echo ""
    echo "=== status (no-pager) ==="
    systemctl status nvidia-imex nvidia-persistenced nvidia-fabricmanager --no-pager -n 5 2>&1
} > "$OUT/services.txt"

# Journals
journalctl -u nvidia-fabricmanager --no-pager -n 200 > "$OUT/journal.fm.txt" 2>&1 || true
journalctl -u nvidia-imex --no-pager -n 200 > "$OUT/journal.imex.txt" 2>&1 || true
journalctl -u nvidia-persistenced --no-pager -n 100 > "$OUT/journal.persistenced.txt" 2>&1 || true

# IMEX logs (only tails; full files can be huge)
if [ -f /var/log/nvidia-imex.log ]; then tail -300 /var/log/nvidia-imex.log > "$OUT/imex.log.tail" 2>&1; fi
if [ -f /var/log/nvidia-imex-verbose.log ]; then tail -300 /var/log/nvidia-imex-verbose.log > "$OUT/imex-verbose.log.tail" 2>&1; fi
if [ -f /var/log/fabricmanager.log ]; then cp /var/log/fabricmanager.log "$OUT/fabricmanager.log" 2>/dev/null; fi
if [ -f /run/nvidia-imex/persist.dat ]; then
    { echo "=== /run/nvidia-imex/persist.dat ==="; od -c /run/nvidia-imex/persist.dat | head -5; } > "$OUT/imex_persist.txt"
fi

# Kernel
dmesg 2>&1 | grep -iE 'nvlink|nvswitch|nvidia|fabric|imex' | tail -100 > "$OUT/dmesg.nvlink_nvswitch.txt"

# Mellanox / IB
{
    echo "=== /sys/class/infiniband ==="
    ls /sys/class/infiniband/ 2>&1
    echo ""
    echo "=== ibstat ==="
    ibstat 2>&1 | head -80
} > "$OUT/ib.txt"
lspci -D 2>/dev/null | grep -i mellanox > "$OUT/lspci.mellanox.txt" 2>&1 || true

# Packages
dpkg -l 2>/dev/null | grep -iE 'nvidia|cuda' | awk '{print $1, $2, $3}' > "$OUT/dpkg.nvidia.txt"

# IMEX config (do NOT modify these)
if [ -f /etc/nvidia-imex/config.cfg ]; then cp /etc/nvidia-imex/config.cfg "$OUT/imex.config.cfg"; fi
if [ -f /etc/nvidia-imex/nodes_config.cfg ]; then cp /etc/nvidia-imex/nodes_config.cfg "$OUT/imex.nodes_config.cfg"; fi

# FM config (if installed)
if [ -f /usr/share/nvidia/nvswitch/fabricmanager.cfg ]; then
    cp /usr/share/nvidia/nvswitch/fabricmanager.cfg "$OUT/fm.cfg.shipped"
fi

# Summary
cat > "$OUT/SUMMARY.md" << EOF
# Fabric Evidence Collection

- **When**: $(date -Is)
- **Host**: $(hostname) ($(hostname -I | awk '{print $1}'))
- **Driver**: $(modinfo nvidia 2>/dev/null | awk '/^version:/ {print $2}')
- **fabric.state**: $(nvidia-smi --query-gpu=fabric.state --format=csv,noheader 2>/dev/null | head -1 | xargs)
- **CliqueId**: $(nvidia-smi -i 0 -q 2>/dev/null | awk '/CliqueId/ {print $3; exit}')
- **ClusterUUID**: $(nvidia-smi -i 0 -q 2>/dev/null | awk '/ClusterUUID/ {print $3; exit}')

## Key questions for cluster ops (NVSwitch OS / NMX-C side)

1. \`nv show sdn partition\` —— current partition state?
2. Are this node's 4 GPUs (see gpu_uuids.txt) members of any partition?
3. \`/var/log/nmx/nmx-c/fabricmanager.log\` —— any errors during chassis bring-up?
4. \`/var/log/nmx/nmx-c/nvlsm.log\` —— NVLSM healthy?
5. \`nv show interface link-diagnostics\` —— NVLink trunk health?
6. Are other 17 compute nodes (192.168.15.137..152, 154) in same In Progress state?

## What was already verified on this compute node

- FM package installed (exact-match driver version), service disabled
- FM attempted to start, exited with NV_WARN_NOTHING_TO_DO (no local NVSwitch hw — expected for Kyber)
- IMEX has gRPC connections to all 17 peers
- All 18 NVLink lanes up at 53.125 GB/s
- nodes_config.cfg unmodified (18-node)
- No reboot, no service restart, no /etc edits performed
EOF

# Final report
echo ""
echo "[+] Done. 证据目录:"
echo "    $OUT"
echo ""
echo "    脱敏后打包发给运维（避免泄露 IP / MAC / 内部 hostname 等）："
echo "    tar -czf $OUT.tgz $OUT"
echo ""
echo "    关键 fabric.state:"
nvidia-smi --query-gpu=fabric.state --format=csv,noheader 2>/dev/null | sed 's/^/      /'
