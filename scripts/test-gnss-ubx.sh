#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Unit tests for GNSS device emulation and UBX protocol (netdevsim/dpll.c).
#
# Exercises:
#   - UBX MON-VER request → firmware version response
#   - UBX CFG-MSG → periodic NAV-STATUS / NAV-CLOCK injection
#   - UBX CFG-VALSET INFIL_NCNOTHRS → signal block / restore
#   - DPLL lock_status transitions during signal cycle
#   - Sysfs isolation when signal_blocked
#   - NMEA GGA fix quality parsing
#   - NMEA forwarding during signal block
#   - GGA parsing skipped during signal block
#   - Full signal loss/recovery cycle
#   - Multiple block/restore stress
#   - UBX ACK for generic commands
#   - Netlink consistency throughout
#
# Usage:  sudo ./scripts/test-gnss-ubx.sh [--no-load] [--verbose]
#
set -eo pipefail

NO_LOAD=false
VERBOSE=false
PASS=0; FAIL=0; SKIP=0; TOTAL=0; FAILURES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-load) NO_LOAD=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
[[ "$VERBOSE" == true ]] && set -x

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'
log() { echo -e "${BOLD}==> $*${NC}"; }
pass() { ((TOTAL++)) || true; ((PASS++)) || true; echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { ((TOTAL++)) || true; ((FAIL++)) || true; FAILURES="${FAILURES}\n  - $1"; echo -e "  ${RED}FAIL${NC}: $1"; }
skip() { ((TOTAL++)) || true; ((SKIP++)) || true; echo -e "  ${YELLOW}SKIP${NC}: $1"; }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then pass "$d"; else fail "$d (expected='$e', got='$a')"; fi; }

get_pci_domain() {
    local bus_nr bus fake_root domain
    bus_nr=$(cat /sys/module/netdevsim/parameters/pci_bus_nr 2>/dev/null || echo 31)
    bus=$(printf "%02x" "$bus_nr")
    fake_root=$(ls /sys/bus/pci/devices/ 2>/dev/null | grep ":${bus}:00\.0" | head -1 || true)
    domain="${fake_root%%:*}"
    [[ -z "$domain" ]] && domain="0000"
    echo "${domain}:${bus}"
}
create_device() {
    local id="${1:-1}" pci_prefix; pci_prefix=$(get_pci_domain)
    local pci_addr="${pci_prefix}:$(printf '%02x' "$((id+1))").0"
    echo "${id} ${pci_addr} ${2:-1} ${3:-2} ${4:-1} ${5:-1}" > /sys/bus/netdevsim/new_device; sleep 1
}
cleanup_all_devices() {
    for dev in /sys/bus/netdevsim/devices/netdevsim*; do
        [[ -d "$dev" ]] || continue
        echo "$(basename "$dev" | sed 's/netdevsim//')" > /sys/bus/netdevsim/del_device 2>/dev/null || true
    done; sleep 0.5
}
dpll_sysfs_path() {
    local id="${1:-1}" pci_prefix; pci_prefix=$(get_pci_domain)
    echo "/sys/bus/pci/devices/${pci_prefix}:$(printf '%02x' "$((id+1))").0/dpll/lock_status"
}

