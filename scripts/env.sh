#!/bin/bash
# NVL72 bench environment — source this before running anything.
# Centralizes all PATH/LD_LIBRARY_PATH/NCCL/UCX env so individual scripts stay clean.

# OpenMPI from NVIDIA HPC-X-style location
export MPI_HOME="${MPI_HOME:-/usr/mpi/gcc/openmpi-4.1.9a1}"
export PATH="$MPI_HOME/bin:$PATH"

# CUDA + MPI runtime libs
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$MPI_HOME/lib:$LD_LIBRARY_PATH"

# UCX: skip IB transports (NVL72 fabric doesn't run IB SM); MPI control flows go over TCP+shared-mem.
# Data plane (NCCL) chooses its own path independently.
export UCX_TLS="${UCX_TLS:-tcp,self,sm}"
export UCX_NET_DEVICES="${UCX_NET_DEVICES:-enP5p9s0}"

# NCCL: bootstrap over the 192.168.15.x management interface.
# Data plane auto-detects: MNNVL (cross-node NVLink via chassis NVSwitch + IMEX) > NVLink P2P > socket.
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enP5p9s0}"
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"

# Bundle root: scripts assume they live at $BUNDLE_ROOT/scripts/
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BUNDLE_ROOT
