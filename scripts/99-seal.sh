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
cloud-init clean --logs --seed --machine-id || cloud-init clean --logs --seed || true

echo "==> Seal: clear network leases and resolv.conf"
rm -f /var/lib/dhcp/* 2>/dev/null || true
truncate -s 0 /etc/resolv.conf 2>/dev/null || true

sync
echo "==> 99-seal.sh complete"