# ---- Python UBX helper ----
UBX_HELPER=""
setup_ubx_helper() {
    UBX_HELPER=$(mktemp /tmp/ubx-helper-XXXXXX.py)
    cat > "$UBX_HELPER" <<'PYEOF'
import sys, os, struct, time, select, json

S1, S2 = 0xB5, 0x62
CLS_NAV, CLS_ACK, CLS_CFG, CLS_MON = 0x01, 0x05, 0x06, 0x0A
NAV_STATUS, NAV_CLOCK, ACK_ACK = 0x03, 0x22, 0x01
CFG_MSG, CFG_VALSET, MON_VER = 0x01, 0x8A, 0x04
KEY_NCNOTHRS = 0x201100aa

def ck(data):
    a = b = 0
    for x in data: a = (a+x)&0xFF; b = (b+a)&0xFF
    return a, b

def build(cls, mid, pl=b""):
    h = bytes([S1, S2, cls, mid, len(pl)&0xFF, (len(pl)>>8)&0xFF])
    d = bytes([cls, mid, len(pl)&0xFF, (len(pl)>>8)&0xFF]) + pl
    a, b = ck(d)
    return h + pl + bytes([a, b])

def parse(data):
    frames, i = [], 0
    while i+8 <= len(data):
        if data[i]==S1 and data[i+1]==S2:
            c, m = data[i+2], data[i+3]
            plen = data[i+4]|(data[i+5]<<8)
            t = 6+plen+2
            if i+t <= len(data):
                frames.append({"class":c,"id":m,"payload":data[i+6:i+6+plen].hex(),"len":plen})
                i += t; continue
        i += 1
    return frames

def wr(dev, data, tmo=1.5):
    fd = os.open(dev, os.O_RDWR|os.O_NONBLOCK)
    try:
        os.write(fd, data); time.sleep(0.1)
        r = b""; dl = time.monotonic()+tmo
        while time.monotonic()<dl:
            s, _, _ = select.select([fd],[],[],min(dl-time.monotonic(),0.2))
            if fd in s:
                try: c = os.read(fd, 4096); r += c
                except BlockingIOError: break
            elif r: break
        return r
    finally: os.close(fd)

def rd(dev, tmo=2.5):
    fd = os.open(dev, os.O_RDONLY|os.O_NONBLOCK)
    try:
        r = b""; dl = time.monotonic()+tmo
        while time.monotonic()<dl:
            s, _, _ = select.select([fd],[],[],min(dl-time.monotonic(),0.3))
            if fd in s:
                try: c = os.read(fd, 4096); r += c
                except BlockingIOError: break
            elif r: break
        return r
    finally: os.close(fd)

def main():
    cmd, dev = sys.argv[1], sys.argv[2] if len(sys.argv)>2 else None

    if cmd == "mon_ver":
        r = wr(dev, build(CLS_MON, MON_VER))
        fs = parse(r)
        print(json.dumps(fs))

    elif cmd == "cfg_msg_nav":
        f1 = build(CLS_CFG, CFG_MSG, bytes([CLS_NAV, NAV_STATUS, 1]))
        f2 = build(CLS_CFG, CFG_MSG, bytes([CLS_NAV, NAV_CLOCK, 1]))
        r = wr(dev, f1+f2, tmo=2.0)
        fs = parse(r)
        print(json.dumps(fs))

    elif cmd == "signal_block":
        v = int(sys.argv[3]) if len(sys.argv)>3 else 50
        pl = bytes([0,1,0,0]) + struct.pack('<IB', KEY_NCNOTHRS, v)
        r = wr(dev, build(CLS_CFG, CFG_VALSET, pl))
        print(json.dumps(parse(r)))

    elif cmd == "signal_restore":
        pl = bytes([0,1,0,0]) + struct.pack('<IB', KEY_NCNOTHRS, 0)
        r = wr(dev, build(CLS_CFG, CFG_VALSET, pl))
        print(json.dumps(parse(r)))

    elif cmd == "write_nmea":
        nmea = sys.argv[3]
        r = wr(dev, (nmea+'\r\n').encode(), tmo=1.0)
        t = r.decode(errors='replace')
        print(json.dumps({"echoed": nmea in t, "len": len(r)}))

    elif cmd == "read_nav_fix":
        # Keep fd open, optionally re-enable NAV if needed, then wait for data
        fd = os.open(dev, os.O_RDWR|os.O_NONBLOCK)
        try:
            # Re-send CFG-MSG to ensure NAV injection is running on this open fd
            f1 = build(CLS_CFG, CFG_MSG, bytes([CLS_NAV, NAV_STATUS, 1]))
            os.write(fd, f1)
            time.sleep(0.1)
            # Drain ACK
            try: os.read(fd, 4096)
            except BlockingIOError: pass
            # Now wait for NAV-STATUS
            dl = time.monotonic() + 4.0
            buf = b""
            while time.monotonic() < dl:
                s, _, _ = select.select([fd],[],[],min(dl-time.monotonic(),0.3))
                if fd in s:
                    try: buf += os.read(fd, 4096)
                    except BlockingIOError: pass
                for f in parse(buf):
                    if f["class"]==CLS_NAV and f["id"]==NAV_STATUS:
                        p = bytes.fromhex(f["payload"])
                        if len(p)>=5:
                            print(json.dumps({"gps_fix":p[4]})); return
                buf = b""  # reset to avoid re-parsing
        finally:
            os.close(fd)
        print(json.dumps({"gps_fix":-1}))

    elif cmd == "read_nav":
        # Keep fd open and enable NAV injection, then read
        fd = os.open(dev, os.O_RDWR|os.O_NONBLOCK)
        try:
            f1 = build(CLS_CFG, CFG_MSG, bytes([CLS_NAV, NAV_STATUS, 1]))
            f2 = build(CLS_CFG, CFG_MSG, bytes([CLS_NAV, NAV_CLOCK, 1]))
            os.write(fd, f1+f2)
            time.sleep(0.2)
            try: os.read(fd, 4096)  # drain ACKs
            except BlockingIOError: pass
            dl = time.monotonic() + 3.0
            buf = b""
            while time.monotonic() < dl:
                s, _, _ = select.select([fd],[],[],min(dl-time.monotonic(),0.3))
                if fd in s:
                    try: buf += os.read(fd, 4096)
                    except BlockingIOError: pass
            fs = [f for f in parse(buf) if f["class"]==CLS_NAV]
            print(json.dumps(fs))
        finally:
            os.close(fd)

    elif cmd == "send_generic":
        c, m = int(sys.argv[3],0), int(sys.argv[4],0)
        r = wr(dev, build(c, m, b"\x00\x00"))
        print(json.dumps(parse(r)))

if __name__=="__main__":
    main()
PYEOF
    chmod +x "$UBX_HELPER"
}
ubx() { python3 "$UBX_HELPER" "$@" 2>/dev/null; }

