---
name: ref-build-aarch64
description: 在 GB300 (aarch64 + CUDA 13.2) 上重编 4 工具的精确命令。详见 scripts/build_aarch64_tools.sh，本备忘只记关键参数。
metadata: 
  node_type: memory
  type: reference
  originSessionId: 3b508727-f532-4710-94b8-488cbd33ed4d
---

**Targets**：sm_100（Blackwell Ultra GB300）。CUDA_HOME=/usr/local/cuda-13，cuBLAS at `/usr/local/cuda/targets/sbsa-linux/lib`，NCCL 2.29.7 at `/lib/aarch64-linux-gnu/`。

| 工具 | 命令 | 产物大小 | 备注 |
|------|------|---------|------|
| `stream` | `nvcc -arch=sm_100 -std=c++17 -O3 -lcudart stream.cu stream_json_writer.cpp -o stream` | 242K | 源码 cudaInit 在 argparse 之前 → `--help` 也会 hang（设计 bug，不影响功能） |
| `bench_gemm` | `nvcc -ccbin g++ -arch=sm_100 -std=c++17 -O3 -lcublas -lcublasLt -lcudart merge2.cu json_writer.cpp -o bench_gemm` | 308K | 比原 776M x86 静态链接小很多；`--help` 正常返回（argparse 在 cudaInit 之前） |
| `nccl_tests` | `make MPI=0 CUDA_HOME=/usr/local/cuda-13 NCCL_HOME=/usr -j` 在 `nccl_tests/` | 24-32M × 10 个 | 单节点版本；多节点要 MPI=1 |
| `nvbandwidth` | `rm -rf CMakeCache.txt CMakeFiles/ && cmake -DCMAKE_CUDA_ARCHITECTURES=100 . && make -j` | 2.2M | 必须先清 x86 cache 残留；依赖 `libboost-program-options-dev`（已装） |

**所有产物**都是 dynamically linked ELF aarch64，需要：
- `libcudart.so.13` (`/usr/local/cuda-13/targets/sbsa-linux/lib/`)
- `libcublas.so.13` / `libcublasLt.so.13`（bench_gemm 用）
- `libnccl.so.2`（nccl_tests 用）

部署到 `~/bench/` 时**不需要**改 `LD_LIBRARY_PATH`——`run_parallel_test.sh` v8 自己设了 `LD_LIBRARY_PATH=/usr/local/cuda/lib64`。

**`scripts/build_aarch64_tools.sh`** 是封装入口；该脚本不自动 apt install（boost dep 缺失时只打印提示），不自动部署到 ~/bench（避免覆盖备份）。
