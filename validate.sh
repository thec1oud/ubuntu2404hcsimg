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

# libguestfs (virt-cat, virt-ls, guestfish) boots a mini appliance via supermin.
# supermin requires BOTH /dev/kvm AND the running kernel's module tree at
# /lib/modules/$(uname -r)/. Force TCG when either is missing so virt-* calls
# succeed in containers/cloud-VMs where /dev/kvm is present but the module tree
# is not mounted (QEMU can use KVM; supermin cannot).
if [ ! -e /dev/kvm ] || [ ! -d "/lib/modules/$(uname -r)" ]; then
  export LIBGUESTFS_BACKEND_SETTINGS=force_tcg
fi

# Ubuntu sets /boot/vmlinuz-* to mode 0600 (root-only) as a KASLR mitigation.
# supermin needs to read the running kernel to build its appliance and fails with
# "Permission denied" for non-root callers. Make a readable temp copy via sudo
# when needed and point supermin at it. The copy is only used for the throwaway
# appliance VM — it never enters the golden image. Cleaned up on exit via trap.
_KERNEL="/boot/vmlinuz-$(uname -r)"
if [ -f "$_KERNEL" ] && [ ! -r "$_KERNEL" ]; then
  _TMPKERNEL="$(mktemp /tmp/vmlinuz-XXXXXX)"
  if sudo cp "$_KERNEL" "$_TMPKERNEL" 2>/dev/null && chmod 644 "$_TMPKERNEL"; then
    export SUPERMIN_KERNEL="$_TMPKERNEL"
    export SUPERMIN_MODULES="/lib/modules/$(uname -r)"
    # shellcheck disable=SC2064
    trap "rm -f '$_TMPKERNEL'" EXIT
  else
    rm -f "$_TMPKERNEL" 2>/dev/null || true
  fi
fi

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

SSH_LS="$(virt-ls -a "$IMG" /etc/ssh 2>/dev/null)"
if [ $? -ne 0 ]; then
  fail "could not list /etc/ssh in image — libguestfs error"
else
  HOST_KEY_COUNT="$(echo "$SSH_LS" | grep -c '^ssh_host_' || true)"
  if [ "${HOST_KEY_COUNT:-0}" -eq 0 ]; then
    ok "no SSH host keys shipped"
  else
    fail "${HOST_KEY_COUNT} SSH host key file(s) found in image"
  fi
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

if vcat /etc/cloud/cloud.cfg.d/96-hcs-tuning.cfg | grep -qE 'name:\s*ubuntu'; then
  ok "cloud-init default_user: ubuntu"
else
  fail "96-hcs-tuning.cfg does not pin default_user name to ubuntu"
fi

if vexists /etc/ssh/sshd_config.d/75-hcs-root.conf; then
  ROOT_CONF="$(vcat /etc/ssh/sshd_config.d/75-hcs-root.conf)"
  if echo "$ROOT_CONF" | grep -qE '^PermitRootLogin (no|prohibit-password)$'; then
    ok "75-hcs-root.conf: $(echo "$ROOT_CONF" | grep '^PermitRootLogin')"
  else
    fail "75-hcs-root.conf has unexpected PermitRootLogin value"
  fi
else
  fail "75-hcs-root.conf missing — root SSH policy not set"
fi

# qemu-guest-agent is device-activated on Ubuntu 24.04: it has no [Install]
# WantedBy=multi-user.target section; instead it BindsTo the virtio-serial port
# device unit and starts automatically when that device appears at runtime.
# "systemctl enable" is therefore a no-op (the unit is "static"). Check for the
# binary instead — presence proves the package is installed and the agent will
# start on HCS where the virtio-ports device is always present.
if vexists /usr/sbin/qemu-ga; then
  ok "qemu-guest-agent installed (/usr/sbin/qemu-ga) — starts via device activation"
else
  fail "qemu-guest-agent binary missing — package was not installed"
fi

if vexists /etc/systemd/system/multi-user.target.wants/chrony.service; then
  ok "chrony enabled"
else
  warn "chrony not in multi-user.target.wants"
fi

if vcat /etc/modules-load.d/hcs-watchdog.conf | grep -qxF 'i6300esb'; then
  ok "i6300esb in modules-load.d/hcs-watchdog.conf"
else
  fail "hcs-watchdog.conf missing or does not load i6300esb"
fi

if vcat /etc/watchdog.conf | grep -qE '^\s*watchdog-device\s*='; then
  ok "/etc/watchdog.conf present with active watchdog-device directive"
else
  fail "/etc/watchdog.conf missing or watchdog-device is commented out"
fi

if vexists /etc/systemd/system/watchdog.service.d/hcs-condition.conf; then
  ok "watchdog.service.d/hcs-condition.conf present"
else
  fail "watchdog.service.d/hcs-condition.conf missing"
fi

if vexists /etc/systemd/system/default.target.wants/watchdog.service; then
  ok "watchdog.service enabled (default.target.wants)"
else
  fail "watchdog.service not enabled — symlink missing from default.target.wants"
fi

# ── 4b. Netplan fallback ──────────────────────────────────────────────────────
hdr "Netplan fallback"

if vexists /etc/netplan/99-hcs-fallback.yaml; then
  NETPLAN_FALLBACK="$(vcat /etc/netplan/99-hcs-fallback.yaml)"
  if echo "$NETPLAN_FALLBACK" | grep -q 'dhcp4: true' && \
     echo "$NETPLAN_FALLBACK" | grep -q 'name: "en\*"'; then
    ok "99-hcs-fallback.yaml present with en* DHCP bootstrap"
  else
    fail "99-hcs-fallback.yaml present but dhcp4 or en* match is missing"
  fi
else
  fail "99-hcs-fallback.yaml missing — first-boot NIC bootstrap will not work"
fi

if vexists /etc/netplan/10-hcs-fallback.yaml; then
  fail "stale 10-hcs-fallback.yaml present — its networkd unit sorts before cloud-init's 50-netplan-*.network and will permanently suppress HCS platform networking"
fi

# ── 5. DNS ────────────────────────────────────────────────────────────────────
hdr "DNS (systemd-resolved)"

FALLBACK_CONF="$(vcat /etc/systemd/resolved.conf.d/10-hcs-fallback.conf)"
DNS_LINE="$(echo "$FALLBACK_CONF" | grep '^DNS=')"
if [ -n "$DNS_LINE" ]; then
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

  if vcat /etc/audit/rules.d/99-immutable.rules | grep -qxF -- '-e 2'; then
    ok "99-immutable.rules: -e 2 (immutable, loads last)"
  else
    fail "99-immutable.rules missing or does not contain '-e 2'"
  fi

  hdr "Hardening: sysctl ($PROFILE)"

  if vcat /etc/sysctl.d/80-hcs-hardening.conf | grep -q 'kernel.randomize_va_space = 2'; then
    ok "80-hcs-hardening.conf present"
  else
    fail "80-hcs-hardening.conf missing or does not set ASLR"
  fi

  hdr "Hardening: AppArmor ($PROFILE)"

  if vexists /etc/systemd/system/sysinit.target.wants/apparmor.service; then
    ok "AppArmor enabled (in sysinit.target.wants)"
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

  if vcat /etc/security/faillock.conf | grep -vE '^\s*#' | grep -qE '^deny\s*=\s*5'; then
    ok "faillock deny=5"
  else
    fail "faillock.conf missing or deny not set to 5"
  fi

  if vcat /etc/login.defs | grep -vE '^\s*#' | grep -qE '^UMASK[[:space:]].*027'; then
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
