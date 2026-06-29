#!/usr/bin/env bash
#
# 10-hcs-prep.sh — Make a stock Ubuntu 24.04 cloud image satisfy the Huawei
# Cloud Stack 8.5.1 (ManageOne) private-image contract.
#
# Runs as root inside the booted build VM.
#
# Inputs (exported by Packer; safe defaults if unset):
#   NTP_SERVERS          space-separated NTP hosts (e.g. "ntp1.corp ntp2.corp").
#                        If set, the public Ubuntu pool is disabled (airgap-safe).
#   PATCH_ON_FIRST_BOOT  true|false — apply security updates on first boot.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
NTP_SERVERS="${NTP_SERVERS:-}"
PATCH_ON_FIRST_BOOT="${PATCH_ON_FIRST_BOOT:-false}"

echo "==> [1/9] Base packages cloud-init / virtio / guest agent / Pro client"
apt-get update
# cloud-init ships in the cloud image already; the rest are belt-and-braces.
# ubuntu-pro-client is kept so ESM/Livepatch/USG/FIPS can be attached later,
# matching what the stock AWS/Azure images retain.
apt-get install -y --no-install-recommends \
  cloud-init cloud-guest-utils chrony qemu-guest-agent \
  vlan ifenslave ubuntu-pro-client
# Never let autoremove strip the Pro client during the hardening trim.
apt-mark manual ubuntu-pro-client >/dev/null 2>&1 || true

systemctl enable chrony qemu-guest-agent || true
systemctl enable cloud-init cloud-init-local cloud-config cloud-final || true

echo "==> [2/9] Ensure virtio block + net drivers are in the initramfs"
# Ubuntu 24.04's kernel includes virtio, but a trimmed initramfs can omit it.
# Force-include the modules and rebuild so the VM can find its root disk/NIC
# on first boot under KVM on HCS.
cat > /etc/initramfs-tools/modules.d/virtio.conf <<'EOF'
virtio
virtio_pci
virtio_blk
virtio_scsi
virtio_net
EOF
# initramfs-tools reads /etc/initramfs-tools/modules (single file); append there too.
for m in virtio virtio_pci virtio_blk virtio_scsi virtio_net; do
  grep -qxF "$m" /etc/initramfs-tools/modules 2>/dev/null || echo "$m" >> /etc/initramfs-tools/modules
done
update-initramfs -u -k all

echo "==> [3/9] Wire cloud-init to the HCS OpenStack metadata datasource"
# Confirmed on-platform (HCS 8.5.1 / ManageOne):
#   cloud-init query subplatform -> metadata (http://169.254.169.254)
#   datasource                   -> DataSourceOpenStackLocal [net,ver=2]
# i.e. standard OpenStack metadata service at the link-local IP (this is also
# cloud-init's default OpenStack URL; pinned here for determinism). The list is
# trimmed to the sources HCS actually uses so boot doesn't probe 25 others.
cat > /etc/cloud/cloud.cfg.d/95-hcs-datasource.cfg <<'EOF'
datasource_list: [ OpenStack, ConfigDrive, NoCloud, None ]
datasource:
  OpenStack:
    metadata_urls: ['http://169.254.169.254']
    max_wait: 120
    timeout: 5
    # apply_network_config left at its default (true): the HCS datasource
    # supplies network config (observed net,ver=2) and the stock image applies
    # it, which honours both DHCP and platform-assigned static IPs.
EOF

# Small, safe settings only. We deliberately do NOT override cloud_init_modules
# wholesale (that risks silently dropping a module on a future 24.04 cloud-init).
# KEY-ONLY: ssh_pwauth:false makes cloud-init disable SSH password auth. The
# default user still gets the HCS-selected key pair injected, so instances MUST
# be launched WITH a key pair or they will be unreachable.
cat > /etc/cloud/cloud.cfg.d/96-hcs-tuning.cfg <<'EOF'
preserve_hostname: false
disable_root: false
ssh_pwauth: false
EOF

