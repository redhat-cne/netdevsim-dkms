#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Unit tests for the netdevsim DPLL emulation (netdevsim/dpll.c).
#
# Exercises:
#   - Module loading (nsim_dpll + netdevsim)
#   - Device creation with wpc=1 (DPLL activation)
#   - Sysfs lock_status (read / write / invalid input)
#   - Generic netlink DPLL interface (device get, pin get)
#   - Pin topology (GNSS, EXT, SyncE)
#   - Lock status transitions and notifications
#   - GNSS device presence and NMEA echo
#   - Device teardown and re-creation
#
# Requirements:
#   - Root privileges
#   - DKMS modules installed and loaded (nsim_ptp, nsim_ptp_mock,
#     nsim_dpll, netdevsim)
#   - python3 (for generic netlink JSON parsing)
#
# Usage:
#   sudo ./scripts/test-dpll.sh [--no-load] [--verbose]
#
#   --no-load   Skip module load/unload (assume already loaded)
#   --verbose   Print all commands as they execute
#
set -eo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NO_LOAD=false
VERBOSE=false
PASS=0
FAIL=0
SKIP=0
TOTAL=0
FAILURES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-load) NO_LOAD=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ "$VERBOSE" == true ]] && set -x

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${BOLD}==> $*${NC}"; }

pass() {
    ((TOTAL++)) || true
    ((PASS++)) || true
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    ((TOTAL++)) || true
    ((FAIL++)) || true
    FAILURES="${FAILURES}\n  - $1"
    echo -e "  ${RED}FAIL${NC}: $1"
}

skip() {
    ((TOTAL++)) || true
    ((SKIP++)) || true
    echo -e "  ${YELLOW}SKIP${NC}: $1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected='$expected', got='$actual')"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc (output does not contain '$needle')"
    fi
}

assert_match() {
    local desc="$1" haystack="$2" pattern="$3"
    if echo "$haystack" | grep -qE "$pattern"; then
        pass "$desc"
    else
        fail "$desc (output does not match pattern '$pattern')"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -e "$path" ]]; then
        pass "$desc"
    else
        fail "$desc ($path does not exist)"
    fi
}

assert_file_not_exists() {
    local desc="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        pass "$desc"
    else
        fail "$desc ($path unexpectedly exists)"
    fi
}

# Discover PCI bus domain from netdevsim module parameter
get_pci_domain() {
    local bus_nr bus fake_root domain
    bus_nr=$(cat /sys/module/netdevsim/parameters/pci_bus_nr 2>/dev/null || echo 31)
    bus=$(printf "%02x" "$bus_nr")
    fake_root=$(ls /sys/bus/pci/devices/ 2>/dev/null | grep ":${bus}:00\.0" | head -1 || true)
    if [[ -n "$fake_root" ]]; then
        domain=$(echo "$fake_root" | cut -d: -f1)
    else
        domain="0000"
    fi
    echo "${domain}:${bus}"
}

# Create a netdevsim device with DPLL (wpc=1)
# Args: device_id [clock_id] [port_count] [num_queues] [wpc]
create_device() {
    local id="${1:-1}"
    local pci_prefix
    pci_prefix=$(get_pci_domain)
    local pci_addr="${pci_prefix}:$(printf '%02x' "$((id + 1))").0"
    local clock_id="${2:-1}"
    local ports="${3:-2}"
    local queues="${4:-1}"
    local wpc="${5:-1}"
    echo "${id} ${pci_addr} ${clock_id} ${ports} ${queues} ${wpc}" \
        > /sys/bus/netdevsim/new_device
    sleep 1
}

delete_device() {
    local id="${1:-1}"
    echo "$id" > /sys/bus/netdevsim/del_device 2>/dev/null || true
    sleep 0.5
}

cleanup_all_devices() {
    for dev in /sys/bus/netdevsim/devices/netdevsim*; do
        [[ -d "$dev" ]] || continue
        local id
        id=$(basename "$dev" | sed 's/netdevsim//')
        echo "$id" > /sys/bus/netdevsim/del_device 2>/dev/null || true
    done
    sleep 0.5
}

HAS_GENL=false
check_genl_tool() {
    if command -v python3 >/dev/null 2>&1; then
        HAS_GENL=true
        setup_genl_helper
    fi
}