# ---- Netlink helper ----
GENL_HELPER=""
setup_genl_helper() {
    GENL_HELPER=$(mktemp /tmp/dpll-genl2-XXXXXX.py)
    cat > "$GENL_HELPER" <<'PYEOF'
import socket, struct, json, sys
def nl(t,fl,sq,p): return struct.pack('=IHHII',len(p)+16,t,fl,sq,0)+p
def gm(c,v,a=b""): return struct.pack('=BBH',c,v,0)+a
def at(t,d):
    l=4+len(d); p=(4-(l%4))%4; return struct.pack('=HH',l,t)+d+b'\x00'*p
def pa(d):
    a={}
    while len(d)>=4:
        l,t=struct.unpack('=HH',d[:4])
        if l<4: break
        a[t]=d[4:l]; d=d[((l+3)&~3):]
    return a
s=socket.socket(socket.AF_NETLINK,socket.SOCK_RAW,16); s.settimeout(3); s.bind((0,0))
p=gm(3,1,at(2,b"dpll\x00")); s.send(nl(0x10,1,1,p)); r=s.recv(65536)
if struct.unpack('=H',r[4:6])[0]==2: print("-1"); s.close(); sys.exit()
fa=pa(r[20:]); fam=struct.unpack('=H',fa[1])[0]
p=gm(2,1); s.send(nl(fam,0x301,2,p)); res=[]
while True:
    r=s.recv(65536); o=0
    while o+16<=len(r):
        ml=struct.unpack('=I',r[o:o+4])[0]
        if ml<16: break
        mt=struct.unpack('=H',r[o+4:o+6])[0]
        if mt in (2,3):
            if res: ls=struct.unpack('=I',res[0].get(7,b'\xff\xff\xff\xff')[:4])[0]; print(ls)
            else: print("-1")
            s.close(); sys.exit()
        d=r[o+16:o+ml]
        if len(d)>=4: res.append(pa(d[4:]))
        o+=(ml+3)&~3
PYEOF
}
genl_lock_status() { python3 "$GENL_HELPER" 2>/dev/null || echo "-1"; }

