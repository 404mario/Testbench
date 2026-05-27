#!/bin/bash
# Build nccl-tests with MPI=1 — produces the *_perf_mpi binaries needed for
# the cluster (multi-node) collective benchmarks.
#
# Use this when you need to:
#   - regenerate the MPI binaries after a NCCL or CUDA upgrade
#   - bootstrap a fresh OSS bundle
#
# Output: /root/nccl-tests/build/{all_reduce,alltoall,all_gather,broadcast,reduce,reduce_scatter,sendrecv,...}_perf
#
# The single-node (non-MPI) variants are built by ./build_aarch64_tools.sh.

set -e
SRC_DIR="${NCCL_TESTS_SRC:-/root/nccl-tests}"
MPI_HOME="${MPI_HOME:-/usr/mpi/gcc/openmpi-4.1.9a1}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
NCCL_HOME="${NCCL_HOME:-/usr}"   # libnccl.so via ldconfig path on Ubuntu image

if [ ! -d "$SRC_DIR" ]; then
  echo "Cloning nccl-tests into $SRC_DIR ..."
  git clone --depth 1 https://github.com/NVIDIA/nccl-tests.git "$SRC_DIR"
fi

cd "$SRC_DIR"

if [ ! -x "$MPI_HOME/bin/mpicc" ]; then
  echo "FATAL: mpicc not found at $MPI_HOME/bin/mpicc" >&2
  echo "Hint: dpkg -L openmpi | grep bin/mpicc      # to find your install" >&2
  exit 1
fi

export PATH="$MPI_HOME/bin:$PATH"

make -j"$(nproc)" \
  MPI=1 \
  MPI_HOME="$MPI_HOME" \
  CUDA_HOME="$CUDA_HOME" \
  NCCL_HOME="$NCCL_HOME"

echo
echo "===built binaries (link check)==="
for b in all_reduce alltoall all_gather broadcast reduce reduce_scatter sendrecv; do
  bin="build/${b}_perf"
  if [ -x "$bin" ] && ldd "$bin" | grep -q libmpi.so; then
    printf '  %-22s  ✓ MPI linked\n' "${b}_perf"
  else
    printf '  %-22s  ✗ missing or no MPI\n' "${b}_perf"
  fi
done

echo
echo "Stage these into ./bin/mpi/ of the OSS bundle (rename with _mpi suffix to avoid"
echo "clashing with the non-MPI variants in ~/bench/):"
echo "  for b in all_reduce alltoall all_gather broadcast reduce reduce_scatter sendrecv; do"
echo "    cp $SRC_DIR/build/\${b}_perf /path/to/bundle/bin/mpi/\${b}_perf_mpi"
echo "  done"