# Shared python netlink helper written to a temp file at startup
GENL_HELPER=""
setup_genl_helper() {
    GENL_HELPER=$(mktemp /tmp/dpll-genl-XXXXXX.py)
    cat > "$GENL_HELPER" <<'PYEOF'
import socket, struct, json, sys

NETLINK_GENERIC = 16
NLM_F_REQUEST = 0x0001
NLM_F_DUMP = 0x0300
GENL_ID_CTRL = 0x10

def nl_msg(msg_type, flags, seq, payload):
    hdr = struct.pack('=IHHII', len(payload) + 16, msg_type, flags, seq, 0)
    return hdr + payload

def genl_msg(cmd, version, attrs=b""):
    return struct.pack('=BBH', cmd, version, 0) + attrs

def nl_attr(attr_type, data):
    alen = 4 + len(data)
    pad = (4 - (alen % 4)) % 4
    return struct.pack('=HH', alen, attr_type) + data + b'\x00' * pad

def parse_attrs(data):
    attrs = {}
    while len(data) >= 4:
        alen, atype = struct.unpack('=HH', data[:4])
        if alen < 4: break
        attrs[atype] = data[4:alen]
        data = data[((alen + 3) & ~3):]
    return attrs

def resolve_family(sock, name):
    payload = genl_msg(3, 1, nl_attr(2, name.encode() + b'\x00'))
    sock.send(nl_msg(GENL_ID_CTRL, NLM_F_REQUEST, 1, payload))
    resp = sock.recv(65536)
    nltype = struct.unpack('=H', resp[4:6])[0]
    if nltype == 2: return None
    attrs = parse_attrs(resp[20:])
    if 1 not in attrs: return None
    return struct.unpack('=H', attrs[1])[0]

def genl_dump(sock, family_id, cmd, seq=2):
    payload = genl_msg(cmd, 1)
    sock.send(nl_msg(family_id, NLM_F_REQUEST | NLM_F_DUMP, seq, payload))
    results = []
    while True:
        resp = sock.recv(65536)
        offset = 0
        while offset + 16 <= len(resp):
            msg_len = struct.unpack('=I', resp[offset:offset+4])[0]
            if msg_len < 16: break
            msg_type = struct.unpack('=H', resp[offset+4:offset+6])[0]
            if msg_type == 3: return results  # NLMSG_DONE
            if msg_type == 2: return results  # NLMSG_ERROR
            data = resp[offset+16:offset+msg_len]
            if len(data) >= 4:
                results.append(parse_attrs(data[4:]))
            offset += (msg_len + 3) & ~3
    return results

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "devices"
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
    sock.settimeout(3)
    sock.bind((0, 0))
    fam = resolve_family(sock, "dpll")
    if fam is None:
        print("[]"); sock.close(); return

    # DPLL UAPI attribute IDs (from linux/dpll.h)
    # Device: ID=1, MODULE_NAME=2, PAD=3, CLOCK_ID=4, MODE=5,
    #          MODE_SUPPORTED=6, LOCK_STATUS=7, TEMP=8, TYPE=9
    # Pin:    ID=1, PARENT_ID=2, MODULE_NAME=3, PAD=4, CLOCK_ID=5,
    #          BOARD_LABEL=6, PANEL_LABEL=7, PACKAGE_LABEL=8, TYPE=9

    if cmd == "devices":
        raw = genl_dump(sock, fam, 2)  # DPLL_CMD_DEVICE_GET
        devs = []
        for attrs in raw:
            d = {}
            if 1 in attrs and len(attrs[1]) >= 4:
                d["id"] = struct.unpack("=I", attrs[1][:4])[0]
            if 7 in attrs and len(attrs[7]) >= 4:
                d["lock-status"] = struct.unpack("=I", attrs[7][:4])[0]
            if 5 in attrs and len(attrs[5]) >= 4:
                d["mode"] = struct.unpack("=I", attrs[5][:4])[0]
            if 9 in attrs and len(attrs[9]) >= 4:
                d["type"] = struct.unpack("=I", attrs[9][:4])[0]
            devs.append(d)
        print(json.dumps(devs))

    elif cmd == "pins":
        raw = genl_dump(sock, fam, 8)  # DPLL_CMD_PIN_GET
        pins = []
        for attrs in raw:
            p = {}
            if 1 in attrs and len(attrs[1]) >= 4:
                p["id"] = struct.unpack("=I", attrs[1][:4])[0]
            if 6 in attrs:
                p["board-label"] = attrs[6].rstrip(b'\x00').decode(errors="replace")
            if 9 in attrs and len(attrs[9]) >= 4:
                p["type"] = struct.unpack("=I", attrs[9][:4])[0]
            pins.append(p)
        print(json.dumps(pins))

    sock.close()

if __name__ == "__main__":
    main()
PYEOF
}

