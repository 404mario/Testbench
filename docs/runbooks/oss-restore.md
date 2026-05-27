# OSS bundle restore — one-click bring-up on a wiped testbench

This testbench is volatile — the OS image gets refreshed periodically, taking
every binary and locally-built artifact with it. To skip the 30-minute
rebuild dance, we package a snapshot of working binaries + scripts + spec +
docs to Alibaba Cloud OSS. New machine → `ossutil cp` → tar → setup → done.

## What's in the bundle (`nvl72-bench-bundle.tar.gz`, ~38 MB)

```
bench-bundle/
├── README.md                self-contained instructions
├── manifest.json            versions + sha256 of every binary
├── bin/
│   ├── single-node/         no-MPI binaries: stream, bench_gemm,
│   │                        nvbandwidth, all_reduce_perf, alltoall_perf
│   └── mpi/                 7 MPI binaries: all_reduce_perf_mpi,
│                            alltoall_perf_mpi, all_gather_perf_mpi,
│                            broadcast_perf_mpi, reduce_perf_mpi,
│                            reduce_scatter_perf_mpi, sendrecv_perf_mpi
├── scripts/                 env.sh, setup.sh, fix_imex_channels.sh,
│                            runner_cluster.sh, run_parallel_test.sh (v9),
│                            hostfile.nvl72
├── spec/                    GPU-specific acceptance thresholds (JSON)
├── docs/                    nccl_design.md, troubleshooting.md
└── results_baseline/        2026-05-27 reference run logs
```

What is NOT in the bundle (must already exist on each new machine):

- NVIDIA driver `595.71.05` + CUDA 13.2 + NCCL 2.29.7
- OpenMPI at `/usr/mpi/gcc/openmpi-4.1.9a1/`
- Working chassis NVSwitch fabric (`fabric.state = Completed`)
- Root SSH passwordless any-to-any across all 18 nodes

If any of these are missing, fix them first (outside this bundle).

## Prerequisites: install ossutil

```bash
# Pick the matching architecture; this rig is aarch64
curl -L https://gosspublic.alicdn.com/ossutil/v2/2.0.0/ossutil-2.0.0-linux-arm64.zip -o /tmp/ossutil.zip
unzip /tmp/ossutil.zip -d /tmp/
sudo install -m 755 /tmp/ossutil-2.0.0-linux-arm64/ossutil /usr/local/bin/ossutil

# verify
ossutil --version
```

## Configure ossutil (one-time per machine)

```bash
ossutil config -e <endpoint> -i <access_key_id> -k <access_key_secret>
# example endpoint: oss-cn-hangzhou.aliyuncs.com   (public)
# example endpoint: oss-cn-hangzhou-internal.aliyuncs.com   (intra-VPC, faster + free egress)
```
This writes `~/.ossutilconfig` (chmod 600). Use intra-VPC endpoint if the
testbench is in the same Alibaba Cloud region as the bucket — the bundle
download will be free and ~5× faster.

## Restore steps on a fresh machine

```bash
# 1. download the bundle
ossutil cp oss://<bucket>/<prefix>/nvl72-bench-bundle.tar.gz /tmp/

# 2. extract to the canonical path
tar xf /tmp/nvl72-bench-bundle.tar.gz -C /root/
mv /root/nvl72-bench-bundle /root/bench-bundle

# 3. edit hostfile if your IP range differs (it's bundled with .137-.154)
$EDITOR /root/bench-bundle/scripts/hostfile.nvl72

# 4. one-time bootstrap: SSH check + IMEX channel fix + distribute to 17 nodes
cd /root/bench-bundle
./scripts/setup.sh

# 5. ready
./scripts/run_parallel_test.sh --mode=72gpu all_reduce
```

The whole thing — fresh machine to first 72-GPU NCCL number — should take
under 5 minutes if prereqs are met.

## Versioning the bundle in OSS

Recommended prefix layout:

```
oss://<bucket>/nvl72/bench/
├── latest/
│   └── nvl72-bench-bundle.tar.gz   ← always the most recent known-good
├── 2026-05-27-bringup/
│   ├── nvl72-bench-bundle.tar.gz
│   └── manifest.json               ← copy out for quick inspection
└── 2026-06-??-driver-upgrade/
    └── ...
```

`latest/` is what you `cp` for routine restores. Date-prefixed snapshots are
kept indefinitely so you can roll back to a known-good combination of
driver + CUDA + NCCL + binaries when a new version regresses.

Upload pattern (after a successful bench session that you want to immortalize):

```bash
cd /root/dist
sha256sum nvl72-bench-bundle.tar.gz > nvl72-bench-bundle.tar.gz.sha256

DATE_TAG=$(date +%Y-%m-%d)-bringup       # or -driver-upgrade, etc.

ossutil cp nvl72-bench-bundle.tar.gz \
    oss://<bucket>/nvl72/bench/$DATE_TAG/
ossutil cp nvl72-bench-bundle.tar.gz.sha256 \
    oss://<bucket>/nvl72/bench/$DATE_TAG/
ossutil cp /root/dist/nvl72-bench-bundle/manifest.json \
    oss://<bucket>/nvl72/bench/$DATE_TAG/

# update latest pointer
ossutil cp nvl72-bench-bundle.tar.gz \
    oss://<bucket>/nvl72/bench/latest/
ossutil cp nvl72-bench-bundle.tar.gz.sha256 \
    oss://<bucket>/nvl72/bench/latest/
```

## Verifying download integrity

```bash
ossutil cp oss://<bucket>/nvl72/bench/latest/nvl72-bench-bundle.tar.gz.sha256 /tmp/
ossutil cp oss://<bucket>/nvl72/bench/latest/nvl72-bench-bundle.tar.gz /tmp/
cd /tmp && sha256sum -c nvl72-bench-bundle.tar.gz.sha256
# expect: nvl72-bench-bundle.tar.gz: OK
```

Mismatched checksum → re-download. Bundle binaries are stripped but
architecture-specific (aarch64 only on GB300/Grace); copying an x86 bundle
to a sbsa node manifests as `Exec format error` at runtime.

## Bandwidth note

The 38 MB bundle takes ~30 seconds to download from intra-VPC OSS, ~3 minutes
over public Internet. Fine for occasional restores. If wipes become frequent
enough to matter, consider mounting OSS as a read-only filesystem via ossfs
instead of repeatedly downloading.