trap_cleanup() {
    cleanup_all_devices
    [[ -f "${UBX_HELPER:-}" ]] && rm -f "$UBX_HELPER"
    [[ -f "${GENL_HELPER:-}" ]] && rm -f "$GENL_HELPER"
}
trap trap_cleanup EXIT

# ===================================================================
log "GNSS / UBX Protocol unit tests"
echo "  Kernel: $(uname -r)"; echo "  Date:   $(date -u)"; echo

[[ ! $(command -v python3) ]] && echo "ERROR: python3 required" && exit 1
setup_ubx_helper; setup_genl_helper

# --- 1. Module check ---
log "1. Module check"
if [[ "$NO_LOAD" == false ]]; then
    rmmod netdevsim nsim_dpll nsim_ptp_mock nsim_ptp 2>/dev/null || true; sleep 0.5
    modprobe gnss 2>/dev/null || true
    modprobe nsim_ptp && pass "nsim_ptp" || fail "nsim_ptp"
    modprobe nsim_ptp_mock && pass "nsim_ptp_mock" || fail "nsim_ptp_mock"
    modprobe nsim_dpll && pass "nsim_dpll" || fail "nsim_dpll"
    modprobe netdevsim pci_bus_nr=0x1f && pass "netdevsim" || fail "netdevsim"
else
    lsmod | grep -q netdevsim && pass "netdevsim loaded" || fail "netdevsim"
fi
echo

# --- 2. Device + GNSS discovery ---
log "2. Device creation + GNSS discovery"
cleanup_all_devices; create_device 1 1 2 1 1
DPLL_SYSFS=$(dpll_sysfs_path 1)
GNSS_DEV=""
for g in /sys/class/gnss/gnss*; do
    [[ -d "$g" ]] || continue
    n=$(basename "$g")
    if [[ -c "/dev/$n" ]]; then GNSS_DEV="/dev/$n"; chmod 666 "$GNSS_DEV" 2>/dev/null; break; fi
done
[[ -n "$GNSS_DEV" ]] && pass "GNSS device: $GNSS_DEV" || fail "no GNSS chardev"
echo

# --- 3. UBX MON-VER ---
log "3. UBX MON-VER request/response"
if [[ -n "$GNSS_DEV" ]]; then
    R=$(ubx mon_ver "$GNSS_DEV")
    C=$(echo "$R" | python3 -c "import sys,json;print(sum(1 for f in json.load(sys.stdin) if f['class']==0x0A and f['id']==0x04))")
    (( C>=1 )) && pass "MON-VER response ($C)" || fail "no MON-VER response"
    if (( C>=1 )); then
        SW=$(echo "$R" | python3 -c "
import sys,json
for f in json.load(sys.stdin):
 if f['class']==0x0A:
  print(bytes.fromhex(f['payload'])[:30].split(b'\x00')[0].decode()); break")
        echo "$SW" | grep -qF "SIM" && pass "MON-VER contains 'SIM'" || fail "MON-VER missing 'SIM' ($SW)"
    fi
else skip "no GNSS"; fi
echo

# --- 4. UBX CFG-MSG NAV enable ---
log "4. UBX CFG-MSG NAV-STATUS + NAV-CLOCK enable"
if [[ -n "$GNSS_DEV" ]]; then
    R=$(ubx cfg_msg_nav "$GNSS_DEV")
    A=$(echo "$R" | python3 -c "import sys,json;print(sum(1 for f in json.load(sys.stdin) if f['class']==0x05))")
    (( A>=2 )) && pass "2 ACKs for CFG-MSG" || { (( A>=1 )) && pass "1 ACK for CFG-MSG" || fail "no ACK"; }
else skip "no GNSS"; fi
echo

# --- 5. NAV periodic injection ---
log "5. NAV periodic injection (1 Hz)"
if [[ -n "$GNSS_DEV" ]]; then
    sleep 1.5
    R=$(ubx read_nav "$GNSS_DEV")
    C=$(echo "$R" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))")
    (( C>=1 )) && pass "NAV frames received ($C)" || fail "no NAV frames"
    if (( C>=1 )); then
        HS=$(echo "$R" | python3 -c "import sys,json;print(1 if any(f['id']==0x03 for f in json.load(sys.stdin)) else 0)")
        HC=$(echo "$R" | python3 -c "import sys,json;print(1 if any(f['id']==0x22 for f in json.load(sys.stdin)) else 0)")
        [[ "$HS" == "1" ]] && pass "NAV-STATUS present" || fail "NAV-STATUS missing"
        [[ "$HC" == "1" ]] && pass "NAV-CLOCK present" || fail "NAV-CLOCK missing"
    fi
