#!/bin/bash
# Cross-compile Ella Core for armv7 (ADRV9361-Z7035 / Zynq-7035 Cortex-A9)
#
# Output: /home/rapidbeam/ella-core/core-armv7  (~50 MB unstripped, ~35 MB stripped)
#
# Requires: Go 1.26+, gcc-arm-linux-gnueabihf
#
# Source patches:
#   - Userspace UPF fallback (also enables build on kernel < 6.8)
#   - 4 fixes for 32-bit int overflow on armv7

set -euo pipefail

ELLA_CORE_DIR="${ELLA_CORE_DIR:-${HOME}/ella-core}"
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"

# Clone if not present
if [[ ! -d "$ELLA_CORE_DIR" ]]; then
    git clone https://github.com/ellanetworks/core.git "$ELLA_CORE_DIR"
    cd "$ELLA_CORE_DIR"
    git checkout v1.10.2
    # Apply patches
    git apply "$(dirname "$0")/../patches/userspace-upf-and-armv7.patch"
fi

cd "$ELLA_CORE_DIR"

# Cross-compile
export PATH="$(dirname $GO_BIN):$PATH"
export CC=arm-linux-gnueabihf-gcc
export CGO_ENABLED=1
export GOOS=linux
export GOARCH=arm
export GOARM=7

echo "Cross-compiling Ella Core for armv7..."
"$GO_BIN" build -o core-armv7 ./cmd/core/

echo ""
echo "Built: $ELLA_CORE_DIR/core-armv7"
file core-armv7
ls -lh core-armv7