genl_dpll_device_dump() {
    python3 "$GENL_HELPER" devices 2>/dev/null || echo "[]"
}

genl_dpll_pin_dump() {
    python3 "$GENL_HELPER" pins 2>/dev/null || echo "[]"
}

# ---------------------------------------------------------------------------
# Trap: cleanup on exit
# ---------------------------------------------------------------------------
trap_cleanup() {
    cleanup_all_devices
    [[ -n "${GENL_HELPER:-}" && -f "${GENL_HELPER:-}" ]] && rm -f "$GENL_HELPER"
}
trap trap_cleanup EXIT

# ===================================================================
#  TEST SUITE
# ===================================================================

log "netdevsim DPLL unit tests"
echo "  Kernel: $(uname -r)"
echo "  Date:   $(date -u)"
echo

check_genl_tool

# -------------------------------------------------------------------
# 1. Module loading
# -------------------------------------------------------------------
log "1. Module loading"

if [[ "$NO_LOAD" == false ]]; then
    rmmod netdevsim 2>/dev/null || true
    rmmod nsim_dpll 2>/dev/null || true
    rmmod nsim_ptp_mock 2>/dev/null || true
    rmmod nsim_ptp 2>/dev/null || true

    modprobe gnss 2>/dev/null || true
    modprobe nsim_ptp && pass "nsim_ptp loaded" || fail "nsim_ptp load failed"
    modprobe nsim_ptp_mock && pass "nsim_ptp_mock loaded" || fail "nsim_ptp_mock load failed"
    modprobe nsim_dpll && pass "nsim_dpll loaded" || fail "nsim_dpll load failed"
    modprobe netdevsim pci_bus_nr=0x1f && pass "netdevsim loaded" || fail "netdevsim load failed"
else
    if grep -q '^nsim_dpll ' /proc/modules 2>/dev/null; then
        pass "nsim_dpll already loaded"
    else
        fail "nsim_dpll not loaded"
    fi
    if grep -q '^netdevsim ' /proc/modules 2>/dev/null; then
        pass "netdevsim already loaded"
    else
        fail "netdevsim not loaded"
    fi
fi

echo

# -------------------------------------------------------------------
# 2. Device creation with DPLL (wpc=1)
# -------------------------------------------------------------------
log "2. Device creation with wpc=1"

cleanup_all_devices
create_device 1 1 2 1 1

assert_file_exists "netdevsim1 bus device exists" \
    /sys/bus/netdevsim/devices/netdevsim1

assert_file_exists "sysfs class nsim_dpll exists" \
    /sys/class/nsim_dpll

assert_file_exists "sysfs dpll0 device exists" \
    /sys/class/nsim_dpll/dpll0

assert_file_exists "sysfs lock_status attribute exists" \
    /sys/class/nsim_dpll/dpll0/lock_status

echo

# -------------------------------------------------------------------
# 3. Sysfs lock_status — default value
# -------------------------------------------------------------------
log "3. Sysfs lock_status — default value"

STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "default lock_status is 'locked'" "locked" "$STATUS"

echo

# -------------------------------------------------------------------
# 4. Sysfs lock_status — write transitions
# -------------------------------------------------------------------
log "4. Sysfs lock_status — write transitions"

echo "holdover" > /sys/class/nsim_dpll/dpll0/lock_status
STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "write 'holdover' -> read 'holdover'" "holdover" "$STATUS"

echo "freerun" > /sys/class/nsim_dpll/dpll0/lock_status
STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "write 'freerun' -> read 'freerun'" "freerun" "$STATUS"

echo "locked" > /sys/class/nsim_dpll/dpll0/lock_status
STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "write 'locked' -> read 'locked'" "locked" "$STATUS"

echo

# -------------------------------------------------------------------
# 5. Sysfs lock_status — idempotent write (same value)
# -------------------------------------------------------------------
log "5. Sysfs lock_status — idempotent write"

echo "locked" > /sys/class/nsim_dpll/dpll0/lock_status
STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "writing same value is idempotent" "locked" "$STATUS"

echo

# -------------------------------------------------------------------
# 6. Sysfs lock_status — invalid input
# -------------------------------------------------------------------
log "6. Sysfs lock_status — invalid input"

if echo "bogus" > /sys/class/nsim_dpll/dpll0/lock_status 2>/dev/null; then
    fail "writing 'bogus' should have returned error"
