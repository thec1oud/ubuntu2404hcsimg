#!/usr/bin/env bash
#
# 99-seal.sh — Strip instance identity and build residue so every HCS instance
# created from the golden image is unique and clean.
#
# NOTE: the build user ('packer') is intentionally NOT removed here — we are
# logged in as it. finalize.sh removes it offline after power-off.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> Seal: stamp in-image build provenance (/etc/hcs-image-build.txt)"
# Lets you tell on HCS which SKU/commit an instance came from, and reproduce it.
cat > /etc/hcs-image-build.txt <<EOF
image: ubuntu-2404-hcs
hardening_profile: ${IMAGE_PROFILE:-unknown}
git_commit: ${GIT_SHA:-unknown}
base_image_sha256: ${BASE_SHA:-unknown}
built_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 644 /etc/hcs-image-build.txt

echo "==> Seal: apt + tmp cleanup"
apt-get -y autoremove --purge || true
apt-get -y clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/*

echo "==> Seal: truncate logs"
find /var/log -type f -exec truncate -s 0 {} \; || true
rm -f /var/log/*.gz /var/log/*.[0-9] /var/log/*-???????? 2>/dev/null || true

echo "==> Seal: remove SSH host keys (regenerated on first boot)"
rm -f /etc/ssh/ssh_host_*
# Ensure regeneration service is active on 24.04.
systemctl enable ssh || true

echo "==> Seal: reset machine-id (unique per instance)"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "==> Seal: clear histories and seed-injected creds residue"
rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/instance 2>/dev/null || true

echo "==> Seal: cloud-init clean so it re-runs fresh on HCS"
cloud-init clean --logs --seed || true

echo "==> Seal: generalize network configuration for hardware-agnostic boot"

# 1. Remove all DHCP lease caches.
#    Ubuntu 24.04 cloud images use systemd-networkd (not dhclient), so the
#    actionable leases are in /var/lib/systemd/network/; /var/lib/dhcp/ is kept
#    for completeness in case dhclient is ever installed.
rm -f /var/lib/dhcp/* 2>/dev/null || true
rm -f /var/lib/systemd/network/*.lease 2>/dev/null || true
# NetworkManager (if present)
rm -f /var/lib/NetworkManager/*.lease \
      /var/lib/NetworkManager/internal-*.conf 2>/dev/null || true
# Persistent NM connection profiles carry MAC addresses and interface names.
# Remove them so the new instance is not biased toward the build NIC.
rm -rf /etc/NetworkManager/system-connections/ 2>/dev/null || true

# 2. Remove build-time Netplan configs.
#    cloud-init renders /etc/netplan/50-cloud-init.yaml during the Packer build
#    pinned to the build VM's interface name (e.g. enp1s0) or MAC.  On an HCS
#    instance the hypervisor assigns a new virtio NIC at a different PCI slot
#    (e.g. enp4s3) with a new MAC, so that stale config matches nothing, the
#    interface is never given a DHCP lease, and the instance is unreachable.
#    cloud-init clean does NOT remove rendered /etc/netplan/ files, so we must
#    do it explicitly here.
rm -f /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null || true

# 3. Write a hardware-agnostic DHCP fallback Netplan.
#    Matches any Ethernet interface whose name starts with "en" (covers enp*, ens*,
#    eno* — every virtio NIC naming scheme used by HCS).  No MAC and no fixed name
#    are referenced, so it works regardless of which PCI slot or MAC the hypervisor
#    assigns.  This breaks the chicken-and-egg deadlock: the NIC gets a DHCP lease
#    on first boot, cloud-init can then reach the HCS OpenStack metadata service
#    (169.254.169.254), and its rendered 50-cloud-init.yaml is then applied.
#
#    NAMING: the file is intentionally named 99-hcs-fallback.yaml.  Netplan names
#    the generated systemd-networkd unit after the YAML file's numeric prefix
#    (e.g. 99-netplan-any-eth.network).  systemd-networkd applies the first
#    alphabetical match per interface and ignores all later ones.  Because
#    cloud-init renders 50-cloud-init.yaml, its unit (50-netplan-*.network) sorts
#    BEFORE the fallback (99-netplan-any-eth.network) and wins once cloud-init has
#    run.  On the very first boot (before cloud-init renders its config) only the
#    fallback unit exists, so the NIC gets a DHCP lease and cloud-init can proceed.
mkdir -p /etc/netplan
cat > /etc/netplan/99-hcs-fallback.yaml <<'NETPLAN'
network:
  version: 2
  ethernets:
    any-eth:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
NETPLAN
chmod 600 /etc/netplan/99-hcs-fallback.yaml

echo "==> Seal: restore resolv.conf symlink"
# Restore the canonical symlink — truncating would corrupt systemd-resolved's
# stub file, and a stale regular file would shadow the FallbackDNS config.
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sync
echo "==> 99-seal.sh complete"
