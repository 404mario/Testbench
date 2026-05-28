# Why NCCL is implemented this way (and why we need MPI)

## NCCL = GPU data plane only

NCCL's deliberate design: it only handles GPU-to-GPU collective primitives
(ring/tree reductions, peer memcpy, NVLink/IB transport selection). It does
NOT handle:

- Process startup / which-process-on-which-node
- Rank assignment
- The initial 128-byte `ncclUniqueId` rendezvous

Those are someone else's job. NCCL expects to be initialized like:

```c
ncclUniqueId id;
if (rank == 0) ncclGetUniqueId(&id);
// ... somehow get this id to all other ranks ...
ncclCommInitRank(&comm, world_size, id, rank);
```

The "somehow" is what MPI (or torchrun, or Slurm PMIx, or your own TCP server) provides.

## Why MPI is the de facto choice for nccl-tests

OpenMPI provides exactly what nccl-tests needs:
1. `mpirun -np N --hostfile hf` to launch N processes across the nodes in hf
2. `MPI_Bcast` to send the 128-byte ncclUniqueId from rank 0 to everyone else
3. `MPI_Comm_rank` / `MPI_Comm_size` so each process knows its rank/world size

After step 3, NCCL takes over. MPI never touches the actual collective data.
That's why the MPI transport (UCX/IB) choice doesn't affect NCCL bandwidth —
they're independent layers.

## The NVL72 special path: MNNVL (Multi-Node NVLink)

In a regular multi-node setup (e.g. 4 DGX nodes with InfiniBand between them),
NCCL uses:
- NVLink P2P intra-node (8 GPUs in one box)
- IB RDMA inter-node

In NVL72, all 72 GPUs sit in one NVLink domain courtesy of 9 chassis NVSwitches.
NCCL detects this via `cliqueSize=72` and switches to **MNNVL**: it does cross-node
memcpy via `cuMemHostRegister` + IMEX (Inter-node Memory eXchange) for address
translation, but the underlying physical transport is still NVLink5 (53.125 GB/s
× 18 links per GPU).

This is why our 72-GPU all_reduce (747 GB/s) is FASTER than single-node 4-GPU
(646 GB/s) — the per-pair NVLink bandwidth is the same, but with 72 ranks the
NCCL ring has more parallelism.

For MNNVL to work:
- `nvidia-imex` service running on every node (control plane)
- IMEX nodes_config.cfg listing all 18 IPs
- `/dev/nvidia-caps-imex-channels/channel0` device on every node (data plane)
- `cudaInit` succeeding (i.e., fabric.state=Completed)

Missing the channel0 dev node is what bit us on this machine on 2026-05-27 —
17/18 nodes had IMEX control-plane UP but no channel device file. NCCL warned:

```
NCCL WARN MNNVL (cliqueSize 72) is available but not working on this system.
Check the IMEX channel configuration (/dev/nvidia-caps-imex-channels).
```

Fix is `fix_imex_channels.sh` (mknod c $major 0 on each node).

## Transport selection priority (NCCL internal)

When forming a comm, NCCL scans transports per (rank_a, rank_b) pair:
1. `P2P` — direct NVLink between same-node GPUs (PCIe peer access on older HW)
2. `MNNVL` — cross-node NVLink via chassis NVSwitch + IMEX (NVL72 / NVL576)
3. `IB` — InfiniBand RDMA (`NCCL_IB_HCA=mlx5_*` to pin which HCAs)
4. `SHM` — shared memory between same-node ranks (fallback if P2P unavailable)
5. `NET/Socket` — TCP over `NCCL_SOCKET_IFNAME`

For NVL72 within-chassis, transport ends up MNNVL for cross-tray and P2P
intra-tray. IB plays no role for within-chassis traffic, even when IB cards
are present — they're for cross-chassis or external storage.

## Why `UCX_TLS=tcp,self,sm` is set in our env.sh

OpenMPI's PML (Point-to-point Messaging Layer) defaults to UCX, which in turn
defaults to using the fastest available transport — which on our NVL72 means
trying IB (`mlx5_4`). The IB subnet manager isn't running, so UCX times out
and MPI dies before NCCL even starts.

`UCX_TLS=tcp,self,sm` tells UCX: use TCP for inter-node MPI control,
shared-memory for intra-node MPI, self loopback for intra-process. This is
slow for MPI internals but completely irrelevant — once NCCL takes over,
all collective data flows through NVLink anyway.

## References

- NCCL docs: https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/env.html
- NVLink/NVSwitch on NVL72: https://docs.nvidia.com/dgx-superpod/reference-architecture-gb200-dgx/latest/
- IMEX guide: https://docs.nvidia.com/multi-node-nvlink-systems/imex-guide/overview.html
