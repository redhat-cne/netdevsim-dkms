#!/bin/bash
#
# Set up a UTM VM with the netdevsim DKMS modules installed and loaded,
# without running any tests.  Adds an SSH config entry so you can
# connect with just:  ssh <vm-name>
#
# Delegates to test-utm-ubuntu.sh --skip-tests for the heavy lifting.
#
# Usage:
#   ./scripts/setup-utm-ubuntu.sh [options]
#
# Options:
#   --release 22.04|24.04 Ubuntu release             (default: 24.04)
#   --ssh-key PATH        SSH private key for VM      (auto-detected)
#   --vm-name NAME        UTM VM name                 (default: netdevsim-ubuntu-test)
#   --ram MiB             RAM in MiB                  (default: 16384)
#   --cpus N              CPU cores                   (default: 4)
#   --disk-size SIZE      qemu-img resize target      (default: 40G)
#   --cleanup             Delete VM and remove SSH config entry
#   --shell               Drop into an interactive SSH shell after setup
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CONFIG="${HOME}/.ssh/config"

# ---------------------------------------------------------------------------
# Parse --vm-name and --cleanup from args (needed before delegation)
# ---------------------------------------------------------------------------
VM_NAME="netdevsim-ubuntu-test"
CLEANUP=false
ARGS=("$@")

i=0
while (( i < ${#ARGS[@]} )); do
    case "${ARGS[$i]}" in
        --vm-name)
            (( i+1 < ${#ARGS[@]} )) && VM_NAME="${ARGS[$((i+1))]}"
            ;;
        --cleanup)
            CLEANUP=true
            ;;
    esac
    (( i++ )) || true
done

MARKER_BEGIN="# --- netdevsim-dkms managed: ${VM_NAME} ---"
MARKER_END="# --- end netdevsim-dkms: ${VM_NAME} ---"

# ---------------------------------------------------------------------------
# Helper: remove the fenced SSH config block for VM_NAME
# ---------------------------------------------------------------------------
remove_ssh_config_entry() {
    [[ -f "$SSH_CONFIG" ]] || return 0
    if grep -qF "$MARKER_BEGIN" "$SSH_CONFIG"; then
        local tmp
        tmp="$(mktemp)"
        awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip
        ' "$SSH_CONFIG" > "$tmp"
        mv "$tmp" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
        echo "==> Removed SSH config entry for '${VM_NAME}'."
    fi
}

# ---------------------------------------------------------------------------
# Guard: check for existing SSH config entry
# ---------------------------------------------------------------------------
if [[ -f "$SSH_CONFIG" ]] && grep -qF "$MARKER_BEGIN" "$SSH_CONFIG"; then
    echo "WARNING: ${SSH_CONFIG} already has an entry for '${VM_NAME}'."
    read -r -p "Remove the old entry and continue? [y/N] " answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            remove_ssh_config_entry
            ;;
        *)
            echo "Aborting.  Pick a different name:"
            echo "  $0 --vm-name <new-name> ${ARGS[*]:-}"
            exit 1
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Cleanup-only mode: remove SSH config + delegate --cleanup
# ---------------------------------------------------------------------------
if [[ "$CLEANUP" == true ]]; then
    remove_ssh_config_entry
    exec "${SCRIPT_DIR}/test-utm-ubuntu.sh" "${ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Delegate to test-utm-ubuntu.sh --skip-tests, capturing output for IP
# ---------------------------------------------------------------------------
LOGFILE="$(mktemp)"
trap 'rm -f "$LOGFILE"' EXIT

echo "==> Setting up UTM VM '${VM_NAME}' with DKMS (no tests) ..."

"${SCRIPT_DIR}/test-utm-ubuntu.sh" --skip-tests "${ARGS[@]}" 2>&1 | tee "$LOGFILE"
TEST_RC=${PIPESTATUS[0]}

if [[ $TEST_RC -ne 0 ]]; then
    echo "ERROR: test-utm-ubuntu.sh exited with code ${TEST_RC}."
    exit "$TEST_RC"
fi

# ---------------------------------------------------------------------------
# Extract VM IP and SSH key from test-utm-ubuntu.sh output
# ---------------------------------------------------------------------------
VM_IP="$(grep 'VM IP: ' "$LOGFILE" | awk '{for(i=1;i<=NF;i++) if($(i-1)=="IP:") print $i}' | tail -1 || true)"
SSH_KEY="$(grep 'ssh -i ' "$LOGFILE" | awk '{for(i=1;i<=NF;i++) if($i=="-i") {print $(i+1); exit}}' | tail -1 || true)"

if [[ -z "$VM_IP" ]]; then
    echo "WARNING: Could not extract VM IP from output. Skipping SSH config."
    exit 0
fi

# ---------------------------------------------------------------------------
# Install test dependencies (but not the test repo itself)
# ---------------------------------------------------------------------------
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
vm_ssh() { ssh "${SSH_OPTS[@]}" "ubuntu@${VM_IP}" "$@"; }

echo "==> Installing test dependencies on VM ..."
vm_ssh sudo bash <<'DEPS'
set -euo pipefail

apt-get update -qq
apt-get install -y -qq podman pciutils uidmap slirp4netns openvswitch-switch \
    git ethtool linuxptp 2>&1 | tail -5

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

# Go
GO_VERSION=$(curl -s https://go.dev/VERSION?m=text | head -n 1)
curl -fsSLo /tmp/go.tar.gz "https://go.dev/dl/${GO_VERSION}.linux-${GOARCH}.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz

# helm
curl -fsSL "https://get.helm.sh/helm-v3.17.3-linux-${GOARCH}.tar.gz" | tar -C /tmp -xzf -
mv "/tmp/linux-${GOARCH}/helm" /usr/local/bin/helm

# PATH for root and ubuntu
for RC in /root/.bashrc /home/ubuntu/.bashrc; do
    grep -q /usr/local/go/bin "$RC" 2>/dev/null || \
        echo 'export PATH=$PATH:$HOME/go/bin:/usr/local/go/bin' >> "$RC"
done

# inotify limits (kind needs these)
sysctl -w fs.inotify.max_user_instances=512
sysctl -w fs.inotify.max_user_watches=524288

# ginkgo (test runner)
export PATH=/usr/local/go/bin:/root/go/bin:$PATH
go install github.com/onsi/ginkgo/v2/ginkgo@latest

echo "--- Verification ---"
podman --version
kind version
kubectl version --client 2>/dev/null | head -1
go version
helm version --short
ovs-vsctl --version | head -1
ginkgo version
DEPS
echo "==> Test dependencies installed."

# ---------------------------------------------------------------------------
# Add SSH config entry
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$SSH_CONFIG")"
[[ -f "$SSH_CONFIG" ]] || touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Ensure a trailing newline before our block
[[ -s "$SSH_CONFIG" && "$(tail -c1 "$SSH_CONFIG")" != "" ]] && echo >> "$SSH_CONFIG"

cat >> "$SSH_CONFIG" <<EOF
${MARKER_BEGIN}
Host ${VM_NAME}
    HostName ${VM_IP}
    User ubuntu
    IdentityFile ${SSH_KEY}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
${MARKER_END}
EOF

echo ""
echo "==> SSH config entry added.  Connect with:"
echo "    ssh ${VM_NAME}"