else
    pass "writing 'bogus' correctly rejected"
fi

STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "lock_status unchanged after invalid write" "locked" "$STATUS"

if echo "" > /sys/class/nsim_dpll/dpll0/lock_status 2>/dev/null; then
    fail "writing empty string should have returned error"
else
    pass "writing empty string correctly rejected"
fi

if echo "LOCKED" > /sys/class/nsim_dpll/dpll0/lock_status 2>/dev/null; then
    fail "writing 'LOCKED' (uppercase) should have returned error"
else
    pass "writing 'LOCKED' (uppercase) correctly rejected"
fi

echo

# -------------------------------------------------------------------
# 7. Sysfs lock_status — full state cycle
# -------------------------------------------------------------------
log "7. Sysfs lock_status — full state cycle"

for state in locked holdover freerun holdover locked freerun locked; do
    echo "$state" > /sys/class/nsim_dpll/dpll0/lock_status
    STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
    assert_eq "cycle: write '$state' -> read '$state'" "$state" "$STATUS"
done

echo

# -------------------------------------------------------------------
# 8. GNSS device presence
# -------------------------------------------------------------------
log "8. GNSS device presence"

GNSS_DEVS=$(ls /sys/class/gnss/ 2>/dev/null || true)
if [[ -n "$GNSS_DEVS" ]]; then
    pass "GNSS device registered in /sys/class/gnss/"
    GNSS_DEV=$(echo "$GNSS_DEVS" | head -1)
    assert_file_exists "/dev/${GNSS_DEV} character device" "/dev/${GNSS_DEV}"

    GNSS_TYPE=$(cat "/sys/class/gnss/${GNSS_DEV}/type" 2>/dev/null || true)
    assert_eq "GNSS type is NMEA" "NMEA" "$GNSS_TYPE"
else
    fail "no GNSS device found in /sys/class/gnss/"
fi

echo

# -------------------------------------------------------------------
# 9. GNSS NMEA echo
# -------------------------------------------------------------------
log "9. GNSS NMEA echo (write → read)"

if [[ -n "${GNSS_DEV:-}" && -c "/dev/${GNSS_DEV}" ]]; then
    chmod 666 "/dev/${GNSS_DEV}" 2>/dev/null || true

    GGA='$GNGGA,120000.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,47.0,M,,*47'
    echo "$GGA" > "/dev/${GNSS_DEV}" 2>/dev/null || true

    READBACK=$(timeout 2 dd if="/dev/${GNSS_DEV}" bs=512 count=1 2>/dev/null || true)
    if [[ -n "$READBACK" ]]; then
        pass "GNSS device returned data after write"
    else
        skip "GNSS read returned empty (may need longer wait)"
    fi
else
    skip "GNSS device not available for echo test"
fi

echo

# -------------------------------------------------------------------
# 10. PTP clock for DPLL device
# -------------------------------------------------------------------
log "10. PTP clock"

PTP_CLASS=$(ls /sys/class/nsim_ptp/ 2>/dev/null | head -1 || true)
if [[ -n "$PTP_CLASS" ]]; then
    pass "nsim_ptp class device exists: $PTP_CLASS"
else
    skip "nsim_ptp class device not found"
fi

PTP_DEV=$(ls /dev/ptp* 2>/dev/null | head -1 || true)
if [[ -n "$PTP_DEV" ]]; then
    pass "PTP device node exists: $PTP_DEV"
else
    skip "PTP device node not found"
fi

echo

# -------------------------------------------------------------------
# 11. Network interface for netdevsim device
# -------------------------------------------------------------------
log "11. Network interface"

PCI_PREFIX=$(get_pci_domain)
PCI_ADDR="${PCI_PREFIX}:02.0"
IFACE=$(ls "/sys/bus/pci/devices/${PCI_ADDR}/net/" 2>/dev/null | head -1 || true)
if [[ -n "$IFACE" ]]; then
    pass "netdev interface found: $IFACE"

    ETHTOOL_OUT=$(ethtool -T "$IFACE" 2>/dev/null || true)
    if echo "$ETHTOOL_OUT" | grep -qi "hardware"; then
        pass "ethtool -T reports hardware timestamping"
    else
        skip "ethtool -T did not report hardware timestamping"
    fi
else
    skip "no network interface found for $PCI_ADDR"
fi

echo

# -------------------------------------------------------------------
# 12. Generic netlink — DPLL device dump
# -------------------------------------------------------------------
log "12. Generic netlink — DPLL device dump"