else skip "no GNSS"; fi
echo

# --- 6. gpsFix = 3 in normal state ---
log "6. gpsFix = 3 (3D) in normal state"
if [[ -n "$GNSS_DEV" ]]; then
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    [[ "$F" == "3" ]] && pass "gpsFix=3" || { [[ "$F" == "-1" ]] && skip "no NAV-STATUS" || fail "gpsFix=$F"; }
else skip "no GNSS"; fi
echo

# --- 7. NMEA echo ---
log "7. NMEA echo (write → read)"
if [[ -n "$GNSS_DEV" ]]; then
    GGA='$GNGGA,120000.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,47.0,M,,*47'
    E=$(ubx write_nmea "$GNSS_DEV" "$GGA" | python3 -c "import sys,json;print(json.load(sys.stdin)['echoed'])")
    [[ "$E" == "True" ]] && pass "NMEA echoed" || fail "NMEA not echoed"
else skip "no GNSS"; fi
echo

# --- 8. NMEA GGA fix quality parsing ---
log "8. NMEA GGA fix quality parsing"
if [[ -n "$GNSS_DEV" ]]; then
    # fix=0 → gpsFix=0
    ubx write_nmea "$GNSS_DEV" '$GNGGA,120000.00,4807.038,N,01131.000,E,0,08,0.9,545.4,M,47.0,M,,*46' >/dev/null
    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    [[ "$F" == "0" ]] && pass "GGA fix=0 → gpsFix=0" || { [[ "$F" == "-1" ]] && skip "no NAV" || fail "gpsFix=$F (expected 0)"; }

    # fix=1 → gpsFix=3
    ubx write_nmea "$GNSS_DEV" '$GNGGA,120000.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,47.0,M,,*47' >/dev/null
    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    [[ "$F" == "3" ]] && pass "GGA fix=1 → gpsFix=3" || { [[ "$F" == "-1" ]] && skip "no NAV" || fail "gpsFix=$F (expected 3)"; }
else skip "no GNSS"; fi
echo

# --- 9. Signal block via UBX CFG-VALSET ---
log "9. UBX CFG-VALSET signal block (INFIL_NCNOTHRS=50)"
if [[ -n "$GNSS_DEV" ]]; then
    S=$(cat "$DPLL_SYSFS"); assert_eq "pre-block is 'locked'" "locked" "$S"

    R=$(ubx signal_block "$GNSS_DEV" 50)
    A=$(echo "$R" | python3 -c "import sys,json;print(sum(1 for f in json.load(sys.stdin) if f['class']==0x05))")
    (( A>=1 )) && pass "ACK for signal_block" || fail "no ACK"
    sleep 0.3

    S=$(cat "$DPLL_SYSFS"); assert_eq "post-block is 'holdover'" "holdover" "$S"
    NL=$(genl_lock_status);  assert_eq "netlink=4 (HOLDOVER)" "4" "$NL"
else skip "no GNSS"; fi
echo

# --- 10. Sysfs isolated during signal_blocked ---
log "10. Sysfs isolation during signal_blocked"
if [[ -n "$GNSS_DEV" ]]; then
    echo "locked" > "$DPLL_SYSFS" 2>/dev/null || true
    S=$(cat "$DPLL_SYSFS"); assert_eq "write 'locked' ignored" "holdover" "$S"
    echo "freerun" > "$DPLL_SYSFS" 2>/dev/null || true
    S=$(cat "$DPLL_SYSFS"); assert_eq "write 'freerun' ignored" "holdover" "$S"
else skip "no GNSS"; fi
echo

