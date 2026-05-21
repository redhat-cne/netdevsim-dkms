#!/bin/bash
# Install the netdevsim DKMS driver package.
# Supports Ubuntu/Debian and Fedora/RHEL/CentOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DKMS_SRC="${DKMS_SRC:-$(dirname "$SCRIPT_DIR")}"
PKG_NAME="netdevsim"
PKG_VERSION="6.9.5"
DEST="/usr/src/${PKG_NAME}-${PKG_VERSION}"

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Detect OS family ─────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
else
    die "Cannot detect OS: /etc/os-release not found"
fi

case "$OS_ID" in
    ubuntu|debian|linuxmint|pop)
        OS_FAMILY="debian"
        ;;
    fedora|rhel|centos|rocky|alma)
        OS_FAMILY="redhat"
        ;;
    *)
        die "Unsupported OS: $OS_ID. Supported: ubuntu, debian, fedora, rhel, centos, rocky, alma"
        ;;
esac

echo "Detected OS: $OS_ID (family: $OS_FAMILY)"
echo "Kernel: $(uname -r)"

# ── Install prerequisites ─────────────────────────────────────────────
echo "Installing prerequisites..."
if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq dkms build-essential "linux-headers-$(uname -r)"
elif [ "$OS_FAMILY" = "redhat" ]; then
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    $PKG_MGR install -y dkms gcc make kernel-devel-"$(uname -r)" kernel-headers-"$(uname -r)" \
        || $PKG_MGR install -y dkms gcc make kernel-devel kernel-headers
fi

# ── Verify source exists ──────────────────────────────────────────────
[ -d "$DKMS_SRC" ] || die "DKMS source not found at $DKMS_SRC. Set DKMS_SRC env var."
[ -f "$DKMS_SRC/dkms.conf" ] || die "No dkms.conf in $DKMS_SRC"

# ── Remove previous installation if present ───────────────────────────
if dkms status "$PKG_NAME/$PKG_VERSION" 2>/dev/null | grep -q "$PKG_VERSION"; then
    echo "Removing previous DKMS installation..."
    dkms remove "$PKG_NAME/$PKG_VERSION" --all 2>/dev/null || true
fi
rm -rf "$DEST"

# ── Copy source to /usr/src ───────────────────────────────────────────
echo "Copying source to $DEST..."
cp -a "$DKMS_SRC" "$DEST"

# ── DKMS add / build / install ────────────────────────────────────────
echo "Running dkms add..."
dkms add "$PKG_NAME/$PKG_VERSION"

echo "Running dkms build..."
dkms build "$PKG_NAME/$PKG_VERSION"

echo "Running dkms install..."
dkms install "$PKG_NAME/$PKG_VERSION"

# ── Install udev rule ─────────────────────────────────────────────────
RULE_FILE="$DEST/99-nsim-ptp.rules"
if [ -f "$RULE_FILE" ]; then
    echo "Installing udev rule..."
    cp "$RULE_FILE" /etc/udev/rules.d/99-nsim-ptp.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=nsim_ptp 2>/dev/null || true
fi

# ── Load modules ──────────────────────────────────────────────────────
echo "Loading modules..."
modprobe -r netdevsim 2>/dev/null || true
modprobe -r nsim_ptp_mock 2>/dev/null || true
modprobe -r nsim_dpll 2>/dev/null || true
modprobe -r nsim_ptp 2>/dev/null || true

modprobe nsim_ptp
modprobe nsim_dpll
modprobe netdevsim pci_bus_nr=0x1f

# ── Verify ────────────────────────────────────────────────────────────
echo ""
echo "Verifying installation..."
echo "  Loaded modules:"
lsmod | grep -E "nsim_ptp|nsim_dpll|netdevsim" | sed 's/^/    /'
echo "  Device class:"
ls /sys/class/nsim_ptp/ 2>/dev/null | sed 's/^/    /' || echo "    (no devices yet — create netdevsim interfaces first)"
echo ""
echo "Done. netdevsim DKMS driver installed successfully."
echo ""
echo "Next steps:"
echo "  1. Create devices:  echo '1 0000:1f:01.0 0 2' > /sys/bus/netdevsim/new_device"
echo "  2. Check PTP devs:  ls -la /dev/nsim_ptp* /dev/ptp*"
