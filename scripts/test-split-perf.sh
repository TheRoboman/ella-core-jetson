#!/bin/bash
# Reproducible performance test for the Jetson-gNB / ADRV-5GC split.
# Runs the OAI rfsim PHY stack on Jetson against Ella Core on the board,
# measures attach latency and data-plane throughput.
#
# Prereqs:
#   - Board reachable at BOARD_IP, Ella Core running, subscriber provisioned
#   - OAI nr-softmodem and nr-uesoftmodem built on Jetson
#   - iperf3 installed
#   - This script is run from the host where the gNB will run (the Jetson)

set -euo pipefail

BOARD_IP="${BOARD_IP:-169.254.237.42}"
JETSON_IP="${JETSON_IP:-169.254.237.1}"
OAI_DIR="${OAI_DIR:-$HOME/openairinterface5g/cmake_targets/ran_build/build}"
CONFIG_DIR="$(cd "$(dirname "$0")/../configs" && pwd)"
RESULTS_DIR="${RESULTS_DIR:-/tmp/split_perf_$(date +%s)}"

mkdir -p "$RESULTS_DIR"
echo "==> Results will be saved to $RESULTS_DIR"

# --- Sanity checks ---
ping -c 1 -W 2 "$BOARD_IP" > /dev/null || { echo "ERROR: board unreachable at $BOARD_IP"; exit 1; }
[[ -f "$OAI_DIR/nr-softmodem" ]] || { echo "ERROR: OAI gNB not found at $OAI_DIR"; exit 1; }
[[ -f "$OAI_DIR/nr-uesoftmodem" ]] || { echo "ERROR: OAI UE not found at $OAI_DIR"; exit 1; }

# --- Base RTT ---
echo "==> Measuring base network RTT to $BOARD_IP"
ping -c 20 -i 0.2 -q "$BOARD_IP" | tail -2 | tee "$RESULTS_DIR/net_rtt.txt"

# --- Set up UE namespace ---
sudo ip netns del ue_ns 2>/dev/null || true
sudo ip netns add ue_ns
sudo ip netns exec ue_ns ip link set lo up

# --- Start OAI gNB → board ---
echo "==> Starting OAI gNB pointed at $BOARD_IP"
sudo killall nr-softmodem nr-uesoftmodem 2>/dev/null || true
sleep 2
cd "$OAI_DIR"
sudo ./nr-softmodem -O "$CONFIG_DIR/gnb_oai_rfsim_adrv.conf" --rfsim \
    > "$RESULTS_DIR/oai_gnb.log" 2>&1 &
sleep 5

if ! grep -q "Received NGSetupResponse" "$RESULTS_DIR/oai_gnb.log"; then
    echo "ERROR: gNB did not connect to AMF"
    tail "$RESULTS_DIR/oai_gnb.log"
    exit 1
fi
echo "    NGSetupResponse received — gNB connected to board"

# --- Start OAI UE ---
echo "==> Starting OAI nrUE"
T_START=$(date +%s.%N)
sudo ./nr-uesoftmodem -O "$CONFIG_DIR/oai_nrue_rfsim_ella.conf" \
    --rfsim --numerology 1 -r 106 --band 78 \
    -C 3319680000 --ssb 516 --ue-fo-compensation \
    > "$RESULTS_DIR/oai_nrue.log" 2>&1 &
UE_PID=$!

for i in $(seq 1 90); do
    if grep -q "TUN Interface oaitun_ue1 successfully configured" "$RESULTS_DIR/oai_nrue.log" 2>/dev/null; then
        T_END=$(date +%s.%N)
        echo "    UE attached after $(echo "$T_END - $T_START" | bc)s"
        break
    fi
    ps -p $UE_PID > /dev/null || { echo "ERROR: UE died"; tail "$RESULTS_DIR/oai_nrue.log"; exit 1; }
    sleep 1
done

# --- Move TUN into ue_ns to dodge same-host routing ---
echo "==> Moving oaitun_ue1 to ue_ns"
sudo ip link set oaitun_ue1 netns ue_ns
sudo ip netns exec ue_ns ip link set oaitun_ue1 up
sudo ip netns exec ue_ns ip addr add 10.45.0.1/24 dev oaitun_ue1
sudo ip netns exec ue_ns ip route add default dev oaitun_ue1

# --- Data plane: ping ---
echo ""
echo "==> Ping UE → board ($BOARD_IP)"
sudo ip netns exec ue_ns ping -c 10 -i 0.5 -W 2 "$BOARD_IP" \
    | tee "$RESULTS_DIR/ping_board.txt" | tail -2

echo ""
echo "==> Ping UE → Jetson ($JETSON_IP, exercises NAT)"
sudo ip netns exec ue_ns ping -c 10 -i 0.5 -W 2 "$JETSON_IP" \
    | tee "$RESULTS_DIR/ping_jetson.txt" | tail -2

# --- Data plane: iperf3 ---
echo ""
echo "==> Starting iperf3 server on Jetson"
killall iperf3 2>/dev/null || true
iperf3 -s -D
sleep 1

echo ""
echo "==> iperf3 UE → Jetson, TCP, 15s"
sudo ip netns exec ue_ns iperf3 -c "$JETSON_IP" -t 15 \
    | tee "$RESULTS_DIR/iperf3_tcp_ul.txt" | tail -5

echo ""
echo "==> iperf3 Jetson → UE, TCP, 10s (-R)"
sudo ip netns exec ue_ns iperf3 -c "$JETSON_IP" -t 10 -R \
    | tee "$RESULTS_DIR/iperf3_tcp_dl.txt" | tail -5

echo ""
echo "==> iperf3 UDP UE → Jetson @ 5 Mbps, 10s"
sudo ip netns exec ue_ns iperf3 -c "$JETSON_IP" -u -b 5M -t 10 \
    | tee "$RESULTS_DIR/iperf3_udp.txt" | tail -5

killall iperf3 2>/dev/null || true

# --- Cleanup ---
echo ""
echo "==> Cleaning up"
sudo killall nr-softmodem nr-uesoftmodem 2>/dev/null || true
sudo ip netns del ue_ns 2>/dev/null || true

echo ""
echo "==> Done. Results in $RESULTS_DIR"
ls -1 "$RESULTS_DIR"
