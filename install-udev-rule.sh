#!/bin/bash
# POST_INSTALL hook for DKMS: install the nsim_ptp udev device-node rule.
set -e

RULE_SRC="${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/source/99-nsim-ptp.rules"
RULE_DST="/etc/udev/rules.d/99-nsim-ptp.rules"

if [ -f "$RULE_SRC" ]; then
    cp "$RULE_SRC" "$RULE_DST"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=nsim_ptp 2>/dev/null || true
fi
