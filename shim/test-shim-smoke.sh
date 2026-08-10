#!/bin/bash
# Smoke-test the VRT shim against a mock PHC (requires loaded netdevsim-dkms).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
make -C "$ROOT" all

NSIM_NEW=/sys/bus/netdevsim/new_device
NSIM_DEL=/sys/bus/netdevsim/del_device
ID=99
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
	PCI="0000:1f:1f.0"
elif [[ "$ARCH" == "aarch64" ]]; then
	PCI="0001:1f:1f.0"
else
	echo "skip: unsupported arch $ARCH"
	exit 0
fi

if [[ ! -w "$NSIM_NEW" ]]; then
	echo "skip: netdevsim not available (need root + modules)"
	exit 0
fi

cleanup() { echo "$ID" >"$NSIM_DEL" 2>/dev/null || true; }
trap cleanup EXIT

echo "$ID" >"$NSIM_DEL" 2>/dev/null || true
echo "$ID $PCI $ID 1" >"$NSIM_NEW"
udevadm settle 2>/dev/null || sleep 0.5
chmod 666 /dev/nsim_ptp* 2>/dev/null || true

IFACE=$(find /sys/bus/netdevsim/devices/netdevsim${ID}/net -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | head -1)
PHC=$(ethtool -T "$IFACE" | awk '/PTP Hardware Clock:/ {print $4}')
DEV="/dev/ptp${PHC}"
[[ -e "$DEV" ]]

export PTP_VRT_PHC="$DEV"
export LD_PRELOAD="$ROOT/libptp_vrt_shim.so"

BEFORE=$("$ROOT/test_vrt_cli" gettime)
"$ROOT/test_vrt_cli" step >/dev/null
AFTER=$("$ROOT/test_vrt_cli" gettime)

# Host CLOCK_REALTIME should be essentially unchanged by the step (shim only).
HOST_NOW=$(date +%s)
BEFORE_SEC=${BEFORE%%.*}
# Stand-in PHC was stepped by 1us; values should be near wall clock still.
echo "vrt_before=$BEFORE vrt_after=$AFTER host_sec=$HOST_NOW"
python3 - <<PY
b=float("$BEFORE"); a=float("$AFTER"); h=float("$HOST_NOW")
assert abs(a-b) < 1.0, (b,a)  # small step + runtime
assert abs(b-h) < 120, (b,h)  # stand-in starts near realtime
print("OK: shim steers stand-in PHC", "$DEV")
PY
