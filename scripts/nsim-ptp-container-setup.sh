#!/bin/bash
# Create /dev/ptpN device nodes inside containers where udev rules don't run.
#
# Containers see /dev/nsim_ptpN (propagated by the runtime) but NOT the
# /dev/ptpN nodes created by the host's udev rule.  This script recreates
# them so linuxptp tools, ethtool, and the ptp-operator find the devices
# at the standard paths.
#
# Usage:
#   As an init container:  scripts/nsim-ptp-container-setup.sh
#   From a DaemonSet:      scripts/nsim-ptp-container-setup.sh --watch
#
# With --watch the script loops every 5 s, useful as a sidecar.
set -euo pipefail

create_nodes() {
    local created=0
    for dev in /dev/nsim_ptp*; do
        [ -e "$dev" ] || continue
        local n="${dev##*nsim_ptp}"
        local target="/dev/ptp${n}"

        if [ -e "$target" ]; then
            continue
        fi

        local maj min
        maj=$(stat -c '%t' "$dev" 2>/dev/null) || continue
        min=$(stat -c '%T' "$dev" 2>/dev/null) || continue
        mknod "$target" c "0x$maj" "0x$min" 2>/dev/null || true
        chmod 666 "$target" 2>/dev/null || true
        echo "created $target (c $maj:$min)"
        created=$((created + 1))
    done
    return $created
}

create_nodes

if [ "${1:-}" = "--watch" ]; then
    while true; do
        sleep 5
        create_nodes 2>/dev/null || true
    done
fi
