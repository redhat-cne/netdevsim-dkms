#!/bin/bash
# Install linux-modules-extra-$(uname -r) when apt has the package.
#
# gnss.ko lives in extra-modules on Azure/GHA kernels; netdevsim will not
# load without those GNSS symbols. Extra-modules is missing on some HWE
# ABIs (e.g. 7.0 generic) — skip in that case.
#
# apt is run under `sudo timeout` so a stalled 71MB fetch cannot outlive
# this script. GitHub's step timeout only kills the shell; leftover sudo
# apt-get holds /var/lib/dpkg/lock-frontend.
set -euo pipefail

extra="linux-modules-extra-$(uname -r)"
APT=(apt-get
  -o Acquire::http::Timeout=20
  -o Acquire::https::Timeout=20
  -o Acquire::Retries=2
)

recover_dpkg() {
  sudo killall -9 apt-get apt dpkg 2>/dev/null || true
  sleep 1
  sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
    /var/cache/apt/archives/lock /var/lib/apt/lists/lock
  sudo dpkg --configure -a || true
}

if ! apt-cache show "${extra}" >/dev/null 2>&1; then
  echo "${extra} not in apt — continuing (gnss may already be in linux-modules)"
  exit 0
fi

if sudo timeout --kill-after=20 240 "${APT[@]}" install -y "${extra}"; then
  exit 0
fi

echo "::error::${extra} install timed out or failed; recovering dpkg"
recover_dpkg
exit 1
