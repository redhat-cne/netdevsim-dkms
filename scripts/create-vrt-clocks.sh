#!/bin/bash
# Create per-node stand-in mock PHCs that act as virtual CLOCK_REALTIME targets
# for Kind/netdevsim CI (used with the phc2sys LD_PRELOAD shim).
#
# Usage:
#   ./create-vrt-clocks.sh [node1] [node2] [node3]
# Defaults: kind-netdevsim-worker kind-netdevsim-worker2 kind-netdevsim-worker3
#
# For each node, creates a 1-port netdevsim device with a unique logical clock,
# writes /var/run/ptp/vrt/device inside that Kind node (seen by linuxptp pods as
# /var/run/vrt/device via the existing hostPath mount).

set -euo pipefail

if [[ $# -eq 0 ]]; then
	NODES=(kind-netdevsim-worker kind-netdevsim-worker2 kind-netdevsim-worker3)
else
	NODES=("$@")
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
	PCI_PREFIX="0000:1f"
elif [[ "$ARCH" == "aarch64" ]]; then
	PCI_PREFIX="0001:1f"
else
	echo "Unsupported architecture: $ARCH" >&2
	exit 1
fi

NSIM_NEW=/sys/bus/netdevsim/new_device
NSIM_DEL=/sys/bus/netdevsim/del_device

# Reserved IDs well above the topology devices (1..18) in configSwitch2.sh.
BASE_ID=90
# PCI function slot 0x10+ also above topology (0x01..0x0f).
BASE_FUNC=0x10

runtime_exec() {
	local name=$1
	shift
	if podman inspect "$name" &>/dev/null; then
		podman exec "$name" "$@"
	elif docker inspect "$name" &>/dev/null; then
		docker exec "$name" "$@"
	else
		echo "Error: Kind node container '$name' not found" >&2
		return 1
	fi
}

phc_index_for_nsim() {
	local nsim_id=$1
	local netdir iface idx
	netdir="/sys/bus/netdevsim/devices/netdevsim${nsim_id}/net"
	iface=$(find "$netdir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
	if [[ -z "$iface" ]]; then
		echo "Error: no netdev for netdevsim${nsim_id}" >&2
		return 1
	fi
	idx=$(ethtool -T "$iface" 2>/dev/null | awk '/PTP Hardware Clock:/ {print $4}')
	if [[ -z "$idx" || "$idx" == "none" ]]; then
		echo "Error: no PHC on $iface (netdevsim${nsim_id})" >&2
		return 1
	fi
	echo "$idx"
}

i=0
for node in "${NODES[@]}"; do
	id=$((BASE_ID + i))
	clk=$id
	func=$((BASE_FUNC + i))
	pci=$(printf '%s:%02x.0' "$PCI_PREFIX" "$func")

	# Replace any previous VRT device with this id.
	echo "$id" >"$NSIM_DEL" 2>/dev/null || true
	if ! echo "$id $pci $clk 1" >"$NSIM_NEW"; then
		echo "Error: failed to create netdevsim id=$id pci=$pci" >&2
		exit 1
	fi
	udevadm settle 2>/dev/null || sleep 0.5
	chmod 666 /dev/nsim_ptp* 2>/dev/null || true

	phc=$(phc_index_for_nsim "$id")
	dev="/dev/ptp${phc}"
	if [[ ! -e "$dev" ]]; then
		echo "Error: $dev does not exist after creating netdevsim${id}" >&2
		exit 1
	fi

	# Keep the unused netdev down; only the PHC chardev is needed.
	netdir="/sys/bus/netdevsim/devices/netdevsim${id}/net"
	iface=$(find "$netdir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
	ip link set dev "$iface" down 2>/dev/null || true

	# Node-local path under the hostPath root used by linuxptp-daemon (/var/run/ptp).
	runtime_exec "$node" mkdir -p /var/run/ptp/vrt
	runtime_exec "$node" bash -c "echo -n '$dev' > /var/run/ptp/vrt/device"
	runtime_exec "$node" bash -c "ln -sfn '$dev' /var/run/ptp/vrt/ptpRT"

	echo "VRT: node=$node nsim=$id pci=$pci clk=$clk phc=$dev"
	i=$((i + 1))
done

echo "Created ${i} virtual RT stand-in PHC(s)"
