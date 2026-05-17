#!/bin/bash
# Create network interfaces for Ella Core
# Run once after boot (interfaces are not persistent)

set -e

echo "Creating Ella Core network interfaces..."

# veth pair for N2/N3 (gNB ↔ core)
if ! ip link show ella-n3 &>/dev/null; then
    sudo ip link add ella-n3 type veth peer name ella-n3-peer
    sudo ip addr add 10.3.0.2/24 dev ella-n3
    sudo ip addr add 10.3.0.1/24 dev ella-n3-peer
    sudo ip link set ella-n3 up
    sudo ip link set ella-n3-peer up
    echo "  Created veth pair: ella-n3 (10.3.0.2) <-> ella-n3-peer (10.3.0.1)"
else
    echo "  ella-n3 already exists"
fi

# Dummy interface for N6 (core → internet)
if ! ip link show ella-n6 &>/dev/null; then
    sudo ip link add ella-n6 type dummy
    sudo ip addr add 10.6.0.2/24 dev ella-n6
    sudo ip link set ella-n6 up
    echo "  Created dummy: ella-n6 (10.6.0.2)"
else
    echo "  ella-n6 already exists"
fi

# NAT for UE traffic
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! sudo iptables -t nat -C POSTROUTING -s 10.45.0.0/16 ! -o ella-n6 -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 ! -o ella-n6 -j MASQUERADE
    echo "  Added NAT rule for 10.45.0.0/16"
else
    echo "  NAT rule already exists"
fi

echo "Done. Ella Core can now bind to:"
echo "  N2/NGAP: 10.3.0.2:38412"
echo "  N3/GTP-U: 10.3.0.2:2152"
echo "  gNB bind: 10.3.0.1"
