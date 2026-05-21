#!/bin/bash
#
# Launch an Ubuntu Cloud VM in UTM, install the netdevsim DKMS modules
# from the source tree, load them, run smoke tests, then install all
# ptp-operator prerequisites and run the full ptp-operator test suite
# via run-on-vm.sh.
#
# This mirrors what the GitHub Actions CI does (ci.yml), but locally
# on macOS via UTM so you can iterate before pushing.
#
# The Ubuntu aarch64 cloud image uses a generic kernel whose version
# tracks the same release train as the Azure-optimised kernel on
# GitHub runners — API surface is equivalent.
#
# Usage:
#   ./scripts/test-utm-ubuntu.sh [options]
#
# Options:
#   --release 22.04|24.04 Ubuntu release             (default: 24.04)
#   --ssh-key PATH        SSH private key for VM      (auto-detected)
#   --vm-name NAME        UTM VM name                 (default: netdevsim-ubuntu-test)
#   --ram MiB             RAM in MiB                  (default: 16384)
#   --cpus N              CPU cores                   (default: 4)
#   --disk-size SIZE      qemu-img resize target      (default: 40G)
#   --cleanup             Delete VM after tests finish
#   --skip-tests          Only create VM + install DKMS, don't run tests
#   --skip-ptp-operator   Run smoke tests but skip ptp-operator suite
#   --shell               Drop into an interactive SSH shell after setup
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
UBUNTU_RELEASE="24.04"
VM_NAME="netdevsim-ubuntu-test"
VM_RAM=16384
VM_CPUS=4
VM_DISK_SIZE="40G"
CLEANUP=false
SKIP_TESTS=false
SKIP_PTP_OPERATOR=false
DROP_SHELL=false
SSH_KEY=""

DKMS_SRC="$(cd "$(dirname "$0")/.." && pwd)"
DKMS_PKG="netdevsim"
DKMS_VER="6.9.5"

TMPDIR_BASE="/tmp/netdevsim-dkms-utm-ubuntu"
SSH_USER="ubuntu"
IMAGE_CACHE="${HOME}/.cache/netdevsim-dkms"

# ---------------------------------------------------------------------------
# Image URLs (aarch64) — resolved after argument parsing
# ---------------------------------------------------------------------------
image_url_for_release() {
    case "$1" in
        22.04) echo "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img" ;;
        24.04) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img" ;;
        *)     echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    sed -n '3,29p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)           UBUNTU_RELEASE="$2"; shift 2 ;;
        --ssh-key)           SSH_KEY="$2";        shift 2 ;;
        --vm-name)           VM_NAME="$2";        shift 2 ;;
        --ram)               VM_RAM="$2";         shift 2 ;;
        --cpus)              VM_CPUS="$2";        shift 2 ;;
        --disk-size)         VM_DISK_SIZE="$2";   shift 2 ;;
        --cleanup)           CLEANUP=true;        shift ;;
        --skip-tests)        SKIP_TESTS=true;     shift ;;
        --skip-ptp-operator) SKIP_PTP_OPERATOR=true; shift ;;
        --shell)             DROP_SHELL=true;     shift ;;
        --help|-h)           usage ;;
        *)                   echo "Unknown option: $1"; usage ;;
    esac
done

IMAGE_URL="$(image_url_for_release "$UBUNTU_RELEASE")"
[[ -n "$IMAGE_URL" ]] || { echo "Unsupported release: $UBUNTU_RELEASE (use 22.04 or 24.04)"; exit 1; }
IMAGE_FILENAME="$(basename "$IMAGE_URL")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
ts()   { date "+%H:%M:%S"; }

VM_IP=""

cleanup_on_exit() {
    local rc=$?
    if [[ "$CLEANUP" == true ]]; then
        log "Cleaning up VM '$VM_NAME' ..."
        utmctl stop "$VM_NAME" 2>/dev/null || true
        sleep 2
        utmctl delete "$VM_NAME" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_BASE"
    if [[ $rc -eq 0 ]]; then
        log "Done — all steps finished successfully."
    else
        log "Script exited with code $rc."
    fi
}
trap cleanup_on_exit EXIT

vm_ssh() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${VM_IP}" "$@"
}

