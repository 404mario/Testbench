#!/bin/bash
# 在 GB300 (aarch64 + CUDA 13) 上重编 4 个工具的 aarch64 ELF 二进制。
# 不需要 CUDA runtime / fabric ready，只需要 nvcc + 源码。
# 不自动 apt install 任何包；不自动部署到 ~/bench/（避免覆盖 x86 备份留底）。
#
# Usage:
#   bash scripts/build_aarch64_tools.sh             # 编译全部
#   bash scripts/build_aarch64_tools.sh stream      # 只编 stream
#   bash scripts/build_aarch64_tools.sh bench_gemm nccl  # 编 bench_gemm + nccl_tests
#
# 产物落点：
#   stream_tests/stream
#   gemm_tests/bench_gemm
#   nccl_tests/build/{all_reduce_perf,alltoall_perf,...}
#   nvbandwidth_tests/nvbandwidth
#
# 验证：每个产物用 `file` 确认是 aarch64

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda-13}
SBSA_LIB=$CUDA_HOME/targets/sbsa-linux/lib
NCCL_HOME=${NCCL_HOME:-/usr}   # libnccl.so.* in /lib/aarch64-linux-gnu, headers in /usr/include
ARCH=sm_100  # GB300 = Blackwell Ultra

TARGETS=${@:-"stream bench_gemm nccl nvbandwidth"}

hdr() { printf "\n\033[1;36m==[ %s ]==\033[0m\n" "$*"; }
ok()  { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn(){ printf "  \033[33m⚠\033[0m %s\n" "$*"; }
err() { printf "  \033[31m✗\033[0m %s\n" "$*"; }

verify_arch() {
    local f=$1
    local arch=$(file -b "$f" 2>/dev/null | grep -oE 'aarch64|x86-64|x86_64' | head -1)
    if [ "$arch" = "aarch64" ]; then ok "$f → aarch64"
    else err "$f → $arch (WRONG!)"; fi
}

build_stream() {
    hdr "stream_tests/stream"
    cd "$REPO/stream_tests" || return 1
    nvcc -arch=$ARCH -std=c++17 -O3 \
        -I$CUDA_HOME/include -L$SBSA_LIB \
        -lcudart \
        stream.cu stream_json_writer.cpp \
        -o stream 2>&1 | tail -20
    [ -x stream ] && verify_arch "$REPO/stream_tests/stream" || err "build failed"
}

build_bench_gemm() {
    hdr "gemm_tests/bench_gemm"
    cd "$REPO/gemm_tests" || return 1
    nvcc -ccbin g++ -arch=$ARCH -std=c++17 -O3 \
        -I$CUDA_HOME/include -L$SBSA_LIB \
        -lcublas -lcublasLt -lcudart \
        merge2.cu json_writer.cpp \
        -o bench_gemm 2>&1 | tail -20
    [ -x bench_gemm ] && verify_arch "$REPO/gemm_tests/bench_gemm" || err "build failed"
}

build_nccl_tests() {
    hdr "nccl_tests (MPI=0)"
    cd "$REPO/nccl_tests" || return 1
    make MPI=0 CUDA_HOME=$CUDA_HOME NCCL_HOME=$NCCL_HOME -j"$(nproc)" 2>&1 | tail -30
    for b in all_reduce_perf alltoall_perf all_gather_perf reduce_perf reduce_scatter_perf broadcast_perf; do
        if [ -x "build/$b" ]; then verify_arch "$REPO/nccl_tests/build/$b"; fi
    done
}

build_nvbandwidth() {
    hdr "nvbandwidth_tests/nvbandwidth"
    cd "$REPO/nvbandwidth_tests" || return 1
    if ! dpkg -l 2>/dev/null | grep -q libboost-program-options-dev; then
        err "缺依赖: libboost-program-options-dev"
        warn "请手动运行（确认安全后）："
        echo "    sudo apt install -y libboost-program-options-dev"
        warn "已跳过 nvbandwidth_tests 构建。"
        return 0
    fi
    # 清理 x86 残留的 CMake cache
    rm -rf CMakeCache.txt CMakeFiles/ cmake_install.cmake Makefile 2>/dev/null
    cmake -DCMAKE_CUDA_COMPILER=$CUDA_HOME/bin/nvcc \
          -DCMAKE_CUDA_ARCHITECTURES=100 . 2>&1 | tail -15
    make -j"$(nproc)" 2>&1 | tail -15
    [ -x nvbandwidth ] && verify_arch "$REPO/nvbandwidth_tests/nvbandwidth" || err "build failed"
}

# Dispatch
for t in $TARGETS; do
    case $t in
        stream) build_stream ;;
        bench_gemm|gemm) build_bench_gemm ;;
        nccl|nccl_tests|all_reduce_perf|alltoall_perf) build_nccl_tests ;;
        nvbandwidth|nvbw) build_nvbandwidth ;;
        all) build_stream; build_bench_gemm; build_nccl_tests; build_nvbandwidth ;;
        *) warn "未知 target: $t (可选: stream bench_gemm nccl nvbandwidth all)" ;;
    esac
done

hdr "建议下一步部署 (人工执行，避免误覆盖)"
cat << 'EOF'
  # 1. 备份原 x86 二进制（若未做过）
  for f in bench_gemm stream all_reduce_perf alltoall_perf nvbandwidth; do
      [ -x ~/bench/$f ] && [ ! -e ~/bench/$f.x86_64.bak ] && \
          mv ~/bench/$f ~/bench/$f.x86_64.bak
  done

  # 2. 部署 aarch64 产物
  cp stream_tests/stream                  ~/bench/stream
  cp gemm_tests/bench_gemm                ~/bench/bench_gemm
  cp nccl_tests/build/all_reduce_perf     ~/bench/all_reduce_perf
  cp nccl_tests/build/alltoall_perf       ~/bench/alltoall_perf
  cp nvbandwidth_tests/nvbandwidth        ~/bench/nvbandwidth     # 若已编

  # 3. 同步 spec
  cp spec/*.json                          ~/bench/spec/

  # 4. 部署改进后的 run_parallel_test.sh（如果仓库有更新）
  cp scripts/run_parallel_test.sh         ~/bench/

  # 5. 验证
  file ~/bench/{bench_gemm,stream,all_reduce_perf,alltoall_perf,nvbandwidth} 2>/dev/null
EOF
