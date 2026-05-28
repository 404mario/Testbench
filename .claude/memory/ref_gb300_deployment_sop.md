---
name: ref-gb300-deployment-sop
description: "GB200/GB300 deployment SOP cheatsheet (from Feishu 1_gb200-poc-readme) — destructive vs read-only commands, plus the read-only diagnostic command set used when fabric is stuck."
metadata: 
  node_type: memory
  type: reference
  originSessionId: 744398e3-0804-4112-909d-65474272ec90
---

Source: user-provided extract of Feishu doc `1_gb200-poc-readme (1).md`. Covers compute tray bring-up, IMEX setup, DOCA/OFED, NVSwitch/NVOS, NMX-C config, validation, and testing.

**Hard rule (per [[feedback-operational-boundaries]]):** never execute the destructive sections without explicit mentor/ops authorization. They include: modprobe -r of NVIDIA kernel modules, apt remove of running kernel, NVIDIA driver/IMEX reinstall, reboot, edits to /etc/modprobe.d/, manual `mknod` of IMEX channel device, ofed_uninstall, firmware burn (`flint`, `mlxfwreset`), `nv action uninstall system image force`, `nv action reset sdn factory-default`, `nv action stop cluster apps nmx-controller`. Treat all of these as out-of-scope unless told otherwise.

**Read-only diagnostic set (safe to run anytime fabric is suspect):**

Compute node side:
```
nvidia-smi --query-gpu=index,uuid,name,pci.bus_id,fabric.state,fabric.status,fabric.cliqueId,fabric.clusterUuid --format=csv
nvidia-smi -q | grep 'Fabric' -A 20
nvidia-smi nvlink --status
nvidia-smi nvlink --errorcounters
systemctl status nvidia-imex.service
nvidia-imex-ctl -N
ll /dev/nvidia-caps-imex-channels/
systemctl status nvidia-persistenced
uname -r
nvidia-smi -q | grep Platform -A 6
```

Switch tray / NMX-C side (via [[ref-nvos-switch]] SSH):
```
nv show system health
nv show platform chassis-location
nv show interface link-diagnostics
nv show cluster apps
nv show cluster apps running
nv show sdn partition           # needs privileged role
curl http://0.0.0.0:9350/healthcheck
curl http://0.0.0.0:9352/management/statistics
tail -200 /var/log/nmx/nmx-c/fabricmanager.log     # ops only
tail -200 /var/log/nmx/nmx-c/nvlsm.log             # ops only
```

**Diagnostic interpretation:**
- `fabric.state = In Progress` + `CliqueId/ClusterUUID/Partition = N/A` + `cuInit() → 802` means the chassis NMX-C has not onboarded this node to a partition. Compute-side fixes are useless; escalate to switch tray.
- nvbandwidth / NCCL / GEMM / DCGM deep tests are pointless in this state — they all hit the same CUDA init hang.

**IMEX node list note:** SOP example uses 9 nodes at `10.114.228.6–14`; the NVL72 environment we work on uses 18 nodes at `192.168.15.137–154`. Do not copy the SOP's `/etc/nvidia-imex/nodes_config.cfg` over.

**Driver version note:** SOP pins NVIDIA driver `570.26` + CUDA 12.8. Local nodes have been observed at `595.58.03`. Never mix.

**Incomplete sections in source:** APT pin file (§1.6), nvidia-persistenced unit (§1.10), DOCA repo file name (§3.2), FP16+ GEMM commands (§7.2) — do not reconstruct from memory; ask user for the full screenshot before using.