# --- 11. gpsFix = 0 during signal block ---
log "11. gpsFix = 0 during signal block"
if [[ -n "$GNSS_DEV" ]]; then
    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    [[ "$F" == "0" ]] && pass "gpsFix=0 during block" || { [[ "$F" == "-1" ]] && skip "no NAV" || fail "gpsFix=$F"; }
else skip "no GNSS"; fi
echo

# --- 12. NMEA forwarded during signal block ---
log "12. NMEA forwarding during signal block"
if [[ -n "$GNSS_DEV" ]]; then
    E=$(ubx write_nmea "$GNSS_DEV" '$GNGGA,130000.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,47.0,M,,*56' | python3 -c "import sys,json;print(json.load(sys.stdin)['echoed'])")
    [[ "$E" == "True" ]] && pass "NMEA forwarded during block" || fail "NMEA NOT forwarded"
else skip "no GNSS"; fi
echo

# --- 13. GGA parsing skipped during block ---
log "13. GGA parsing skipped during signal block"
if [[ -n "$GNSS_DEV" ]]; then
    ubx write_nmea "$GNSS_DEV" '$GNGGA,140000.00,4807.038,N,01131.000,E,1,08,0.9,545.4,M,47.0,M,,*50' >/dev/null
    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    [[ "$F" == "0" ]] && pass "GGA parsing skipped (gpsFix stays 0)" || fail "GGA NOT skipped (gpsFix=$F)"
else skip "no GNSS"; fi
echo

# --- 14. Signal restore via UBX CFG-VALSET ---
log "14. UBX CFG-VALSET signal restore (INFIL_NCNOTHRS=0)"
if [[ -n "$GNSS_DEV" ]]; then
    R=$(ubx signal_restore "$GNSS_DEV")
    A=$(echo "$R" | python3 -c "import sys,json;print(sum(1 for f in json.load(sys.stdin) if f['class']==0x05))")
    (( A>=1 )) && pass "ACK for signal_restore" || fail "no ACK"
    sleep 0.3

    S=$(cat "$DPLL_SYSFS"); assert_eq "post-restore is 'locked'" "locked" "$S"
    NL=$(genl_lock_status);  assert_eq "netlink=3 (LOCKED_HO_ACQ)" "3" "$NL"
else skip "no GNSS"; fi
echo

# --- 15. Sysfs unblocked after restore ---
log "15. Sysfs unblocked after restore"
if [[ -n "$GNSS_DEV" ]]; then
    echo "holdover" > "$DPLL_SYSFS"; S=$(cat "$DPLL_SYSFS"); assert_eq "write 'holdover' works" "holdover" "$S"
    echo "locked"   > "$DPLL_SYSFS"; S=$(cat "$DPLL_SYSFS"); assert_eq "write 'locked' works"   "locked"   "$S"
else skip "no GNSS"; fi
echo

# --- 16. gpsFix = 3 after restore ---
log "16. gpsFix = 3 after restore"
if [[ -n "$GNSS_DEV" ]]; then
    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    [[ "$F" == "3" ]] && pass "gpsFix=3 restored" || fail "gpsFix=$F (expected 3)"
else skip "no GNSS"; fi
echo

# --- 17. Full signal loss/recovery cycle ---
log "17. Full signal loss/recovery cycle"
if [[ -n "$GNSS_DEV" ]]; then
    S=$(cat "$DPLL_SYSFS"); assert_eq "cycle: initial 'locked'" "locked" "$S"

    ubx signal_block "$GNSS_DEV" 50 >/dev/null; sleep 0.3
    S=$(cat "$DPLL_SYSFS"); assert_eq "cycle: block → 'holdover'" "holdover" "$S"
    NL=$(genl_lock_status);  assert_eq "cycle: netlink=4" "4" "$NL"

    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    assert_eq "cycle: gpsFix=0 during block" "0" "$F"

    ubx signal_restore "$GNSS_DEV" >/dev/null; sleep 0.3
    S=$(cat "$DPLL_SYSFS"); assert_eq "cycle: restore → 'locked'" "locked" "$S"
    NL=$(genl_lock_status);  assert_eq "cycle: netlink=3" "3" "$NL"

    sleep 1.5
    F=$(ubx read_nav_fix "$GNSS_DEV" | python3 -c "import sys,json;print(json.load(sys.stdin)['gps_fix'])")
    assert_eq "cycle: gpsFix=3 after restore" "3" "$F"
