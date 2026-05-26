#!/bin/bash
# Cross-compile OpenAirInterface nr-softmodem for armhf (ADRV9361-Z7035).
# Produces a binary that can run as VNF, PNF, or monolithic gNB via --nfapi.
#
# Two-stage build (per OAI's official cross-compile guide):
#  1. Build LDPC code generators + generate_T for the build HOST (aarch64
#     Jetson here). These are tools that run at compile time to emit C source.
#  2. Cross-compile everything else for armhf, pointing at the host-built
#     generators via -DNATIVE_DIR.
#
# Requires:
#   - gcc-arm-linux-gnueabihf, g++ same
#   - armhf foreign architecture enabled: `dpkg --add-architecture armhf && apt update`
#   - armhf libs installed:
#       libblas-dev, liblapacke-dev, libfftw3-dev, libconfig-dev,
#       libsctp-dev, libssl-dev, libcap-dev, libnuma-dev, zlib1g-dev
#     (all the :armhf variants)
#   - OAI source patched via patches/oai-armhf.patch (this directory)

set -euo pipefail

OAI_DIR="${OAI_DIR:-${HOME}/openairinterface5g}"
NATIVE_DIR="build_host_aarch64"
ARMHF_DIR="build_armhf"

[[ -d "$OAI_DIR" ]] || { echo "OAI source not found at $OAI_DIR"; exit 1; }
which arm-linux-gnueabihf-gcc > /dev/null || { echo "install gcc-arm-linux-gnueabihf"; exit 1; }

cd "$OAI_DIR/cmake_targets/ran_build"

# --- Stage 1: host-side code generators -------------------------------------
if [[ ! -f "$NATIVE_DIR/common/utils/T/genids" ]]; then
    echo "==> Stage 1: building host (aarch64) code generators"
    mkdir -p "$NATIVE_DIR"
    (cd "$NATIVE_DIR" && cmake ../../.. -G Ninja)
    (cd "$NATIVE_DIR" && ninja -j$(nproc) ldpc_generators generate_T)
else
    echo "==> Stage 1 already built (genids present)"
fi

# --- Stage 2: armhf cross-compile -------------------------------------------
echo "==> Stage 2: cross-compile for armhf"
rm -rf "$ARMHF_DIR"
mkdir -p "$ARMHF_DIR"
cd "$ARMHF_DIR"
cmake ../../.. -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$OAI_DIR/cmake_targets/armhf-toolchain.cmake" \
  -DNATIVE_DIR="../$NATIVE_DIR" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DAVX2=OFF -DAVX512=OFF

ninja -j$(nproc) nr-softmodem params_libconfig coding rfsimulator

echo ""
echo "==> Stripping binaries"
arm-linux-gnueabihf-strip nr-softmodem
arm-linux-gnueabihf-strip librfsimulator.so 2>/dev/null || true

echo ""
echo "==> Build complete:"
ls -lh nr-softmodem librfsimulator.so libparams_libconfig.so 2>&1 | head -3
file nr-softmodem | head -1