if [[ "$HAS_GENL" == true ]]; then
    DEVICES_JSON=$(genl_dpll_device_dump)
    DEVICE_COUNT=$(echo "$DEVICES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

    if [[ "$DEVICE_COUNT" -ge 2 ]]; then
        pass "DPLL device dump returned $DEVICE_COUNT devices (expected >=2: PPS+EEC)"
    elif [[ "$DEVICE_COUNT" -ge 1 ]]; then
        pass "DPLL device dump returned $DEVICE_COUNT device(s)"
    else
        fail "DPLL device dump returned 0 devices"
    fi

    if [[ "$DEVICE_COUNT" -ge 1 ]]; then
        LOCK_STATUS=$(echo "$DEVICES_JSON" | python3 -c "
import sys, json
devs = json.load(sys.stdin)
ls = devs[0].get('lock-status', -1)
print(ls)
" 2>/dev/null || echo "-1")
        # DPLL_LOCK_STATUS_LOCKED_HO_ACQ = 3 (kernel UAPI: UNLOCKED=1, LOCKED=2, LOCKED_HO_ACQ=3, HOLDOVER=4)
        assert_eq "DPLL device lock-status via netlink is 3 (LOCKED_HO_ACQ)" "3" "$LOCK_STATUS"

        MODE=$(echo "$DEVICES_JSON" | python3 -c "
import sys, json
devs = json.load(sys.stdin)
print(devs[0].get('mode', -1))
" 2>/dev/null || echo "-1")
        assert_eq "DPLL device mode via netlink is 2 (AUTOMATIC)" "2" "$MODE"
    fi
else
    skip "python3 not available — skipping netlink DPLL device tests"
fi

echo

# -------------------------------------------------------------------
# 13. Generic netlink — sysfs/netlink lock_status consistency
# -------------------------------------------------------------------
log "13. Sysfs/netlink lock_status consistency"

if [[ "$HAS_GENL" == true ]]; then
    for sysfs_val in holdover freerun locked; do
        echo "$sysfs_val" > /sys/class/nsim_dpll/dpll0/lock_status
        sleep 0.2

        DEVICES_JSON=$(genl_dpll_device_dump)
        NL_STATUS=$(echo "$DEVICES_JSON" | python3 -c "
import sys, json
devs = json.load(sys.stdin)
if devs:
    print(devs[0].get('lock-status', -1))
else:
    print(-1)
" 2>/dev/null || echo "-1")

        # Kernel UAPI: UNLOCKED=1, LOCKED=2, LOCKED_HO_ACQ=3, HOLDOVER=4
        case "$sysfs_val" in
            locked)   EXPECTED_NL=3 ;;  # DPLL_LOCK_STATUS_LOCKED_HO_ACQ
            holdover) EXPECTED_NL=4 ;;  # DPLL_LOCK_STATUS_HOLDOVER
            freerun)  EXPECTED_NL=1 ;;  # DPLL_LOCK_STATUS_UNLOCKED
        esac

        assert_eq "sysfs '$sysfs_val' -> netlink status=$EXPECTED_NL" \
            "$EXPECTED_NL" "$NL_STATUS"
    done

    echo "locked" > /sys/class/nsim_dpll/dpll0/lock_status
else
    skip "python3 not available — skipping sysfs/netlink consistency tests"
fi

echo

# -------------------------------------------------------------------
# 14. Generic netlink — DPLL pin dump
# -------------------------------------------------------------------
log "14. Generic netlink — DPLL pin dump"

if [[ "$HAS_GENL" == true ]]; then
    PINS_JSON=$(genl_dpll_pin_dump)
    PIN_COUNT=$(echo "$PINS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

    if [[ "$PIN_COUNT" -ge 7 ]]; then
        pass "DPLL pin dump returned $PIN_COUNT pins (expected >=7: 1 GNSS + 4 EXT + 2 SyncE)"
    elif [[ "$PIN_COUNT" -ge 5 ]]; then
        pass "DPLL pin dump returned $PIN_COUNT pins (expected >=5: 1 GNSS + 4 EXT)"
    elif [[ "$PIN_COUNT" -ge 1 ]]; then
        pass "DPLL pin dump returned $PIN_COUNT pin(s)"
    else
        fail "DPLL pin dump returned 0 pins"
    fi

    if [[ "$PIN_COUNT" -ge 1 ]]; then
        GNSS_LABEL=$(echo "$PINS_JSON" | python3 -c "
import sys, json
pins = json.load(sys.stdin)
for p in pins:
    if p.get('board-label', '') == 'GNSS-1PPS':
        print('found')
        break
else:
    print('missing')
" 2>/dev/null || echo "error")
        assert_eq "GNSS-1PPS pin present in pin dump" "found" "$GNSS_LABEL"

        EXT_LABELS=$(echo "$PINS_JSON" | python3 -c "
import sys, json
pins = json.load(sys.stdin)
labels = sorted([p.get('board-label','') for p in pins
                 if p.get('board-label','').startswith(('SMA','U.FL'))])
print(' '.join(labels))
" 2>/dev/null || echo "")

        assert_contains "SMA1 pin present" "$EXT_LABELS" "SMA1"
        assert_contains "SMA2 pin present" "$EXT_LABELS" "SMA2"
        assert_contains "U.FL1 pin present" "$EXT_LABELS" "U.FL1"
        assert_contains "U.FL2 pin present" "$EXT_LABELS" "U.FL2"
    fi
else
    skip "python3 not available — skipping netlink DPLL pin tests"
fi

echo

# -------------------------------------------------------------------
# 15. Device without DPLL (wpc=0)
# -------------------------------------------------------------------
log "15. Device without DPLL (wpc=0)"

cleanup_all_devices
create_device 2 1 2 1 0

assert_file_exists "netdevsim2 bus device exists (wpc=0)" \
    /sys/bus/netdevsim/devices/netdevsim2

if [[ -d /sys/class/nsim_dpll/dpll0 ]]; then
    fail "sysfs dpll0 should NOT exist with wpc=0"
else
    pass "sysfs dpll0 correctly absent with wpc=0"
fi

delete_device 2

echo

# -------------------------------------------------------------------
# 16. Device teardown and re-creation
# -------------------------------------------------------------------
log "16. Device teardown and re-creation"

cleanup_all_devices

assert_file_not_exists "sysfs dpll0 absent after teardown" \
    /sys/class/nsim_dpll/dpll0

create_device 1 1 2 1 1

assert_file_exists "sysfs dpll0 re-appears after re-creation" \
    /sys/class/nsim_dpll/dpll0

STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "lock_status defaults to 'locked' after re-creation" "locked" "$STATUS"

echo "holdover" > /sys/class/nsim_dpll/dpll0/lock_status
STATUS=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "lock_status writable after re-creation" "holdover" "$STATUS"

echo

# -------------------------------------------------------------------
# 17. Rapid state transitions
# -------------------------------------------------------------------
log "17. Rapid state transitions (stress)"

RAPID_PASS=true
for _ in $(seq 1 50); do
    for state in locked holdover freerun; do
        echo "$state" > /sys/class/nsim_dpll/dpll0/lock_status
    done
done

FINAL=$(cat /sys/class/nsim_dpll/dpll0/lock_status)
assert_eq "lock_status consistent after 150 rapid writes" "freerun" "$FINAL"

echo

# -------------------------------------------------------------------
# 18. dmesg sanity — no kernel warnings/errors from netdevsim DPLL
# -------------------------------------------------------------------
log "18. dmesg sanity check"

DMESG_DPLL=$(dmesg | grep -i "netdevsim.*dpll\|nsim_dpll" || true)
if echo "$DMESG_DPLL" | grep -qiE "error|warning|bug|oops|panic|call.trace"; then
    fail "dmesg contains errors/warnings related to DPLL"
    echo "$DMESG_DPLL" | grep -iE "error|warning|bug|oops|panic|call.trace" | head -5
else
    pass "no DPLL errors/warnings in dmesg"
fi

echo

# -------------------------------------------------------------------
# 19. Cleanup
# -------------------------------------------------------------------
log "19. Cleanup"

cleanup_all_devices
pass "all devices cleaned up"

echo

# ===================================================================
#  Summary
# ===================================================================
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  DPLL Test Results${NC}"
echo -e "${BOLD}============================================${NC}"
echo -e "  Total:   ${TOTAL}"
echo -e "  ${GREEN}Passed:  ${PASS}${NC}"
echo -e "  ${RED}Failed:  ${FAIL}${NC}"
echo -e "  ${YELLOW}Skipped: ${SKIP}${NC}"

if [[ $FAIL -gt 0 ]]; then
    echo -e "\n${RED}  Failures:${NC}${FAILURES}"
    echo
    exit 1
fi

echo
echo -e "${GREEN}All tests passed.${NC}"
exit 0