vm_scp() {
    scp "${SSH_OPTS[@]}" "$@"
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
log "Checking prerequisites ..."

if [[ -n "$SSH_KEY" ]]; then
    SSH_KEY="$(cd "$(dirname "$SSH_KEY")" && pwd)/$(basename "$SSH_KEY")"
    [[ -f "$SSH_KEY" ]] || die "SSH private key not found: $SSH_KEY"
else
    for candidate in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ecdsa; do
        if [[ -f "$candidate" ]]; then
            SSH_KEY="$candidate"
            break
        fi
    done
    [[ -n "$SSH_KEY" ]] || die "No SSH key found. Specify --ssh-key or generate: ssh-keygen -t ed25519"
fi

SSH_PUBKEY_FILE="${SSH_KEY}.pub"
[[ -f "$SSH_PUBKEY_FILE" ]] || die "Public key not found at ${SSH_PUBKEY_FILE}"
SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

command -v utmctl  >/dev/null 2>&1 || die "utmctl not found. Install UTM from https://mac.getutm.app"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found. Install with: brew install qemu"

MKISO_CMD=""
if command -v mkisofs >/dev/null 2>&1; then
    MKISO_CMD="mkisofs"
elif command -v genisoimage >/dev/null 2>&1; then
    MKISO_CMD="genisoimage"
fi

log "  DKMS source: $DKMS_SRC"
log "  Ubuntu:      $UBUNTU_RELEASE (arm64)"
log "  SSH key:     $SSH_KEY"
log "  ISO tool:    ${MKISO_CMD:-hdiutil (fallback)}"

# ---------------------------------------------------------------------------
# 2. Download Ubuntu Cloud image (cached)
# ---------------------------------------------------------------------------
mkdir -p "$IMAGE_CACHE"
CACHED_IMG="$IMAGE_CACHE/$IMAGE_FILENAME"

if [[ -f "$CACHED_IMG" ]]; then
    log "Using cached image: $CACHED_IMG"
else
    log "Downloading Ubuntu ${UBUNTU_RELEASE} Cloud arm64 image ..."
    curl -fSL -C - --retry 5 --retry-delay 3 --retry-all-errors \
        -o "${CACHED_IMG}.partial" "$IMAGE_URL"
    mv "${CACHED_IMG}.partial" "$CACHED_IMG"
    log "  Saved to $CACHED_IMG"
fi

# ---------------------------------------------------------------------------
# 3. Prepare working directory and resize disk
# ---------------------------------------------------------------------------
log "Preparing disk image (resize to $VM_DISK_SIZE) ..."

mkdir -p "$TMPDIR_BASE"
WORK_QCOW2="$TMPDIR_BASE/${VM_NAME}.qcow2"
qemu-img convert -f qcow2 -O qcow2 "$CACHED_IMG" "$WORK_QCOW2"
qemu-img resize "$WORK_QCOW2" "$VM_DISK_SIZE"

# ---------------------------------------------------------------------------
# 4. Create cloud-init NoCloud ISO
# ---------------------------------------------------------------------------
log "Creating cloud-init NoCloud ISO ..."

CIDATA_DIR="$TMPDIR_BASE/cidata"
CIDATA_ISO="$TMPDIR_BASE/cidata.iso"
mkdir -p "$CIDATA_DIR"

cat > "$CIDATA_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

HWE_PACKAGES=""
if [[ "$UBUNTU_RELEASE" == "24.04" ]]; then
    HWE_PACKAGES="
  - linux-generic-hwe-24.04
  - linux-headers-generic-hwe-24.04"
elif [[ "$UBUNTU_RELEASE" == "22.04" ]]; then
    HWE_PACKAGES="
  - linux-generic-hwe-22.04
  - linux-headers-generic-hwe-22.04"
fi

cat > "$CIDATA_DIR/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBKEY}

ssh_pwauth: false
disable_root: false

runcmd:
  - mkdir -p /root/.ssh && chmod 700 /root/.ssh
  - cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd
  - systemctl enable --now qemu-guest-agent

growpart:
  mode: auto
  devices: ['/']

package_update: true
packages:
  - qemu-guest-agent
  - dkms
  - gcc
  - make
  - linux-headers-generic${HWE_PACKAGES}
EOF

if [[ -n "$MKISO_CMD" ]]; then
    "$MKISO_CMD" -output "$CIDATA_ISO" -volid cidata -joliet -rock "$CIDATA_DIR/"
else
    hdiutil makehybrid \
        -o "$CIDATA_ISO" \
        "$CIDATA_DIR" \
        -joliet -iso \
        -default-volume-name cidata \
        -iso-volume-name cidata
    if [[ -f "${CIDATA_ISO}.cdr" && ! -f "$CIDATA_ISO" ]]; then
        mv "${CIDATA_ISO}.cdr" "$CIDATA_ISO"
    fi
fi

[[ -f "$CIDATA_ISO" ]] || die "Failed to create cloud-init ISO"

# ---------------------------------------------------------------------------
# 5. Build .utm bundle and import into UTM
# ---------------------------------------------------------------------------
log "Creating UTM VM '$VM_NAME' ..."

if utmctl list 2>/dev/null | grep -q "$VM_NAME"; then
    log "  Removing existing VM '$VM_NAME' ..."
    utmctl stop "$VM_NAME" 2>/dev/null || true
    sleep 2
    utmctl delete "$VM_NAME" 2>/dev/null || true
    sleep 2
fi

DISK_UUID=$(uuidgen)
CD_UUID=$(uuidgen)
VM_UUID=$(uuidgen)
MAC_ADDR=$(printf '52:54:00:%02X:%02X:%02X' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

UTM_BUNDLE="$TMPDIR_BASE/${VM_NAME}.utm"
mkdir -p "$UTM_BUNDLE/Data"

cp "$WORK_QCOW2" "$UTM_BUNDLE/Data/${DISK_UUID}.qcow2"
cp "$CIDATA_ISO"  "$UTM_BUNDLE/Data/${CD_UUID}.iso"

cat > "$UTM_BUNDLE/config.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Backend</key>
	<string>QEMU</string>
	<key>ConfigurationVersion</key>
	<integer>4</integer>
	<key>Display</key>
	<array>
		<dict>
			<key>DownscalingFilter</key>
			<string>Linear</string>
			<key>DynamicResolution</key>
			<true/>
			<key>Hardware</key>
			<string>virtio-gpu-pci</string>
			<key>NativeResolution</key>
			<false/>
			<key>UpscalingFilter</key>
			<string>Nearest</string>
		</dict>
	</array>
	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>${DISK_UUID}</string>
			<key>ImageName</key>
			<string>${DISK_UUID}.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
		<dict>
			<key>Identifier</key>
			<string>${CD_UUID}</string>
			<key>ImageName</key>
			<string>${CD_UUID}.iso</string>
			<key>ImageType</key>
			<string>CD</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<true/>
		</dict>
	</array>
	<key>Information</key>
	<dict>
		<key>Icon</key>
		<string>linux</string>
		<key>IconCustom</key>
		<false/>
		<key>Name</key>
		<string>${VM_NAME}</string>
		<key>UUID</key>
		<string>${VM_UUID}</string>
	</dict>
	<key>Input</key>
	<dict>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
	</dict>
	<key>Network</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>virtio-net-pci</string>
			<key>IsolateFromHost</key>
			<false/>
			<key>MacAddress</key>
			<string>${MAC_ADDR}</string>
			<key>Mode</key>
			<string>Shared</string>
			<key>PortForward</key>
			<array/>
		</dict>
	</array>
	<key>QEMU</key>
	<dict>
		<key>AdditionalArguments</key>
		<array/>
		<key>BalloonDevice</key>
		<false/>
		<key>DebugLog</key>
		<false/>
		<key>Hypervisor</key>
		<true/>
		<key>MachinePropertyOverride</key>
		<string>acpi=off</string>
		<key>PS2Controller</key>
		<false/>
		<key>RNGDevice</key>
		<true/>
		<key>RTCLocalTime</key>
		<false/>
		<key>TPMDevice</key>
		<false/>
		<key>TSO</key>
		<false/>
		<key>UEFIBoot</key>
		<true/>
	</dict>
	<key>Serial</key>
	<array/>
	<key>Sharing</key>
	<dict>
		<key>ClipboardSharing</key>
		<true/>
		<key>DirectoryShareMode</key>
		<string>VirtFS</string>
		<key>DirectoryShareReadOnly</key>
		<false/>
	</dict>
	<key>Sound</key>
	<array>
		<dict>
			<key>Hardware</key>
			<string>intel-hda</string>
		</dict>
	</array>
	<key>System</key>
	<dict>
		<key>Architecture</key>
		<string>aarch64</string>
		<key>CPU</key>
		<string>default</string>
		<key>CPUCount</key>
		<integer>${VM_CPUS}</integer>
		<key>CPUFlagsAdd</key>
		<array/>
		<key>CPUFlagsRemove</key>
		<array/>
		<key>ForceMulticore</key>
		<false/>
		<key>JITCacheSize</key>
		<integer>0</integer>
		<key>MemorySize</key>
		<integer>${VM_RAM}</integer>
		<key>Target</key>
		<string>virt</string>
	</dict>
</dict>
</plist>
PLIST

plutil -lint "$UTM_BUNDLE/config.plist" >/dev/null

open -a UTM
sleep 3

osascript <<APPLESCRIPT
tell application "UTM"
    import new virtual machine from POSIX file "${UTM_BUNDLE}"
end tell
APPLESCRIPT

log "  VM imported."

# ---------------------------------------------------------------------------
# 6. Start VM and discover IP
# ---------------------------------------------------------------------------
log "Starting VM ..."
sleep 3
utmctl start "$VM_NAME"

log "Waiting for VM IPv4 address ..."
log "  (cloud-init must install qemu-guest-agent first — this can take up to 5 min)"
SECONDS=0
MAX_WAIT=420
VM_IP6=""
while (( SECONDS < MAX_WAIT )); do
    addrs="$(utmctl ip-address "$VM_NAME" 2>/dev/null || true)"
    VM_IP=$( echo "$addrs" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | head -1 || true)
    if [[ -z "$VM_IP6" ]]; then
        VM_IP6=$( echo "$addrs" \
                | grep -E '^[0-9a-fA-F:]+$' \
                | grep -viE '^(::1|fe80)' \
                | head -1 || true )
    fi
    if [[ -n "$VM_IP" ]]; then
        break
    fi
    # Progress indicator every 30s
    if (( SECONDS % 30 < 6 )); then
        log "  ... still waiting (${SECONDS}s elapsed)"
    fi
    sleep 5
done

if [[ -z "$VM_IP" ]]; then
    log "utmctl ip-address returned nothing after ${MAX_WAIT}s."
    log "Trying ARP scan for MAC ${MAC_ADDR} as fallback ..."
    # Normalise our MAC to lowercase colon-separated
    MAC_LOWER="$(echo "$MAC_ADDR" | tr '[:upper:]' '[:lower:]')"
    VM_IP="$(arp -a 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | grep "$MAC_LOWER" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 || true)"

    if [[ -z "$VM_IP" && -n "$VM_IP6" ]]; then
        log "IPv6 found (${VM_IP6}); trying SSH diagnostics ..."
        VM_IP="$VM_IP6"
        for _ in {1..12}; do
            vm_ssh "true" 2>/dev/null && break || sleep 5
        done
        if vm_ssh "true" 2>/dev/null; then
            vm_ssh 'ip -brief addr; echo "----"; ip -4 route' 2>&1 || true
        fi
    fi

    [[ -n "$VM_IP" ]] || die "Could not discover VM IP address after ${MAX_WAIT}s."
fi

log "  VM IP: $VM_IP (discovered in ${SECONDS}s)"

log "Waiting for SSH on $VM_IP ..."
SECONDS=0
MAX_SSH_WAIT=120
while (( SECONDS < MAX_SSH_WAIT )); do
    if vm_ssh "true" 2>/dev/null; then
        break
    fi
    sleep 5
done

if ! vm_ssh "true" 2>/dev/null; then
    die "SSH not reachable at ${SSH_USER}@${VM_IP} after ${MAX_SSH_WAIT}s."
fi

log "SSH is up (took ${SECONDS}s)."

log "Waiting for cloud-init to finish ..."
vm_ssh "sudo cloud-init status --wait" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. Reboot into HWE kernel (needed for both 22.04 and 24.04)
# ---------------------------------------------------------------------------
if [[ "$UBUNTU_RELEASE" == "22.04" || "$UBUNTU_RELEASE" == "24.04" ]]; then
    KERNEL_BEFORE="$(vm_ssh 'uname -r')"
    log "Current kernel: $KERNEL_BEFORE"
    log "Rebooting into HWE kernel ..."
    vm_ssh "sudo reboot" 2>/dev/null || true
    sleep 15

    SECONDS=0
    MAX_REBOOT_WAIT=180
    while (( SECONDS < MAX_REBOOT_WAIT )); do
        if vm_ssh "true" 2>/dev/null; then
            break
        fi
        sleep 5
    done

    if ! vm_ssh "true" 2>/dev/null; then
        die "SSH not reachable after reboot (waited ${MAX_REBOOT_WAIT}s)."
    fi

    KERNEL_AFTER="$(vm_ssh 'uname -r')"
    log "Kernel after reboot: $KERNEL_AFTER"
    if [[ "$KERNEL_BEFORE" == "$KERNEL_AFTER" ]]; then
        log "WARNING: kernel did not change after reboot — HWE may not be installed"
    fi
fi

# ---------------------------------------------------------------------------
# 8. Report kernel version and discover config
# ---------------------------------------------------------------------------
log "VM kernel info:"
vm_ssh "uname -a"
RUNNING_KERNEL="$(vm_ssh 'uname -r')"
log "  Running kernel: $RUNNING_KERNEL"

log "Kernel config for relevant modules:"
vm_ssh "grep -E 'NETDEVSIM|PTP_1588|DPLL|DEVLINK|BPF_SYSCALL|XFRM_OFFLOAD|PSAMPLE|MACSEC|GNSS|OPENVSWITCH' \
    /boot/config-\$(uname -r) 2>/dev/null || echo '  /boot/config not found'"

log "Module presence (builtin / loadable / absent):"
vm_ssh "echo '--- modules.builtin ---' && \
    grep -E 'netdevsim|ptp|dpll' /lib/modules/\$(uname -r)/modules.builtin 2>/dev/null || echo '  (none builtin)'; \
    echo '--- modinfo ---' && \
    modinfo netdevsim ptp dpll 2>&1 | grep -E '^filename|^description' || echo '  (none loadable)'"

# ---------------------------------------------------------------------------
# 9. Ensure kernel headers match running kernel
# ---------------------------------------------------------------------------
log "Ensuring kernel headers and extra modules are installed ..."
vm_ssh sudo bash -c "'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq linux-headers-\$(uname -r) linux-modules-extra-\$(uname -r) dkms gcc make 2>&1 | tail -5
echo \"Headers dir: /lib/modules/\$(uname -r)/build\"
ls /lib/modules/\$(uname -r)/build/Makefile >/dev/null 2>&1 && echo \"  OK\" || echo \"  MISSING\"
'"

# ---------------------------------------------------------------------------
# 10. Copy DKMS source tree and install
# ---------------------------------------------------------------------------
log "Copying DKMS source tree to VM ..."

REMOTE_DKMS="/usr/src/${DKMS_PKG}-${DKMS_VER}"
vm_ssh "sudo mkdir -p ${REMOTE_DKMS}"

# Pack the relevant directories into a tarball (avoids many small scp calls)
TAR_STAGING="$TMPDIR_BASE/dkms-src.tar.gz"
tar -C "$DKMS_SRC" -czf "$TAR_STAGING" \
    Makefile dkms.conf install-udev-rule.sh 99-nsim-ptp.rules \
    include ptp dpll netdevsim

vm_scp "$TAR_STAGING" "${SSH_USER}@${VM_IP}:/tmp/dkms-src.tar.gz"
vm_ssh "sudo tar -C ${REMOTE_DKMS} -xzf /tmp/dkms-src.tar.gz"

log "  DKMS add ..."
vm_ssh "sudo dkms add ${DKMS_PKG}/${DKMS_VER}" || {
    log "  (already registered — continuing)"
}

log "  DKMS build ..."
vm_ssh "sudo dkms build ${DKMS_PKG}/${DKMS_VER}" || {
    log "--- make.log ---"
    vm_ssh "sudo cat /var/lib/dkms/${DKMS_PKG}/${DKMS_VER}/build/make.log" || true
    die "DKMS build failed"
}

log "  DKMS install ..."
vm_ssh "sudo dkms install --force ${DKMS_PKG}/${DKMS_VER}"
vm_ssh "dkms status"

# ---------------------------------------------------------------------------
# 11. Install udev rule for /dev/ptp* compat device nodes
# ---------------------------------------------------------------------------
log "Installing nsim_ptp udev rule ..."
vm_ssh "sudo cp ${REMOTE_DKMS}/99-nsim-ptp.rules /etc/udev/rules.d/ && \
        sudo udevadm control --reload-rules"

# ---------------------------------------------------------------------------
# 12. Load modules
# ---------------------------------------------------------------------------
log "Loading modules ..."

vm_ssh sudo bash -c "'
set -euo pipefail
modprobe gnss           && echo \"  gnss            loaded\" || echo \"  gnss            skipped\"
modprobe nsim_ptp       && echo \"  nsim_ptp        loaded\"
modprobe nsim_ptp_mock  && echo \"  nsim_ptp_mock   loaded\"
modprobe nsim_dpll      && echo \"  nsim_dpll       loaded\"
modprobe netdevsim      && echo \"  netdevsim       loaded\"
echo
echo \"--- lsmod ---\"
lsmod | grep -E \"ptp|netdevsim|dpll|gnss\" || true
'"

# ---------------------------------------------------------------------------
# 13. Smoke tests
# ---------------------------------------------------------------------------
if [[ "$SKIP_TESTS" == true ]]; then
    log "Skipping tests (--skip-tests)."
else
    log "Running smoke tests ..."

    vm_ssh sudo bash -c "'
    set -euo pipefail
    set -x

    # Detect fake PCI root domain (netdevsim registers its own PCI root bus)
    PCI_DOMAIN=\$(dmesg | grep -oP \"bus->domain_nr=\K[0-9]+\" | tail -1)
    : \${PCI_DOMAIN:=1}
    PCI_BUS=\$(printf \"%02x\" \$(dmesg | grep -oP \"pci_bus_nr=0x\K[0-9a-f]+\" | tail -1 || echo 1))
    : \${PCI_BUS:=01}
    PCI_ADDR=\"\${PCI_DOMAIN}:\${PCI_BUS}:02.0\"
    echo \"Using PCI address: 000\${PCI_ADDR}\"

    # Create a netdevsim device (id=1, pci_addr, clk_id=1)
    echo \"1 000\${PCI_ADDR} 1\" > /sys/bus/netdevsim/new_device
    sleep 1

    # Verify the bus device appeared
    ls /sys/bus/netdevsim/devices/netdevsim1/

    # Verify PTP clock (nsim_ptp class + /dev/ptp compat device node)
    ls /sys/class/nsim_ptp/
    ls -la /dev/nsim_ptp* /dev/ptp* 2>/dev/null

    # Verify /dev/ptpN has the same major:minor as /dev/nsim_ptpN
    PTP_RDEV=\$(stat -c '%t:%T' /dev/ptp0 2>/dev/null || true)
    NSIM_RDEV=\$(stat -c '%t:%T' /dev/nsim_ptp0 2>/dev/null || true)
    [ -n \"\$PTP_RDEV\" ] && [ \"\$PTP_RDEV\" = \"\$NSIM_RDEV\" ] \\
        && echo \"  /dev/ptp0 matches /dev/nsim_ptp0 (rdev \$PTP_RDEV)\" \\
        || echo \"  WARN: /dev/ptp0 rdev mismatch or missing\"

    # Verify ethtool reports a valid PHC
    IFACE=\$(ls /sys/bus/pci/devices/000\${PCI_ADDR}/net/ 2>/dev/null | head -1)
    if [ -n \"\$IFACE\" ]; then
        echo \"Interface: \$IFACE\"
        ethtool -T \"\$IFACE\" | grep -E \"PTP Hardware Clock|hardware\"
    fi

    # Check dmesg for netdevsim messages
    dmesg | grep -i netdevsim | tail -10

    # Cleanup
    echo \"1\" > /sys/bus/netdevsim/del_device 2>/dev/null || true

    echo
    echo \"=== ALL SMOKE TESTS PASSED ===\"
    '"
fi

# ---------------------------------------------------------------------------
# 14. Install ptp-operator prerequisites
# ---------------------------------------------------------------------------
PTP_REPO="${PTP_REPO:-https://github.com/edcdavid/ptp-operator-upstream.git}"
PTP_BRANCH="${PTP_BRANCH:-netdevsim-dkms}"

if [[ "$SKIP_TESTS" == true || "$SKIP_PTP_OPERATOR" == true ]]; then
    log "Skipping ptp-operator setup."
else
    log "Installing ptp-operator prerequisites ..."

    vm_ssh sudo bash <<'PREREQS'
set -euo pipefail
set -x

apt-get install -y -qq podman pciutils uidmap slirp4netns openvswitch-switch git 2>&1 | tail -3

ARCH=$(uname -m)
GOARCH=arm64
[ "$ARCH" = "x86_64" ] && GOARCH=amd64

# kind
curl -fsSLo /usr/bin/kind "https://kind.sigs.k8s.io/dl/v0.27.0/kind-linux-${GOARCH}"
chmod +x /usr/bin/kind

# kubectl + oc
if [ "$GOARCH" = "arm64" ]; then
    curl -fsSLo /tmp/oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux-arm64.tar.gz
else
    curl -fsSLo /tmp/oc.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
fi
tar -C /tmp -xzf /tmp/oc.tar.gz oc kubectl
mv /tmp/oc /tmp/kubectl /usr/local/bin/

# Go (latest)
GO_VERSION=$(curl -s https://go.dev/VERSION?m=text | head -n 1)
curl -fsSLo /tmp/go.tar.gz "https://go.dev/dl/${GO_VERSION}.linux-${GOARCH}.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz

# helm
curl -fsSL "https://get.helm.sh/helm-v3.17.3-linux-${GOARCH}.tar.gz" | tar -C /tmp -xzf -
mv "/tmp/linux-${GOARCH}/helm" /usr/local/bin/helm

# PATH for root
grep -q /usr/local/go/bin /root/.bashrc 2>/dev/null || \
    echo 'export PATH=$PATH:$HOME/go/bin:/usr/local/go/bin' >> /root/.bashrc
export PATH=/usr/local/go/bin:/root/go/bin:$PATH

# inotify limits (kind needs these)
sysctl -w fs.inotify.max_user_instances=512
sysctl -w fs.inotify.max_user_watches=524288

echo "--- Verification ---"
podman --version
kind version
kubectl version --client 2>/dev/null | head -1
go version
helm version --short
ovs-vsctl --version | head -1
PREREQS

    # -----------------------------------------------------------------------
    # 15. Clone ptp-operator, install ginkgo, go mod vendor
    # -----------------------------------------------------------------------
    log "Cloning ptp-operator (branch: ${PTP_BRANCH}) ..."
    vm_ssh "sudo rm -rf /root/ptp-operator"
    vm_ssh "sudo git clone --depth 1 --branch '${PTP_BRANCH}' '${PTP_REPO}' /root/ptp-operator"

    log "Installing ginkgo and vendoring Go modules ..."
    vm_ssh sudo bash <<'GO_SETUP'
set -euo pipefail
export PATH=/usr/local/go/bin:/root/go/bin:$PATH
cd /root/ptp-operator
go mod tidy 2>&1 | tail -3
go mod vendor 2>&1 | tail -3
go install github.com/onsi/ginkgo/v2/ginkgo@latest
GO_SETUP

    # -----------------------------------------------------------------------
    # 16. Run ptp-operator test suite (--dkms flag handles all adjustments)
    # -----------------------------------------------------------------------
    log "[$(ts)] Running ptp-operator run-on-vm.sh --dkms ..."
    vm_ssh sudo bash -l <<'REMOTE_SCRIPT'
set -euo pipefail
set -x

export PATH=/usr/local/go/bin:/root/go/bin:$PATH
export GOMAXPROCS=$(nproc)

VM_IP=$(hostname -I | awk '{print $1}')
echo "VM_IP=${VM_IP}"

cd /root/ptp-operator/scripts
./run-on-vm.sh --dkms "${VM_IP}"
REMOTE_SCRIPT
    log "[$(ts)] ptp-operator tests completed."
fi

# ---------------------------------------------------------------------------
# 17. Interactive shell or finish
# ---------------------------------------------------------------------------
if [[ "$DROP_SHELL" == true ]]; then
    log "Dropping into interactive shell (Ctrl-D to exit) ..."
    log "  ssh -i ${SSH_KEY} ${SSH_USER}@${VM_IP}"
    ssh "${SSH_OPTS[@]}" -t "${SSH_USER}@${VM_IP}"
fi

if [[ "$CLEANUP" != true ]]; then
    echo
    log "VM is still running.  Connect with:"
    log "  ssh -i ${SSH_KEY} ${SSH_USER}@${VM_IP}"
    log "Destroy later with:  utmctl stop ${VM_NAME} && utmctl delete ${VM_NAME}"
fi