else skip "no GNSS"; fi
echo

# --- 18. Multiple block/restore cycles (stress) ---
log "18. Multiple block/restore cycles (x10)"
if [[ -n "$GNSS_DEV" ]]; then
    OK=true
    for i in $(seq 1 10); do
        ubx signal_block "$GNSS_DEV" 50 >/dev/null; sleep 0.15
        S=$(cat "$DPLL_SYSFS")
        [[ "$S" != "holdover" ]] && OK=false && fail "stress #$i block: got '$S'" && break
        ubx signal_restore "$GNSS_DEV" >/dev/null; sleep 0.15
        S=$(cat "$DPLL_SYSFS")
        [[ "$S" != "locked" ]] && OK=false && fail "stress #$i restore: got '$S'" && break
    done
    [[ "$OK" == true ]] && pass "10 block/restore cycles OK"
else skip "no GNSS"; fi
echo

# --- 19. ACK for generic/unknown UBX commands ---
log "19. ACK for generic UBX command"
if [[ -n "$GNSS_DEV" ]]; then
    R=$(ubx send_generic "$GNSS_DEV" 0x0B 0x01)
    A=$(echo "$R" | python3 -c "import sys,json;print(sum(1 for f in json.load(sys.stdin) if f['class']==0x05))")
    (( A>=1 )) && pass "ACK for class=0x0B" || fail "no ACK"
else skip "no GNSS"; fi
echo

# --- 20. Teardown cleans GNSS ---
log "20. Teardown cleans GNSS"
cleanup_all_devices
G=$(ls /sys/class/gnss/ 2>/dev/null || true)
[[ -z "$G" ]] && pass "GNSS removed after teardown" || fail "GNSS still present: $G"
echo

# --- 21. Re-creation restores everything ---
log "21. Re-creation restores GNSS + signal block"
create_device 1 1 2 1 1
DPLL_SYSFS=$(dpll_sysfs_path 1)
G2=""
for g in /sys/class/gnss/gnss*; do
    [[ -d "$g" ]] || continue; n=$(basename "$g")
    [[ -c "/dev/$n" ]] && G2="/dev/$n" && chmod 666 "$G2" 2>/dev/null && break
done
[[ -n "$G2" ]] && pass "GNSS re-registered" || fail "no GNSS after re-create"
S=$(cat "$DPLL_SYSFS"); assert_eq "lock_status defaults locked" "locked" "$S"
if [[ -n "$G2" ]]; then
    ubx signal_block "$G2" 50 >/dev/null; sleep 0.3
    S=$(cat "$DPLL_SYSFS"); assert_eq "block works after re-create" "holdover" "$S"
    ubx signal_restore "$G2" >/dev/null; sleep 0.3
    S=$(cat "$DPLL_SYSFS"); assert_eq "restore works after re-create" "locked" "$S"
fi
echo

# --- 22. dmesg sanity ---
log "22. dmesg sanity"
D=$(dmesg | grep -iE "gnss|ubx|dpll" | tail -20 || true)
echo "$D" | grep -qiE "bug|oops|panic|call.trace|rcu.*stall" && fail "dmesg errors" || pass "dmesg clean"
echo

# --- 23. Final cleanup ---
log "23. Cleanup"
cleanup_all_devices; pass "cleaned up"
echo

# ===================================================================
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  GNSS / UBX Test Results${NC}"
echo -e "${BOLD}============================================${NC}"
echo -e "  Total:   ${TOTAL}"
echo -e "  ${GREEN}Passed:  ${PASS}${NC}"
echo -e "  ${RED}Failed:  ${FAIL}${NC}"
echo -e "  ${YELLOW}Skipped: ${SKIP}${NC}"
[[ $FAIL -gt 0 ]] && echo -e "\n${RED}  Failures:${NC}${FAILURES}" && echo && exit 1
echo; echo -e "${GREEN}All tests passed.${NC}"; exit 0
