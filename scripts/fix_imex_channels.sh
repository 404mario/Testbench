#!/bin/bash
# Create /dev/nvidia-caps-imex-channels/channel0 on all nodes that need it.
# Without this, NCCL MNNVL fails with "Cuda failure 800 'operation not permitted'"
# because the IMEX data-plane device node is missing on most nodes after first boot.
#
# Why mknod and not nvidia-modprobe -f?
#   The /proc/driver/nvidia-caps-imex-channels/ path that -f expects is not always
#   created by the driver. Major 505 (= /proc/devices entry "nvidia-caps-imex-channels")
#   is registered though, so we can mknod directly.
#
# Usage: run on the launcher; needs root SSH to each host in hostfile.

set -e
HOSTFILE="${1:-$(dirname "$0")/hostfile.nvl72}"
[ -f "$HOSTFILE" ] || { echo "hostfile not found: $HOSTFILE" >&2; exit 1; }

# Extract just the IPs (one per node)
IPS=$(awk '{print $1}' "$HOSTFILE")

for ip in $IPS; do
  ssh -o BatchMode=yes -o ConnectTimeout=5 root@"$ip" '
    if [ ! -e /dev/nvidia-caps-imex-channels/channel0 ]; then
      major=$(awk "/nvidia-caps-imex-channels/ {print \$1}" /proc/devices)
      if [ -z "$major" ]; then
        echo "FAIL: no nvidia-caps-imex-channels major in /proc/devices" >&2
        exit 2
      fi
      mkdir -p /dev/nvidia-caps-imex-channels
      mknod /dev/nvidia-caps-imex-channels/channel0 c "$major" 0
      chmod 0666 /dev/nvidia-caps-imex-channels/channel0
    fi
    ls /dev/nvidia-caps-imex-channels/channel0
  ' && printf '%-15s OK\n' "$ip" || printf '%-15s FAIL\n' "$ip"
done
