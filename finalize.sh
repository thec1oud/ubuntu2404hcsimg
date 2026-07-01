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

# libguestfs (virt-customize, virt-sparsify) boots a mini appliance via supermin.
# supermin requires BOTH /dev/kvm AND the running kernel's module tree at
# /lib/modules/$(uname -r)/. In container/cloud-VM environments /dev/kvm may be
# present (QEMU uses it fine) while the host module tree is not mounted inside
# the guest, causing supermin to exit with status 1 even when KVM is available.
# Force TCG when either prerequisite is missing.
if [ ! -e /dev/kvm ] || [ ! -d "/lib/modules/$(uname -r)" ]; then
  export LIBGUESTFS_BACKEND_SETTINGS=force_tcg
  echo "==> KVM or kernel modules unavailable — using LIBGUESTFS_BACKEND_SETTINGS=force_tcg (supermin fallback)"
fi

# Ubuntu sets /boot/vmlinuz-* to mode 0600 (root-only) as a KASLR mitigation.
# supermin copies the running kernel to build its libguestfs appliance and fails
# with "Permission denied" when the caller is not root. Make a readable temp
# copy and point supermin at it via SUPERMIN_KERNEL. The copy is only used as
# the kernel for the throwaway appliance VM — it never enters the golden image.
# The temp file is removed on exit via trap.
_KERNEL="/boot/vmlinuz-$(uname -r)"
if [ -f "$_KERNEL" ] && [ ! -r "$_KERNEL" ]; then
  _TMPKERNEL="$(mktemp /tmp/vmlinuz-XXXXXX)"
  sudo cp "$_KERNEL" "$_TMPKERNEL"
  chmod 644 "$_TMPKERNEL"
  export SUPERMIN_KERNEL="$_TMPKERNEL"
  export SUPERMIN_MODULES="/lib/modules/$(uname -r)"
  # shellcheck disable=SC2064
  trap "rm -f '$_TMPKERNEL'" EXIT
  echo "==> /boot/vmlinuz is root-only — using temp copy for supermin appliance"
fi

echo "==> Removing build user and any shipped credentials"
virt-customize --no-network -a "$IMG" \
  --run-command 'deluser --remove-home packer 2>/dev/null || true' \
  --run-command 'rm -rf /home/packer' \
  --delete /etc/sudoers.d/90-cloud-init-users \
  --run-command 'rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null || true' \
  --run-command 'truncate -s 0 /etc/machine-id' \
  --run-command 'rm -f /etc/ssh/ssh_host_*' \
  --run-command 'cloud-init clean --logs --seed 2>/dev/null || true'

# --- Optional: one-click password reset agent ------------------------------
# The CloudResetPwdAgent package is specific to your HCS environment; obtain it
# from the HCS console / Service OM / OBS for 8.5.1 and VERIFY its integrity
# before use. It runs as root and enables out-of-band password reset — a
# convenience some hardened baselines deliberately omit in favour of key-only
# access. Skipping it is a valid enterprise choice.
if [ -n "$AGENT_ZIP" ] && [ -f "$AGENT_ZIP" ]; then
  echo "==> Installing one-click password reset agent from $AGENT_ZIP"
  AGENT_BASENAME="$(basename "$AGENT_ZIP")"
  virt-customize --no-network -a "$IMG" \
    --copy-in "$AGENT_ZIP:/tmp" \
    --run-command 'cd /tmp && unzip -o "'"$AGENT_BASENAME"'" -d /tmp/crpa && \
                   cd /tmp/crpa/CloudResetPwdAgent.Linux && bash setup.sh || \
                   echo "WARN: agent setup.sh path differs for your version; check the zip layout"' \
    --run-command 'rm -rf /tmp/crpa /tmp/'"$AGENT_BASENAME"
else
  echo "==> Skipping password-reset agent (none provided)"
fi

echo "==> Sparsifying image"
virt-sparsify --in-place "$IMG"

echo "==> finalize.sh complete -> $IMG"
qemu-img info "$IMG"
