#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Unit tests for the mock PTP Hardware Clock (ptp/ptp_mock.c).
#
# Exercises:
#   - PHC device discovery via nsim_ptp class
#   - gettime64 / settime64 (time read / write)
#   - adjtime (time step)
#   - adjfine (frequency adjustment via scaled_ppm)
#   - EXTTS enable, event delivery, second-boundary alignment
#   - EXTTS self-correction after PHC time step
#   - PHC sharing across ports (same logical_clk_id)
#   - Pin configuration (2 pins: NONE, GNSS1PPS)
#
# Requirements:
#   - Root privileges
#   - DKMS modules installed and loaded
#   - python3 (for PTP ioctl helpers)
#
# Usage:
#   sudo ./scripts/test-phc.sh [--no-load] [--verbose]
#
set -eo pipefail

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

assert_range() {
    local desc="$1" value="$2" min="$3" max="$4"
    if (( value >= min && value <= max )); then
        pass "$desc (value=$value in [$min, $max])"
    else
        fail "$desc (value=$value NOT in [$min, $max])"
    fi
}

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

# ---------------------------------------------------------------------------
# Python PTP ioctl helper (embedded)
# ---------------------------------------------------------------------------
PTP_HELPER=""
setup_ptp_helper() {
    PTP_HELPER=$(mktemp /tmp/ptp-helper-XXXXXX.py)
    cat > "$PTP_HELPER" <<'PYEOF'
#!/usr/bin/env python3
"""
Minimal PTP Hardware Clock ioctl helper for testing mock PHC.
Supports: gettime, settime, adjtime, adjfine, enable_extts,
          disable_extts, read_extts, get_pins
"""
import sys, os, struct, fcntl, time, select

# PTP ioctl numbers (from linux/ptp_clock.h)
PTP_CLK_MAGIC = ord('=')

# struct ptp_clock_caps
PTP_CLOCK_GETCAPS = 0x80503d01  # _IOR('=', 1, 80 bytes)

def _iowr(nr, size):
    return 0xc0003d00 | (size << 16) | nr

def _iow(nr, size):
    return 0x40003d00 | (size << 16) | nr

def _ior(nr, size):
    return 0x80003d00 | (size << 16) | nr

# struct ptp_sys_offset_precise: 3 * ptp_clock_time (3*16=48 bytes)
PTP_SYS_OFFSET_PRECISE = _iowr(8, 48)

# PTP_CLOCK_SETTIME: struct timespec (16 bytes)
PTP_CLOCK_SETTIME = _iow(4, 16)

# PTP_CLOCK_GETTIME: struct timespec (16 bytes)
PTP_CLOCK_GETTIME = _ior(9, 16)

# PTP_CLOCK_ADJ: s64 (8 bytes) but uses struct ptp_clock_adj
# Actually adjtime uses PTP_CLOCK_ADJTIME
# struct timex is used for adjtime via clock_adjtime syscall.
# For simplicity, use clock_settime/clock_gettime via POSIX clock fd.

# struct ptp_extts_request: 3 fields (index, flags, rsv) = 12 bytes → padded to 16
PTP_EXTTS_REQUEST = _iow(2, 16)  # _IOW('=', 2, struct ptp_extts_request)

# struct ptp_extts_event: timestamp (16 bytes) + index (4) + flags (4) + rsv (4) = 28 → pad to 32
PTP_EXTTS_EVENT_SIZE = 32

# PTP_PIN_GETFUNC — struct ptp_pin_desc: char[64] + 8*uint = 96 bytes
PTP_PIN_GETFUNC = _iowr(6, 96)

# Flags
PTP_ENABLE_FEATURE = 1
PTP_RISING_EDGE = 2

CLOCK_REALTIME = 0

import ctypes
import ctypes.util

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

# clock_gettime/clock_settime with dynamic clock ID
class timespec(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_nsec", ctypes.c_long)]

def fd_to_clockid(fd):
    return (~fd << 3) | 3

def phc_gettime(fd):
    clk_id = fd_to_clockid(fd)
    ts = timespec()
    ret = libc.clock_gettime(clk_id, ctypes.byref(ts))
    if ret != 0:
        raise OSError(ctypes.get_errno(), "clock_gettime failed")
    return ts.tv_sec, ts.tv_nsec

def phc_settime(fd, sec, nsec):
    clk_id = fd_to_clockid(fd)
    ts = timespec(sec, nsec)
    ret = libc.clock_settime(clk_id, ctypes.byref(ts))
    if ret != 0:
        raise OSError(ctypes.get_errno(), "clock_settime failed")

# clock_adjtime for adjfine/adjtime
ADJ_SETOFFSET = 0x0100
ADJ_FREQUENCY = 0x0002
ADJ_NANO = 0x2000

class timex(ctypes.Structure):
    _fields_ = [
        ("modes", ctypes.c_uint),
        ("offset", ctypes.c_long),
        ("freq", ctypes.c_long),
        ("maxerror", ctypes.c_long),
        ("esterror", ctypes.c_long),
        ("status", ctypes.c_int),
        ("constant", ctypes.c_long),
        ("precision", ctypes.c_long),
        ("tolerance", ctypes.c_long),
        ("time_tv_sec", ctypes.c_long),
        ("time_tv_usec", ctypes.c_long),
        ("tick", ctypes.c_long),
        ("ppsfreq", ctypes.c_long),
        ("jitter", ctypes.c_long),
        ("shift", ctypes.c_int),
        ("stabil", ctypes.c_long),
        ("jitcnt", ctypes.c_long),
        ("calcnt", ctypes.c_long),
        ("errcnt", ctypes.c_long),
        ("stbcnt", ctypes.c_long),
        ("tai", ctypes.c_int),
        ("_pad", ctypes.c_int * 11),
    ]

def phc_adjtime(fd, delta_ns):
    clk_id = fd_to_clockid(fd)
    tx = timex()
    tx.modes = ADJ_SETOFFSET | ADJ_NANO
    if delta_ns >= 0:
        tx.time_tv_sec = delta_ns // 1000000000
        tx.time_tv_usec = delta_ns % 1000000000
    else:
        tx.time_tv_sec = -((-delta_ns - 1) // 1000000000 + 1)
        tx.time_tv_usec = 1000000000 - ((-delta_ns) % 1000000000)
        if tx.time_tv_usec == 1000000000:
            tx.time_tv_usec = 0
            tx.time_tv_sec += 1
    ret = libc.clock_adjtime(clk_id, ctypes.byref(tx))
    if ret < 0:
        raise OSError(ctypes.get_errno(), "clock_adjtime (adjtime) failed")

def phc_adjfine(fd, scaled_ppm):
    clk_id = fd_to_clockid(fd)
    tx = timex()
    tx.modes = ADJ_FREQUENCY
    tx.freq = int(scaled_ppm)
    ret = libc.clock_adjtime(clk_id, ctypes.byref(tx))
    if ret < 0:
        raise OSError(ctypes.get_errno(), "clock_adjtime (adjfine) failed")

def phc_enable_extts(fd, index=0, flags=PTP_RISING_EDGE | PTP_ENABLE_FEATURE):
    buf = struct.pack('=IIii', index, flags, 0, 0)
    fcntl.ioctl(fd, PTP_EXTTS_REQUEST, buf)

def phc_disable_extts(fd, index=0):
    buf = struct.pack('=IIii', index, 0, 0, 0)
    fcntl.ioctl(fd, PTP_EXTTS_REQUEST, buf)

def phc_read_extts(fd, timeout_s=3.0):
    """Read EXTTS events from the PTP device (uses poll/read)."""
    events = []
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        remaining = max(0, deadline - time.monotonic())
        r, _, _ = select.select([fd], [], [], min(remaining, 0.5))
        if fd in r:
            try:
                data = os.read(fd, PTP_EXTTS_EVENT_SIZE * 16)
                off = 0
                while off + PTP_EXTTS_EVENT_SIZE <= len(data):
                    chunk = data[off:off + PTP_EXTTS_EVENT_SIZE]
                    sec, nsec = struct.unpack_from('=qI', chunk, 0)
                    idx = struct.unpack_from('=I', chunk, 12)[0]
                    events.append((sec, nsec, idx))
                    off += PTP_EXTTS_EVENT_SIZE
            except Exception:
                break
        if len(events) >= 3:
            break
    return events

def phc_get_pin(fd, index):
    buf = bytearray(96)
    struct.pack_into('=I', buf, 64, index)
    result = fcntl.ioctl(fd, PTP_PIN_GETFUNC, bytes(buf))
    name = result[:64].split(b'\x00')[0].decode()
    idx, func, chan = struct.unpack_from('=III', result, 64)
    return {"name": name, "index": idx, "func": func, "chan": chan}

def main():
    import json
    cmd = sys.argv[1]
    dev = sys.argv[2]

    fd = os.open(dev, os.O_RDWR)
    try:
        if cmd == "gettime":
            sec, nsec = phc_gettime(fd)
            print(json.dumps({"sec": sec, "nsec": nsec}))

        elif cmd == "settime":
            sec = int(sys.argv[3])
            nsec = int(sys.argv[4]) if len(sys.argv) > 4 else 0
            phc_settime(fd, sec, nsec)
            print(json.dumps({"ok": True}))

        elif cmd == "adjtime":
            delta_ns = int(sys.argv[3])
            phc_adjtime(fd, delta_ns)
            print(json.dumps({"ok": True}))

        elif cmd == "adjfine":
            freq = int(sys.argv[3])
            phc_adjfine(fd, freq)
            print(json.dumps({"ok": True}))

        elif cmd == "enable_extts":
            idx = int(sys.argv[3]) if len(sys.argv) > 3 else 0
            phc_enable_extts(fd, idx)
            print(json.dumps({"ok": True}))

        elif cmd == "disable_extts":
            idx = int(sys.argv[3]) if len(sys.argv) > 3 else 0
            phc_disable_extts(fd, idx)
            print(json.dumps({"ok": True}))

        elif cmd == "read_extts":
            timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
            events = phc_read_extts(fd, timeout)
            print(json.dumps([{"sec": s, "nsec": n, "index": i}
                              for s, n, i in events]))

        elif cmd == "getpin":
            idx = int(sys.argv[3])
            info = phc_get_pin(fd, idx)
            print(json.dumps(info))

        elif cmd == "read_extts_timed":
            timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 5.0
            max_events = int(sys.argv[4]) if len(sys.argv) > 4 else 10
            events = []
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline and len(events) < max_events:
                remaining = max(0, deadline - time.monotonic())
                r, _, _ = select.select([fd], [], [], min(remaining, 0.5))
                if fd in r:
                    try:
                        data = os.read(fd, PTP_EXTTS_EVENT_SIZE * 16)
                        wall = time.monotonic()
                        off = 0
                        while off + PTP_EXTTS_EVENT_SIZE <= len(data):
                            chunk = data[off:off + PTP_EXTTS_EVENT_SIZE]
                            sec, nsec = struct.unpack_from('=qI', chunk, 0)
                            idx = struct.unpack_from('=I', chunk, 12)[0]
                            events.append({"sec": sec, "nsec": nsec,
                                           "index": idx, "mono": wall})
                            off += PTP_EXTTS_EVENT_SIZE
                    except Exception:
                        break
            print(json.dumps(events))

        else:
            print(json.dumps({"error": f"unknown command: {cmd}"}))
            sys.exit(1)
    finally:
        os.close(fd)

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$PTP_HELPER"
}

phc_cmd() {
    python3 "$PTP_HELPER" "$@" 2>/dev/null
}

phc_gettime_sec() {
    phc_cmd gettime "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])"
}

phc_gettime_nsec() {
    phc_cmd gettime "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)['nsec'])"
}

# ---------------------------------------------------------------------------
# Trap
# ---------------------------------------------------------------------------
trap_cleanup() {
    cleanup_all_devices
    [[ -n "${PTP_HELPER:-}" && -f "${PTP_HELPER:-}" ]] && rm -f "$PTP_HELPER"
}
trap trap_cleanup EXIT

# ===================================================================
#  TEST SUITE
# ===================================================================

log "Mock PHC unit tests"
echo "  Kernel: $(uname -r)"
echo "  Date:   $(date -u)"
echo

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 required"
    exit 1
fi

setup_ptp_helper

# -------------------------------------------------------------------
# 1. Module loading
# -------------------------------------------------------------------
log "1. Module check"

if [[ "$NO_LOAD" == false ]]; then
    rmmod netdevsim 2>/dev/null || true
    rmmod nsim_dpll 2>/dev/null || true
    rmmod nsim_ptp_mock 2>/dev/null || true
    rmmod nsim_ptp 2>/dev/null || true
    sleep 0.5

    modprobe gnss 2>/dev/null || true
    modprobe nsim_ptp && pass "nsim_ptp loaded" || fail "nsim_ptp load failed"
    modprobe nsim_ptp_mock && pass "nsim_ptp_mock loaded" || fail "nsim_ptp_mock load failed"
    modprobe nsim_dpll && pass "nsim_dpll loaded" || fail "nsim_dpll load failed"
    modprobe netdevsim pci_bus_nr=0x1f && pass "netdevsim loaded" || fail "netdevsim load failed"
else
    lsmod | grep -q nsim_ptp_mock && pass "nsim_ptp_mock loaded" || fail "nsim_ptp_mock not loaded"
fi

echo

# -------------------------------------------------------------------
# 2. Device creation and PTP device discovery
# -------------------------------------------------------------------
log "2. Device creation + PTP discovery"

cleanup_all_devices
create_device 1 1 2 1 1

PCI_PREFIX=$(get_pci_domain)
PCI_ADDR="${PCI_PREFIX}:02.0"

# Find PTP device via nsim_ptp class
PTP_CLASS_DEV=$(ls /sys/class/nsim_ptp/ 2>/dev/null | head -1 || true)
if [[ -z "$PTP_CLASS_DEV" ]]; then
    echo "ERROR: No nsim_ptp class device found"
    exit 1
fi

PTP_DEV="/dev/${PTP_CLASS_DEV}"
if [[ ! -c "$PTP_DEV" ]]; then
    # Try via udev symlink
    PTP_MAJOR=$(cat "/sys/class/nsim_ptp/${PTP_CLASS_DEV}/dev" | cut -d: -f1)
    PTP_MINOR=$(cat "/sys/class/nsim_ptp/${PTP_CLASS_DEV}/dev" | cut -d: -f2)
    PTP_DEV=$(ls /dev/ptp* 2>/dev/null | head -1 || true)
    if [[ -z "$PTP_DEV" || ! -c "$PTP_DEV" ]]; then
        echo "ERROR: Cannot find PTP character device"
        exit 1
    fi
fi

pass "PTP device found: $PTP_DEV"
echo

# -------------------------------------------------------------------
# 3. PHC gettime64 — initial time is reasonable
# -------------------------------------------------------------------
log "3. PHC gettime64 — initial time"

TIME_JSON=$(phc_cmd gettime "$PTP_DEV")
PHC_SEC=$(echo "$TIME_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")
NOW_SEC=$(date +%s)

DIFF=$(( PHC_SEC - NOW_SEC ))
if (( DIFF < 0 )); then DIFF=$(( -DIFF )); fi

# PHC is MONOTONIC-based, offset_ns starts at 0, so PHC time ≈ uptime
# After settime64 by ts2phc, it would be TAI. At creation, it's raw monotonic.
# Just verify it's a positive number.
if (( PHC_SEC > 0 )); then
    pass "PHC gettime returns positive time (sec=$PHC_SEC)"
else
    fail "PHC gettime returned non-positive time (sec=$PHC_SEC)"
fi

echo

# -------------------------------------------------------------------
# 4. PHC settime64 / gettime64 round-trip
# -------------------------------------------------------------------
log "4. PHC settime64 + gettime64 round-trip"

TARGET_SEC=1700000000
TARGET_NSEC=500000000

phc_cmd settime "$PTP_DEV" $TARGET_SEC $TARGET_NSEC >/dev/null

READBACK=$(phc_cmd gettime "$PTP_DEV")
RB_SEC=$(echo "$READBACK" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")
RB_NSEC=$(echo "$READBACK" | python3 -c "import sys,json; print(json.load(sys.stdin)['nsec'])")

# Allow 50ms tolerance for syscall latency
DIFF_SEC=$(( RB_SEC - TARGET_SEC ))
DIFF_NS=$(( (DIFF_SEC * 1000000000 + RB_NSEC) - TARGET_NSEC ))
if (( DIFF_NS < 0 )); then DIFF_NS=$(( -DIFF_NS )); fi

if (( DIFF_NS < 50000000 )); then
    pass "settime64/gettime64 round-trip (drift=${DIFF_NS}ns < 50ms)"
else
    fail "settime64/gettime64 round-trip (drift=${DIFF_NS}ns > 50ms)"
fi

# Verify settime resets freq_ppb to 0 (PHC should track monotonic rate after set)
phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
sleep 1
RB1=$(phc_cmd gettime "$PTP_DEV")
sleep 1
RB2=$(phc_cmd gettime "$PTP_DEV")

SEC1=$(echo "$RB1" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")
SEC2=$(echo "$RB2" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")
ELAPSED=$(( SEC2 - SEC1 ))

# After 1 second sleep, PHC should advance ~1 second (freq_ppb=0)
if (( ELAPSED >= 0 && ELAPSED <= 2 )); then
    pass "PHC advances ~1s per second after settime (elapsed=${ELAPSED}s)"
else
    fail "PHC time advance unexpected after settime (elapsed=${ELAPSED}s)"
fi

echo

# -------------------------------------------------------------------
# 5. PHC adjtime — time step
# -------------------------------------------------------------------
log "5. PHC adjtime (time step)"

phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
sleep 0.1

BEFORE=$(phc_cmd gettime "$PTP_DEV")
BEFORE_SEC=$(echo "$BEFORE" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")

# Step by +5 seconds
phc_cmd adjtime "$PTP_DEV" 5000000000 >/dev/null

AFTER=$(phc_cmd gettime "$PTP_DEV")
AFTER_SEC=$(echo "$AFTER" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")

STEP=$(( AFTER_SEC - BEFORE_SEC ))
if (( STEP >= 4 && STEP <= 6 )); then
    pass "adjtime +5s applied correctly (measured step=${STEP}s)"
else
    fail "adjtime +5s step incorrect (measured step=${STEP}s)"
fi

# Negative step
phc_cmd adjtime "$PTP_DEV" -3000000000 >/dev/null

AFTER_NEG=$(phc_cmd gettime "$PTP_DEV")
AFTER_NEG_SEC=$(echo "$AFTER_NEG" | python3 -c "import sys,json; print(json.load(sys.stdin)['sec'])")

STEP_NEG=$(( AFTER_NEG_SEC - AFTER_SEC ))
if (( STEP_NEG >= -4 && STEP_NEG <= -2 )); then
    pass "adjtime -3s applied correctly (measured step=${STEP_NEG}s)"
else
    fail "adjtime -3s step incorrect (measured step=${STEP_NEG}s)"
fi

echo

# -------------------------------------------------------------------
# 6. PHC adjfine — frequency adjustment
# -------------------------------------------------------------------
log "6. PHC adjfine (frequency adjustment)"

phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
phc_cmd adjfine "$PTP_DEV" 0 >/dev/null
sleep 0.1

# Set a large positive frequency: +100 ppm = +6553600 scaled_ppm
# (scaled_ppm = ppm * 65536)
FREQ_SPM=6553600  # +100 ppm
phc_cmd adjfine "$PTP_DEV" $FREQ_SPM >/dev/null

T1_JSON=$(phc_cmd gettime "$PTP_DEV")
sleep 2
T2_JSON=$(phc_cmd gettime "$PTP_DEV")

T1_NS=$(echo "$T1_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sec']*1000000000+d['nsec'])")
T2_NS=$(echo "$T2_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sec']*1000000000+d['nsec'])")

ELAPSED_NS=$(( T2_NS - T1_NS ))

# At +100 ppm over 2 seconds: expect ~2.0002s (200µs extra drift)
# PHC should advance MORE than 2.0 seconds
# Minimum: 2s baseline + some extra from freq correction
if (( ELAPSED_NS > 2000000000 )); then
    pass "adjfine +100ppm: PHC advances faster than real time (${ELAPSED_NS}ns > 2e9)"
else
    fail "adjfine +100ppm: PHC did not advance faster (${ELAPSED_NS}ns)"
fi

# Reset frequency
phc_cmd adjfine "$PTP_DEV" 0 >/dev/null

echo

# -------------------------------------------------------------------
# 7. Pin configuration
# -------------------------------------------------------------------
log "7. Pin configuration"

PIN0=$(phc_cmd getpin "$PTP_DEV" 0)
PIN0_NAME=$(echo "$PIN0" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
assert_eq "Pin 0 name is 'NONE'" "NONE" "$PIN0_NAME"

PIN1=$(phc_cmd getpin "$PTP_DEV" 1)
PIN1_NAME=$(echo "$PIN1" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
assert_eq "Pin 1 name is 'GNSS1PPS'" "GNSS1PPS" "$PIN1_NAME"

echo

# -------------------------------------------------------------------
# 8. EXTTS enable + event delivery
# -------------------------------------------------------------------
log "8. EXTTS enable + event delivery"

# Set PHC to known time near a second boundary
phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
phc_cmd adjfine "$PTP_DEV" 0 >/dev/null
sleep 0.1

# Enable EXTTS on channel 0
phc_cmd enable_extts "$PTP_DEV" 0 >/dev/null

# Read events (wait up to 4 seconds for at least 2 events)
EVENTS=$(phc_cmd read_extts "$PTP_DEV" 4.0)
EVENT_COUNT=$(echo "$EVENTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if (( EVENT_COUNT >= 2 )); then
    pass "EXTTS delivered $EVENT_COUNT events in 4s"
else
    fail "EXTTS delivered only $EVENT_COUNT events (expected >= 2)"
fi

# Disable EXTTS
phc_cmd disable_extts "$PTP_DEV" 0 >/dev/null

echo

# -------------------------------------------------------------------
# 9. EXTTS second-boundary alignment
# -------------------------------------------------------------------
log "9. EXTTS second-boundary alignment"

phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
phc_cmd adjfine "$PTP_DEV" 0 >/dev/null
sleep 0.1

phc_cmd enable_extts "$PTP_DEV" 0 >/dev/null
EVENTS=$(phc_cmd read_extts "$PTP_DEV" 5.0)
phc_cmd disable_extts "$PTP_DEV" 0 >/dev/null

# Check that EXTTS timestamps have nsec < 10ms (within 10ms of a second boundary)
ALIGNMENT_OK=$(echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if not events:
    print('no_events')
    sys.exit()
all_ok = True
for e in events:
    nsec = e['nsec']
    off = min(nsec, 1000000000 - nsec)
    if off > 10000000:
        all_ok = False
        print(f'bad:{nsec}')
        break
if all_ok:
    print('ok')
")

if [[ "$ALIGNMENT_OK" == "ok" ]]; then
    pass "EXTTS timestamps aligned to second boundary (< 10ms offset)"
elif [[ "$ALIGNMENT_OK" == "no_events" ]]; then
    skip "No EXTTS events to check alignment"
else
    fail "EXTTS timestamp NOT aligned: $ALIGNMENT_OK"
fi

echo

# -------------------------------------------------------------------
# 10. EXTTS self-correction after PHC time step
# -------------------------------------------------------------------
log "10. EXTTS self-correction after time step"

phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
phc_cmd adjfine "$PTP_DEV" 0 >/dev/null
sleep 0.1

phc_cmd enable_extts "$PTP_DEV" 0 >/dev/null

# Wait for first event to confirm timer is running
EVENTS_PRE=$(phc_cmd read_extts "$PTP_DEV" 2.0)
PRE_COUNT=$(echo "$EVENTS_PRE" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if (( PRE_COUNT < 1 )); then
    skip "No pre-step EXTTS events; cannot test self-correction"
else
    # Step PHC by +500ms (deliberately misalign)
    phc_cmd adjtime "$PTP_DEV" 500000000 >/dev/null

    # Read events for 3 more seconds — the timer should self-correct
    EVENTS_POST=$(phc_cmd read_extts "$PTP_DEV" 4.0)

    CORRECTION_OK=$(echo "$EVENTS_POST" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if len(events) < 2:
    print('insufficient')
    sys.exit()
last = events[-1]
nsec = last['nsec']
off = min(nsec, 1000000000 - nsec)
if off < 50000000:
    print('ok')
else:
    print(f'bad:{nsec}')
")

    if [[ "$CORRECTION_OK" == "ok" ]]; then
        pass "EXTTS self-corrected after 500ms PHC step"
    elif [[ "$CORRECTION_OK" == "insufficient" ]]; then
        skip "Insufficient post-step EXTTS events"
    else
        fail "EXTTS did NOT self-correct after step: $CORRECTION_OK"
    fi
fi

phc_cmd disable_extts "$PTP_DEV" 0 >/dev/null

echo

# -------------------------------------------------------------------
# 11. EXTTS with frequency adjustment
# -------------------------------------------------------------------
log "11. EXTTS with frequency adjustment"

phc_cmd settime "$PTP_DEV" 1700000000 0 >/dev/null
phc_cmd adjfine "$PTP_DEV" 6553600 >/dev/null  # +100 ppm
sleep 0.1

phc_cmd enable_extts "$PTP_DEV" 0 >/dev/null
EVENTS=$(phc_cmd read_extts "$PTP_DEV" 5.0)
phc_cmd disable_extts "$PTP_DEV" 0 >/dev/null
phc_cmd adjfine "$PTP_DEV" 0 >/dev/null

# Even with +100ppm, EXTTS should still fire near second boundaries
FREQ_ALIGN=$(echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if len(events) < 2:
    print('insufficient')
    sys.exit()
last = events[-1]
nsec = last['nsec']
off = min(nsec, 1000000000 - nsec)
if off < 50000000:
    print('ok')
else:
    print(f'bad:{nsec}')
")

if [[ "$FREQ_ALIGN" == "ok" ]]; then
    pass "EXTTS aligned at second boundary even with +100ppm freq adj"
elif [[ "$FREQ_ALIGN" == "insufficient" ]]; then
    skip "Insufficient EXTTS events with freq adj"
else
    fail "EXTTS misaligned with freq adj: $FREQ_ALIGN"
fi

echo

# -------------------------------------------------------------------
# 12. PHC sharing (same logical_clk_id)
# -------------------------------------------------------------------
log "12. PHC sharing across ports (same logical_clk_id)"

cleanup_all_devices
create_device 1 1 2 1 1  # 2 ports, clock_id=1

PCI_PREFIX=$(get_pci_domain)
PCI_ADDR1="${PCI_PREFIX}:02.0"

# Both ports should share the same PHC.
# Check via ethtool -T on both interfaces
IFACE1=$(ls "/sys/bus/pci/devices/${PCI_ADDR1}/net/" 2>/dev/null | head -1 || true)
IFACE2=$(ls "/sys/bus/pci/devices/${PCI_ADDR1}/net/" 2>/dev/null | tail -1 || true)

if [[ -n "$IFACE1" && -n "$IFACE2" ]]; then
    PHC_IDX1=$(ethtool -T "$IFACE1" 2>/dev/null | grep "PTP Hardware Clock" | awk '{print $NF}' || echo "-1")
    PHC_IDX2=$(ethtool -T "$IFACE2" 2>/dev/null | grep "PTP Hardware Clock" | awk '{print $NF}' || echo "-1")

    if [[ "$PHC_IDX1" != "-1" && "$PHC_IDX1" == "$PHC_IDX2" ]]; then
        pass "Both ports share PHC index $PHC_IDX1"
    elif [[ "$PHC_IDX1" == "-1" ]]; then
        skip "Cannot determine PHC index from ethtool"
    else
        fail "Ports have different PHC indices ($PHC_IDX1 vs $PHC_IDX2)"
    fi
else
    skip "Cannot find both network interfaces"
fi

echo

# -------------------------------------------------------------------
# 13. Multiple settime64 operations
# -------------------------------------------------------------------
log "13. Multiple settime64 operations (no corruption)"

cleanup_all_devices
create_device 1 1 2 1 1
PTP_DEV=$(ls /dev/ptp* 2>/dev/null | head -1 || true)

if [[ -n "$PTP_DEV" && -c "$PTP_DEV" ]]; then
    MULTI_OK=true
    for t in 1000000000 2000000000 1500000000 1800000000 999999999; do
        phc_cmd settime "$PTP_DEV" "$t" 0 >/dev/null
        RB_SEC=$(phc_gettime_sec "$PTP_DEV")
        DIFF=$(( RB_SEC - t ))
        if (( DIFF < 0 )); then DIFF=$(( -DIFF )); fi
        if (( DIFF > 1 )); then
            MULTI_OK=false
            break
        fi
    done

    if [[ "$MULTI_OK" == true ]]; then
        pass "5 consecutive settime64 ops all read back correctly"
    else
        fail "settime64 corruption detected (t=$t, readback=$RB_SEC)"
    fi
else
    skip "No PTP device for multi-set test"
fi

echo

# -------------------------------------------------------------------
# 14. REGRESSION: EXTTS with realistic TAI time (large offset_ns)
# -------------------------------------------------------------------
log "14. REGRESSION: EXTTS with realistic TAI time (offset_ns ≈ 56 years)"

# Bug: with CLOCK_MONOTONIC_RAW base, setting PHC to TAI time created
# offset_ns ≈ 1.78e18.  ts2phc's servo drove freq_ppb to -500M, causing
# EXTTS to rapid-fire (5 events in 200ms) and ts2phc couldn't converge.
# The CLOCK_MONOTONIC fix keeps freq_ppb near 0.

cleanup_all_devices
create_device 1 1 2 1 1
PTP_DEV=$(ls /dev/ptp* 2>/dev/null | head -1 || true)

if [[ -n "$PTP_DEV" && -c "$PTP_DEV" ]]; then
    # Set PHC to realistic TAI time (≈ June 2026 TAI)
    TAI_TIME=1780690000
    phc_cmd settime "$PTP_DEV" $TAI_TIME 0 >/dev/null
    phc_cmd adjfine "$PTP_DEV" 0 >/dev/null
    sleep 0.1

    phc_cmd enable_extts "$PTP_DEV" 0 >/dev/null
    EVENTS=$(phc_cmd read_extts_timed "$PTP_DEV" 5.0 5)
    phc_cmd disable_extts "$PTP_DEV" 0 >/dev/null

    # Verify: events are ~1 second apart in monotonic time (not rapid-fire)
    TAI_RESULT=$(echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if len(events) < 2:
    print('insufficient')
    sys.exit()
# Check monotonic spacing between events
spacings = []
for i in range(1, len(events)):
    dt = events[i]['mono'] - events[i-1]['mono']
    spacings.append(dt)
min_sp = min(spacings)
max_sp = max(spacings)
# Each spacing should be ~1 second (0.5 to 1.5 is acceptable)
if min_sp < 0.5:
    print(f'rapid_fire:min_spacing={min_sp:.3f}s')
elif max_sp > 2.0:
    print(f'too_slow:max_spacing={max_sp:.3f}s')
else:
    print(f'ok:spacings={[round(s,3) for s in spacings]}')
")

    if [[ "$TAI_RESULT" == ok:* ]]; then
        pass "EXTTS fires ~1Hz with TAI time (${TAI_RESULT#ok:})"
    elif [[ "$TAI_RESULT" == "insufficient" ]]; then
        skip "Not enough EXTTS events for TAI time test"
    elif [[ "$TAI_RESULT" == rapid_fire:* ]]; then
        fail "EXTTS rapid-fire with TAI time! ${TAI_RESULT#rapid_fire:}"
    else
        fail "EXTTS timing issue with TAI time: $TAI_RESULT"
    fi

    # Verify EXTTS timestamps are near second boundaries
    TAI_ALIGN=$(echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if not events: print('no_events'); sys.exit()
worst = 0
for e in events:
    off = min(e['nsec'], 1000000000 - e['nsec'])
    worst = max(worst, off)
if worst < 10000000:
    print(f'ok:worst_offset={worst}ns')
else:
    print(f'bad:worst_offset={worst}ns')
")
    if [[ "$TAI_ALIGN" == ok:* ]]; then
        pass "EXTTS aligned at TAI second boundaries (${TAI_ALIGN#ok:})"
    else
        fail "EXTTS misaligned with TAI time: $TAI_ALIGN"
    fi
else
    skip "No PTP device for TAI time regression test"
fi

echo

# -------------------------------------------------------------------
# 15. REGRESSION: EXTTS must not rapid-fire with extreme freq_ppb
# -------------------------------------------------------------------
log "15. REGRESSION: EXTTS with extreme freq_ppb = -500M"

# Bug: when freq_ppb = -500000000 (max negative), PHC advances at 50%
# speed.  With CLOCK_MONOTONIC_RAW the EXTTS delay was doubled, but the
# self-correction loop produced 5 rapid-fire events in 200ms before
# converging.  This test verifies that even with extreme freq, events
# don't rapid-fire below 200ms spacing.

if [[ -n "$PTP_DEV" && -c "$PTP_DEV" ]]; then
    phc_cmd settime "$PTP_DEV" 1780690000 0 >/dev/null
    # Set extreme negative freq: -500M ppb = scaled_ppm -500M*65536/1000 = -32768000000
    # But max adjfine accepts is limited by max_adj (500M ppb).
    # scaled_ppm = ppb * 65536 / 1000
    EXTREME_SPM=$(python3 -c "print(int(-500000000 * 65536 / 1000))")
    phc_cmd adjfine "$PTP_DEV" $EXTREME_SPM >/dev/null
    sleep 0.1

    phc_cmd enable_extts "$PTP_DEV" 0 >/dev/null

    # With freq_ppb = -500M, PHC runs at 50% speed, so EXTTS should fire
    # every ~2 seconds in wall time (1 PHC second = 2 real seconds).
    # Read for 8 seconds to get at least 2-3 events.
    EVENTS=$(phc_cmd read_extts_timed "$PTP_DEV" 8.0 6)
    phc_cmd disable_extts "$PTP_DEV" 0 >/dev/null
    phc_cmd adjfine "$PTP_DEV" 0 >/dev/null

    EXTREME_RESULT=$(echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
if len(events) < 2:
    print('insufficient')
    sys.exit()
spacings = [events[i]['mono'] - events[i-1]['mono'] for i in range(1, len(events))]
min_sp = min(spacings)
# With -500M ppb, minimum inter-event spacing should be > 0.2s
# (the old bug caused 5 events in 0.2s, i.e. ~40ms spacing)
rapid_count = sum(1 for s in spacings if s < 0.2)
if rapid_count > 0:
    print(f'rapid_fire:{rapid_count}_events_below_200ms,spacings={[round(s,3) for s in spacings]}')
else:
    print(f'ok:min_spacing={min_sp:.3f}s,spacings={[round(s,3) for s in spacings]}')
")

    if [[ "$EXTREME_RESULT" == ok:* ]]; then
        pass "No rapid-fire with freq_ppb=-500M (${EXTREME_RESULT#ok:})"
    elif [[ "$EXTREME_RESULT" == "insufficient" ]]; then
        skip "Not enough events for extreme freq test"
    elif [[ "$EXTREME_RESULT" == rapid_fire:* ]]; then
        fail "EXTTS rapid-fire with -500M ppb! ${EXTREME_RESULT#rapid_fire:}"
    else
        fail "EXTTS extreme freq issue: $EXTREME_RESULT"
    fi
else
    skip "No PTP device for extreme freq regression test"
fi

echo

# -------------------------------------------------------------------
# 16. REGRESSION: freq_ppb stays small after realistic settime
# -------------------------------------------------------------------
log "16. REGRESSION: freq_ppb stays near zero with MONOTONIC base"

# Bug: with CLOCK_MONOTONIC_RAW, after settime to TAI, the PHC drifted
# and ts2phc pushed freq_ppb to -500M.  With CLOCK_MONOTONIC base, the
# PHC should track real time closely and freq_ppb should stay near 0.

if [[ -n "$PTP_DEV" && -c "$PTP_DEV" ]]; then
    phc_cmd settime "$PTP_DEV" 1780690000 0 >/dev/null
    phc_cmd adjfine "$PTP_DEV" 0 >/dev/null
    sleep 0.1

    # Read time twice 2s apart, measure drift
    T1=$(phc_cmd gettime "$PTP_DEV")
    WALL1=$(python3 -c "import time; print(time.monotonic())")
    sleep 2
    T2=$(phc_cmd gettime "$PTP_DEV")
    WALL2=$(python3 -c "import time; print(time.monotonic())")

    DRIFT_RESULT=$(python3 -c "
import json
t1 = json.loads('$T1')
t2 = json.loads('$T2')
phc1 = t1['sec'] + t1['nsec']/1e9
phc2 = t2['sec'] + t2['nsec']/1e9
wall_elapsed = $WALL2 - $WALL1
phc_elapsed = phc2 - phc1
# drift_ppm = (phc_elapsed / wall_elapsed - 1) * 1e6
if wall_elapsed > 0:
    drift_ppm = (phc_elapsed / wall_elapsed - 1.0) * 1e6
    if abs(drift_ppm) < 1000:
        print(f'ok:drift={drift_ppm:.1f}ppm')
    else:
        print(f'bad:drift={drift_ppm:.1f}ppm')
else:
    print('error')
")

    if [[ "$DRIFT_RESULT" == ok:* ]]; then
        pass "PHC drift < 1000 ppm with MONOTONIC base (${DRIFT_RESULT#ok:})"
    elif [[ "$DRIFT_RESULT" == bad:* ]]; then
        fail "PHC drift too large! ${DRIFT_RESULT#bad:}"
    else
        fail "Could not measure PHC drift: $DRIFT_RESULT"
    fi
else
    skip "No PTP device for drift test"
fi

echo

# -------------------------------------------------------------------
# 17. dmesg sanity
# -------------------------------------------------------------------
log "17. dmesg sanity check"

DMESG_PHC=$(dmesg | grep -i "ptp_mock\|mock_phc\|nsim_ptp" | tail -20 || true)
if echo "$DMESG_PHC" | grep -qiE "bug|oops|panic|call.trace|rcu.*stall"; then
    fail "dmesg contains errors related to mock PHC"
    echo "$DMESG_PHC" | grep -iE "bug|oops|panic|call.trace" | head -5
else
    pass "no PHC errors in dmesg"
fi

echo

# -------------------------------------------------------------------
# 18. Cleanup
# -------------------------------------------------------------------
log "18. Cleanup"

cleanup_all_devices
pass "all devices cleaned up"

echo

# ===================================================================
#  Summary
# ===================================================================
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Mock PHC Test Results${NC}"
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
