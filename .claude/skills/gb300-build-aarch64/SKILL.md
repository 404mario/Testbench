---
name: gb300-build-aarch64
description: Cross-compile the 4 Testbench tools (bench_gemm, stream, nccl_tests, nvbandwidth) for aarch64 on a GB300 host. Use when ~/bench/* binaries are x86_64 (Exec format error) and need to be rebuilt natively, or when the user asks "重编 / build / compile aarch64 / 编 GB300 二进制". Does NOT require fabric.state=Completed (compile-only, no CUDA runtime).
---

# GB300 Build aarch64 Tools

**Trigger when**: `~/bench/` binaries are wrong arch (x86_64 on aarch64 host); user asks to build, compile, or rebuild; following a recipe update.

**Pre-check (read-only, fast)**:

```bash
file ~/bench/{bench_gemm,stream,all_reduce_perf,alltoall_perf,nvbandwidth} 2>/dev/null
```

If any line shows `x86-64`, rebuild is needed.

**Action**:

```bash
# 全部编
bash scripts/build_aarch64_tools.sh

# 只编一个
bash scripts/build_aarch64_tools.sh stream
bash scripts/build_aarch64_tools.sh bench_gemm
bash scripts/build_aarch64_tools.sh nccl
bash scripts/build_aarch64_tools.sh nvbandwidth
```

**What it does**:
- Compiles for `sm_100` (GB300), using `CUDA_HOME=/usr/local/cuda-13` + `NCCL_HOME=/usr` + cuBLAS at `/usr/local/cuda/targets/sbsa-linux/lib`
- nccl_tests: `make MPI=0` (single-node only; multi-node will need MPI later)
- nvbandwidth: cleans x86 CMake cache, reconfigures for aarch64; if `libboost-program-options-dev` missing, **prints suggested `sudo apt install` and skips** (does NOT auto-install)
- Verifies each output with `file` showing `aarch64`
- **Does NOT auto-deploy** to `~/bench/`. Prints the suggested deploy commands at the end for human execution.

**Manual deploy step** (after build succeeds, with human oversight):
```bash
# Backup x86 versions if not yet done
for f in bench_gemm stream all_reduce_perf alltoall_perf nvbandwidth; do
    [ -x ~/bench/$f ] && [ ! -e ~/bench/$f.x86_64.bak ] && mv ~/bench/$f ~/bench/$f.x86_64.bak
done

# Deploy
cp stream_tests/stream            ~/bench/
cp gemm_tests/bench_gemm          ~/bench/
cp nccl_tests/build/all_reduce_perf  ~/bench/
cp nccl_tests/build/alltoall_perf    ~/bench/
cp nvbandwidth_tests/nvbandwidth  ~/bench/   # 若已编

# Sync spec
cp spec/*.json ~/bench/spec/
```

**Hard limits**: MUST NOT `sudo apt install` anything automatically. MUST NOT delete the x86 backups (`*.x86_64.bak`). MUST NOT commit compiled binaries — `.gitignore` already excludes them.

**Note on CUDA runtime**: compile-only does NOT require `fabric.state=Completed`. You can build during the fabric blocker without issue.
