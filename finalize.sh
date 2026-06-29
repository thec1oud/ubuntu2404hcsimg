#!/usr/bin/env bash
#
# finalize.sh — Offline post-processing of the golden qcow2.
#   • removes the build-time 'packer' user and its credentials
#   • (optional) installs YOUR HCS one-click password-reset agent
#   • final identity scrub + sparsify to shrink the upload
#
# Usage:
#   ./finalize.sh output/ubuntu-2404-hcs.qcow2 [/path/to/CloudResetPwdAgent.zip]
#
# Requires: libguestfs-tools  (sudo apt-get install -y libguestfs-tools)
#
set -euo pipefail

IMG="${1:?usage: finalize.sh <image.qcow2> [CloudResetPwdAgent.zip]}"
AGENT_ZIP="${2:-}"

echo "==> Removing build user and any shipped credentials"
virt-customize -a "$IMG" \
  --run-command 'deluser --remove-home packer 2>/dev/null || true' \
  --run-command 'rm -rf /home/packer' \
  --delete /etc/sudoers.d/90-cloud-init-users \
  --run-command 'rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null || true' \
  --run-command 'truncate -s 0 /etc/machine-id' \
  --run-command 'rm -f /etc/ssh/ssh_host_*' \
  --run-command 'cloud-init clean --logs --seed --machine-id 2>/dev/null || true'

# --- Optional: one-click password reset agent ------------------------------
# The CloudResetPwdAgent package is specific to your HCS environment; obtain it
# from the HCS console / Service OM / OBS for 8.5.1 and VERIFY its integrity
# before use. It runs as root and enables out-of-band password reset — a
# convenience some hardened baselines deliberately omit in favour of key-only
# access. Skipping it is a valid enterprise choice.
if [ -n "$AGENT_ZIP" ] && [ -f "$AGENT_ZIP" ]; then
  echo "==> Installing one-click password reset agent from $AGENT_ZIP"
  virt-customize -a "$IMG" \
    --copy-in "$AGENT_ZIP:/tmp" \
    --run-command 'cd /tmp && unzip -o "$(basename '"$AGENT_ZIP"')" -d /tmp/crpa && \
                   cd /tmp/crpa/CloudResetPwdAgent.Linux && bash setup.sh || \
                   echo "WARN: agent setup.sh path differs for your version; check the zip layout"' \
    --run-command 'rm -rf /tmp/crpa /tmp/CloudResetPwdAgent.zip'
else
  echo "==> Skipping password-reset agent (none provided)"
fi

echo "==> Sparsifying image"
virt-sparsify --in-place "$IMG"

echo "==> finalize.sh complete -> $IMG"
qemu-img info "$IMG"