echo "==> [4/9] Networking: let cloud-init render from the HCS datasource"
# The HCS OpenStack datasource provides network config, so we let cloud-init
# apply it — same behaviour as the stock HCS image. Do NOT ship a competing
# static netplan or disable cloud-init's network rendering. (If you specifically
# want to ignore platform network config and force DHCP on all NICs instead,
# see the "Networking strategy" note in the README.)
# Clear any persistent net-naming rules so no fixed MAC->iface mapping ships.
rm -f /etc/udev/rules.d/70-persistent-net.rules \
      /etc/udev/rules.d/*persistent*net*.rules 2>/dev/null || true

echo "==> [5/9] fstab + GRUB: reference the root filesystem by UUID"
# Ubuntu's cloud image mounts root via LABEL=cloudimg-rootfs. HCS asks for UUID
# in fstab and GRUB.
ROOT_SRC="$(findmnt -no SOURCE /)"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC")"
if [ -n "$ROOT_UUID" ]; then
  sed -i "s|^LABEL=cloudimg-rootfs\s\+/\s|UUID=${ROOT_UUID} / |" /etc/fstab
  # update-grub emits root=UUID=... by default (GRUB_DISABLE_LINUX_UUID unset).
  update-grub
fi
echo "    root: ${ROOT_SRC}  UUID=${ROOT_UUID}"
cat /etc/fstab

echo "==> [6/9] Console + boot settings sane for a headless cloud VM"
# Ensure serial console output (helps HCS VNC/console debugging).
if ! grep -q "console=ttyS0" /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=tty1 console=ttyS0,115200n8"/' /etc/default/grub
  update-grub
fi

echo "==> [7/9] Time sync (chrony) — match a platform clock like AWS/Azure do"
# HCS VMs get a stable hardware clock from the KVM host (kvm-clock); chrony adds
# NTP discipline. AWS points at 169.254.169.123, Azure uses Hyper-V PTP; on HCS
# you point at your datacenter NTP. Drop-in goes in conf.d (sourced by 24.04's
# /etc/chrony/chrony.conf).
systemctl enable chrony || true
if [ -n "$NTP_SERVERS" ]; then
  {
    echo "# HCS time sources (set at image build)"
    for s in $NTP_SERVERS; do echo "server $s iburst"; done
  } > /etc/chrony/conf.d/10-hcs.conf
  # Airgap-safe: stop reaching for the public Ubuntu pool when corp NTP is set.
  sed -i 's/^pool /#pool /' /etc/chrony/chrony.conf 2>/dev/null || true
  echo "    chrony -> ${NTP_SERVERS}"
else
  echo "    NTP_SERVERS not set; leaving the default Ubuntu NTP pool in place."
  echo "    Set NTP_SERVERS to your HCS/datacenter NTP before shipping (esp. if airgapped)."
fi

echo "==> [8/9] Confirm ubuntu-pro-client present (ESM/Livepatch/USG/FIPS attach)"
if dpkg -s ubuntu-pro-client >/dev/null 2>&1; then
  echo "    ubuntu-pro-client installed and marked manual."
else
  echo "    WARN: ubuntu-pro-client missing — Pro attach (ESM/FIPS) won't work."
fi

echo "==> [9/9] Optional: apply security updates on first boot"
# Stock AWS/Azure images refresh against the archive at first boot. cloud-init's
# package_upgrade does the same, once per instance. Off by default (slows boot).
if [ "$PATCH_ON_FIRST_BOOT" = "true" ]; then
  cat > /etc/cloud/cloud.cfg.d/97-hcs-firstboot-patch.cfg <<'EOF'
package_update: true
package_upgrade: true
EOF
  echo "    first-boot patching ENABLED."
else
  rm -f /etc/cloud/cloud.cfg.d/97-hcs-firstboot-patch.cfg
  echo "    first-boot patching disabled (unattended-upgrades still covers drift)."
fi

echo "==> 10-hcs-prep.sh complete"
