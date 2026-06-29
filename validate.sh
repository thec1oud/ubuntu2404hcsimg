#!/usr/bin/env bash
#
# validate.sh — Offline validation of a built HCS golden image.
#
# Inspects the qcow2 directly via libguestfs without booting it.
# Catches seal failures, missing configs, and profile mismatches before upload.
# Called automatically by 'make base|cis-l1|cis-l2'; also runnable standalone.
#
# Usage:  ./validate.sh <image.qcow2> <profile>
#         profile: base | cis-l1 | cis-l2
#
# Requires: libguestfs-tools  qemu-utils
#
set -uo pipefail

IMG="${1:?usage: validate.sh <image.qcow2> <profile>}"
PROFILE="${2:?usage: validate.sh <image.qcow2> <profile>}"

[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
NPASS=0; NFAIL=0; NWARN=0

ok()   { printf "  ${GREEN}PASS${NC}  %s\n" "$1"; NPASS=$((NPASS+1)); }
fail() { printf "  ${RED}FAIL${NC}  %s\n" "$1"; NFAIL=$((NFAIL+1)); }
warn() { printf "  ${YELLOW}WARN${NC}  %s\n" "$1"; NWARN=$((NWARN+1)); }
hdr()  { printf "\n${BOLD}%s${NC}\n" "$1"; }

# Read a guest file; always exits 0 so individual checks don't abort the script.
vcat()    { virt-cat    -a "$IMG" "$1" 2>/dev/null || true; }
# List filenames in a guest directory.
vls()     { virt-ls     -a "$IMG" "$1" 2>/dev/null || true; }
# Return 0 if path exists in the image, 1 otherwise.
vexists() { virt-cat    -a "$IMG" "$1" >/dev/null 2>&1; }
# Return the symlink target, or NOT_A_SYMLINK.
vreadlink() {
  guestfish --ro -a "$IMG" -i readlink "$1" 2>/dev/null || echo NOT_A_SYMLINK
}

printf "\n${BOLD}Validating:${NC} %s\n${BOLD}Profile:${NC}    %s\n" "$(basename "$IMG")" "$PROFILE"

# ── 1. Image integrity ────────────────────────────────────────────────────────
hdr "Image integrity"

if qemu-img check "$IMG" >/dev/null 2>&1; then
  ok "qemu-img check clean"
else
  fail "qemu-img check failed — image may be corrupt"
fi

if qemu-img info "$IMG" 2>/dev/null | grep -q 'file format: qcow2'; then
  ok "format is qcow2"
else
  fail "unexpected format (expected qcow2)"
fi

# ── 2. Seal: instance identity stripped ───────────────────────────────────────
hdr "Seal: instance identity stripped"

MACHINE_ID="$(vcat /etc/machine-id | tr -d '[:space:]')"
if [ -z "$MACHINE_ID" ]; then
  ok "machine-id is empty (regenerated per instance)"
else
  fail "machine-id not empty: '$MACHINE_ID' — seal step did not run"
fi

HOST_KEY_COUNT="$(vls /etc/ssh | grep -c '^ssh_host_' || true)"
if [ "${HOST_KEY_COUNT:-0}" -eq 0 ]; then
  ok "no SSH host keys shipped"
else
  fail "${HOST_KEY_COUNT} SSH host key file(s) found in image"
fi

if ! vexists /var/lib/cloud/instance; then
  ok "cloud-init instance state cleared"
else
  fail "/var/lib/cloud/instance still present — cloud-init state not cleaned"
fi

BASH_HIST="$(vcat /root/.bash_history | wc -c || true)"
if [ "${BASH_HIST:-0}" -eq 0 ]; then
  ok "/root/.bash_history cleared"
else
  warn "/root/.bash_history is non-empty"
fi

# ── 3. Build user removed ─────────────────────────────────────────────────────
hdr "Build user removed"

if ! vcat /etc/passwd | grep -q '^packer:'; then
  ok "packer absent from /etc/passwd"
else
  fail "packer user still present in /etc/passwd"
fi

if ! vexists /home/packer; then
  ok "/home/packer removed"
else
  fail "/home/packer still exists"
fi

ROOT_KEY_COUNT="$(vcat /root/.ssh/authorized_keys 2>/dev/null | grep -c 'ssh-' || true)"
if [ "${ROOT_KEY_COUNT:-0}" -eq 0 ]; then
  ok "no keys in /root/.ssh/authorized_keys"
else
  fail "authorized_keys found in /root — build credentials leaked"
fi

if ! vexists /etc/sudoers.d/90-cloud-init-users; then
  ok "/etc/sudoers.d/90-cloud-init-users removed"
else
  fail "90-cloud-init-users sudoers file still present"
fi

# ── 4. HCS contract ───────────────────────────────────────────────────────────
hdr "HCS contract"

MODS="$(vcat /etc/initramfs-tools/modules)"
for MOD in virtio virtio_pci virtio_blk virtio_scsi virtio_net; do
  if echo "$MODS" | grep -qxF "$MOD"; then
    ok "initramfs includes $MOD"
  else
    fail "initramfs missing module: $MOD"
  fi
done

FSTAB_ROOT="$(vcat /etc/fstab | grep -E '\s/\s')"
if echo "$FSTAB_ROOT" | grep -qE '^UUID='; then
  ok "fstab root uses UUID"
else
  fail "fstab root is not UUID-based: ${FSTAB_ROOT:-<not found>}"
fi

if vcat /etc/cloud/cloud.cfg.d/95-hcs-datasource.cfg | grep -q 'OpenStack'; then
  ok "cloud-init datasource pinned to OpenStack"
else
  fail "95-hcs-datasource.cfg missing or does not list OpenStack"
fi

if vcat /etc/cloud/cloud.cfg.d/96-hcs-tuning.cfg | grep -q 'ssh_pwauth: false'; then
  ok "cloud-init ssh_pwauth: false"
else
  fail "ssh_pwauth not disabled in 96-hcs-tuning.cfg"
fi

if vexists /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service; then
  ok "qemu-guest-agent enabled"
else
  warn "qemu-guest-agent not in multi-user.target.wants — verify it is enabled"
fi

if vexists /etc/systemd/system/multi-user.target.wants/chrony.service; then
  ok "chrony enabled"
else
  warn "chrony not in multi-user.target.wants"
fi

# ── 5. DNS ────────────────────────────────────────────────────────────────────
hdr "DNS (systemd-resolved)"

if vcat /etc/systemd/resolved.conf.d/10-hcs-fallback.conf | grep -qE '^DNS='; then
  DNS_LINE="$(vcat /etc/systemd/resolved.conf.d/10-hcs-fallback.conf | grep '^DNS=')"
  ok "10-hcs-fallback.conf: $DNS_LINE"
else
  fail "10-hcs-fallback.conf missing or has no DNS= line"
fi

RESOLV_TARGET="$(vreadlink /etc/resolv.conf)"
if [ "$RESOLV_TARGET" = "/run/systemd/resolve/stub-resolv.conf" ]; then
  ok "/etc/resolv.conf → stub-resolv.conf"
else
  fail "/etc/resolv.conf is not the expected symlink (got: $RESOLV_TARGET)"
fi

# ── 6. Provenance ─────────────────────────────────────────────────────────────
hdr "Provenance (/etc/hcs-image-build.txt)"

BUILD_TXT="$(vcat /etc/hcs-image-build.txt)"
if echo "$BUILD_TXT" | grep -q "hardening_profile: ${PROFILE}"; then
  ok "in-image profile matches: $PROFILE"
else
  FOUND="$(echo "$BUILD_TXT" | grep hardening_profile || echo '<missing>')"
  fail "profile mismatch — expected $PROFILE, found: $FOUND"
fi

if echo "$BUILD_TXT" | grep -qE '^base_image_sha256: [0-9a-f]{64}$'; then
  ok "base_image_sha256 stamped"
else
  fail "base_image_sha256 missing or not a 64-char hex string"
fi

GIT_COMMIT="$(echo "$BUILD_TXT" | grep '^git_commit:' | awk '{print $2}')"
if [ "$GIT_COMMIT" = "nogit" ] || [ -z "$GIT_COMMIT" ]; then
  warn "git_commit is '$GIT_COMMIT' — build was not run via make"
else
  ok "git_commit stamped: $GIT_COMMIT"
fi

# ── 7. Hardening: cis-l1 and cis-l2 ─────────────────────────────────────────
if [ "$PROFILE" != "base" ]; then

  hdr "Hardening: SSH ($PROFILE)"

  SSH_CONF="$(vcat /etc/ssh/sshd_config.d/80-hcs-hardening.conf)"
  if echo "$SSH_CONF" | grep -q 'PasswordAuthentication no'; then
    ok "PasswordAuthentication no"
  else
    fail "PasswordAuthentication not disabled in 80-hcs-hardening.conf"
  fi

  if echo "$SSH_CONF" | grep -q 'KexAlgorithms'; then
    ok "KexAlgorithms restricted"
  else
    fail "KexAlgorithms not restricted in SSH hardening config"
  fi

  if echo "$SSH_CONF" | grep -q 'MaxAuthTries 3'; then
    ok "MaxAuthTries 3"
  else
    fail "MaxAuthTries not set to 3"
  fi

  if echo "$SSH_CONF" | grep -q 'X11Forwarding no'; then
    ok "X11Forwarding no"
  else
    fail "X11Forwarding not disabled"
  fi

  hdr "Hardening: auditd ($PROFILE)"

  if vexists /etc/audit/rules.d/80-hcs.rules; then
    ok "80-hcs.rules present"
  else
    fail "80-hcs.rules missing"
  fi

  IMMUTABLE="$(vcat /etc/audit/rules.d/99-immutable.rules | tr -d '[:space:]')"
  if [ "$IMMUTABLE" = "-e2" ]; then
    ok "99-immutable.rules: -e 2 (immutable, loads last)"
  else
    fail "99-immutable.rules missing or malformed: '${IMMUTABLE}'"
  fi

  hdr "Hardening: sysctl ($PROFILE)"

  if vcat /etc/sysctl.d/80-hcs-hardening.conf | grep -q 'kernel.randomize_va_space = 2'; then
    ok "80-hcs-hardening.conf present"
  else
    fail "80-hcs-hardening.conf missing or does not set ASLR"
  fi

  hdr "Hardening: AppArmor ($PROFILE)"

  if vexists /etc/systemd/system/multi-user.target.wants/apparmor.service; then
    ok "AppArmor enabled (in multi-user.target.wants)"
  else
    fail "AppArmor not enabled — H7 step may have failed"
  fi

  hdr "Hardening: module blacklist ($PROFILE)"

  if vexists /etc/modprobe.d/80-hcs-blacklist.conf; then
    ok "80-hcs-blacklist.conf present (H3: unused fs/proto modules)"
  else
    fail "80-hcs-blacklist.conf missing — H3 module blacklist not applied"
  fi

  hdr "Hardening: core dumps ($PROFILE)"

  if vexists /etc/security/limits.d/80-hcs-nocore.conf; then
    ok "80-hcs-nocore.conf present (H6: hard core 0)"
  else
    fail "80-hcs-nocore.conf missing — H6 core dump limit not applied"
  fi

  hdr "Hardening: PAM / login ($PROFILE)"

  if vexists /etc/security/pwquality.conf.d/80-hcs.conf; then
    ok "pwquality config present (minlen=14 etc.)"
  else
    fail "80-hcs.conf (pwquality) missing"
  fi

  if vcat /etc/security/faillock.conf | grep -q 'deny = 5'; then
    ok "faillock deny=5"
  else
    fail "faillock.conf missing or deny not set to 5"
  fi

  if vcat /etc/login.defs | grep -q 'UMASK.*027'; then
    ok "login.defs UMASK 027"
  else
    fail "UMASK not set to 027 in login.defs"
  fi

  hdr "Hardening: unattended-upgrades ($PROFILE)"

  if vexists /etc/apt/apt.conf.d/52-hcs-unattended; then
    ok "52-hcs-unattended present"
  else
    fail "52-hcs-unattended missing"
  fi

  hdr "Hardening: AIDE ($PROFILE)"

  if vexists /etc/systemd/system/hcs-aide-init.service; then
    ok "hcs-aide-init.service present"
  else
    fail "hcs-aide-init.service missing"
  fi

fi

# ── 8. L2-specific ───────────────────────────────────────────────────────────
if [ "$PROFILE" = "cis-l2" ]; then

  hdr "Hardening: L2 controls"

  if vcat /etc/sysctl.d/81-hcs-l2.conf | grep -q 'net.ipv4.ip_forward = 0'; then
    ok "L2 sysctl: ip_forward=0"
  else
    fail "81-hcs-l2.conf missing or ip_forward not set to 0"
  fi

  if vexists /etc/audit/rules.d/81-hcs-l2.rules; then
    ok "81-hcs-l2.rules present"
  else
    fail "81-hcs-l2.rules missing"
  fi

  if vexists /etc/ssh/sshd_config.d/81-hcs-l2.conf; then
    ok "SSH L2 drop-in (81-hcs-l2.conf) present"
  else
    fail "81-hcs-l2.conf (SSH) missing"
  fi

  if vexists /etc/systemd/system/hcs-aide-check.timer; then
    ok "hcs-aide-check.timer present"
  else
    fail "hcs-aide-check.timer missing"
  fi

  BANNER="$(vcat /etc/issue.net | tr -d '[:space:]')"
  if [ -n "$BANNER" ]; then
    ok "login banner set in /etc/issue.net"
  else
    fail "/etc/issue.net is empty — L2 banner step did not run"
  fi

  if vcat /etc/sysctl.d/81-hcs-l2.conf | grep -q 'kernel.apparmor_restrict_unprivileged_userns = 1'; then
    ok "L2 sysctl: unprivileged userns restricted"
  else
    fail "apparmor_restrict_unprivileged_userns not set in 81-hcs-l2.conf"
  fi

fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}Results:${NC}  ${GREEN}%d passed${NC}" "$NPASS"
[ "$NWARN" -gt 0 ] && printf "  ${YELLOW}%d warnings${NC}" "$NWARN"
[ "$NFAIL" -gt 0 ] && printf "  ${RED}%d failed${NC}" "$NFAIL"
printf "\n\n"

if [ "$NFAIL" -gt 0 ]; then
  echo "Image did NOT pass offline validation. Do not upload to HCS."
  exit 1
fi

echo "Image passed offline validation. Deploy a test instance and run:"
echo "  ssh ubuntu@<ip> 'bash -s' < scripts/validate-instance.sh"
