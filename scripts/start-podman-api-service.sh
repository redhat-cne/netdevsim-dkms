#!/bin/bash
# Run all podman CLI invocations through a single API server.
#
# Kind fires parallel `podman exec` during "Writing configuration". Each
# daemonless podman process locks the shared libpod SQLite DB; concurrent
# execs into systemd (kindest/node) containers deadlock (futex_wait). A
# single `podman system service` serializes DB access like dockerd does.
#
# Usage: start-podman-api-service.sh
# Idempotent. Safe to call from CI after overlay config / before Kind.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

SOCK="${PODMAN_API_SOCK:-unix:///run/podman/podman.sock}"
SOCK_PATH="${SOCK#unix://}"
# Dedicated dir so we never overwrite the real podman binary (kubic may
# install it at /usr/local/bin/podman → ETXTBSY if we try to replace it).
WRAP_DIR="${PODMAN_WRAP_DIR:-/usr/local/ptp-podman-wrap}"
WRAPPER="${WRAP_DIR}/podman"

mkdir -p "$(dirname "${SOCK_PATH}")" "${WRAP_DIR}"

# Resolve the real binary before we put our wrapper ahead on PATH.
REAL_PODMAN="${REAL_PODMAN:-}"
if [[ -z "${REAL_PODMAN}" ]]; then
  for candidate in /usr/bin/podman /usr/local/bin/podman; do
    if [[ -x "${candidate}" && "${candidate}" != "${WRAPPER}" ]]; then
      # Skip if this path is already our wrapper script.
      if head -n1 "${candidate}" 2>/dev/null | grep -q '^#!'; then
        if grep -q 'start-podman-api-service' "${candidate}" 2>/dev/null; then
          continue
        fi
      fi
      REAL_PODMAN="${candidate}"
      break
    fi
  done
fi
if [[ -z "${REAL_PODMAN}" || ! -x "${REAL_PODMAN}" ]]; then
  echo "ERROR: could not find real podman binary"
  exit 1
fi
echo "Using real podman binary: ${REAL_PODMAN}"

# Prefer systemd socket (podman.socket) when present; else start a service.
if [[ -S "${SOCK_PATH}" ]] && "${REAL_PODMAN}" --remote --url "${SOCK}" info >/dev/null 2>&1; then
  echo "podman API already up at ${SOCK}"
else
  # Try enabling the packaged socket first.
  systemctl enable --now podman.socket 2>/dev/null || true
  sleep 0.5
fi

if ! "${REAL_PODMAN}" --remote --url "${SOCK}" info >/dev/null 2>&1; then
  rm -f "${SOCK_PATH}"
  "${REAL_PODMAN}" system service --time=0 "${SOCK}" >/var/log/podman-api-service.log 2>&1 &
  echo $! >/run/podman-api-service.pid
  echo "Started podman system service pid=$(cat /run/podman-api-service.pid) sock=${SOCK}"

  for _ in $(seq 1 50); do
    if [[ -S "${SOCK_PATH}" ]] && "${REAL_PODMAN}" --remote --url "${SOCK}" info >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
fi

if ! "${REAL_PODMAN}" --remote --url "${SOCK}" info >/dev/null 2>&1; then
  echo "ERROR: podman API failed to become ready"
  tail -n 50 /var/log/podman-api-service.log || true
  systemctl status podman.socket podman.service 2>&1 | head -40 || true
  exit 1
fi

# Atomic replace of wrapper (never overwrite /usr/bin or /usr/local/bin/podman).
tmp="$(mktemp "${WRAP_DIR}/podman.XXXXXX")"
cat >"${tmp}" <<EOF
#!/bin/bash
# Installed by scripts/start-podman-api-service.sh — do not edit.
exec ${REAL_PODMAN} --remote --url ${SOCK} "\$@"
EOF
chmod 755 "${tmp}"
mv -f "${tmp}" "${WRAPPER}"

echo "podman wrapper: ${WRAPPER} -> ${REAL_PODMAN} --remote --url ${SOCK}"
echo "Prepend ${WRAP_DIR} to PATH so Kind/CI use the remote client."
# Smoke-test via the wrapper itself.
PATH="${WRAP_DIR}:${PATH}" "${WRAPPER}" info --format 'API ok GraphDriver={{.Store.GraphDriverName}}' \
  || PATH="${WRAP_DIR}:${PATH}" "${WRAPPER}" info | head -n 20
