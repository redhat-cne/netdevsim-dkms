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
VM_IP="$(grep -oP '(?<=VM IP: )\S+' "$LOGFILE" | tail -1 || true)"
SSH_KEY="$(grep -oP '(?<=ssh -i )\S+' "$LOGFILE" | tail -1 || true)"

if [[ -z "$VM_IP" ]]; then
    echo "WARNING: Could not extract VM IP from output. Skipping SSH config."
    exit 0
fi

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
