#!/bin/bash
# Start Ella Core (patched for kernel 5.15 userspace UPF)
# Prerequisite: network interfaces must exist (run setup-ella-net.sh first)

set -e

ELLA_DIR="/home/rapidbeam/ella-core"
ELLA_CONFIG="/home/rapidbeam/ella-core-trial/core.yaml"
ELLA_LOG="/tmp/ella-core.log"

# Check interfaces exist
if ! ip link show ella-n3 &>/dev/null; then
    echo "ERROR: ella-n3 interface not found. Run setup-ella-net.sh first."
    exit 1
fi

# Kill any existing instance
sudo killall core 2>/dev/null || true
sleep 1

# Start Ella Core
echo "Starting Ella Core..."
cd "$ELLA_DIR"
sudo nohup ./core -config "$ELLA_CONFIG" > "$ELLA_LOG" 2>&1 &
sleep 3

# Verify it's running
if pgrep -f "core -config" > /dev/null; then
    echo "Ella Core started (PID: $(pgrep -f 'core -config' | tail -1))"
    echo "API: https://127.0.0.1:5002"
    echo "NGAP: 10.3.0.2:38412"
    echo "GTP-U: 10.3.0.2:2152"
    echo "Log: $ELLA_LOG"

    # Check for errors
    if grep -q "fatal\|panic" "$ELLA_LOG" 2>/dev/null; then
        echo "WARNING: Errors detected in log!"
        grep "fatal\|panic" "$ELLA_LOG"
    fi
else
    echo "ERROR: Ella Core failed to start"
    tail -20 "$ELLA_LOG"
    exit 1
fi
