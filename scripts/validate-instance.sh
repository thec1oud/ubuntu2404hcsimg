#!/usr/bin/env bash
#
# validate-instance.sh — On-instance validation after deploying to HCS.
#
# Run on a freshly deployed test instance before publishing the image:
#   ssh ubuntu@<ip> 'bash -s' < scripts/validate-instance.sh
#
# Auto-detects the hardening profile from /etc/hcs-image-build.txt.
# Some checks require sudo; the default ubuntu user has passwordless sudo.
#
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
NPASS=0; NFAIL=0; NWARN=0

ok()   { printf "  ${GREEN}PASS${NC}  %s\n" "$1"; NPASS=$((NPASS+1)); }
fail() { printf "  ${RED}FAIL${NC}  %s\n" "$1"; NFAIL=$((NFAIL+1)); }
warn() { printf "  ${YELLOW}WARN${NC}  %s\n" "$1"; NWARN=$((NWARN+1)); }
hdr()  { printf "\n${BOLD}%s${NC}\n" "$1"; }

PROFILE="$(awk '/hardening_profile:/{print $2}' /etc/hcs-image-build.txt 2>/dev/null || echo unknown)"

printf "\n${BOLD}On-instance validation${NC}\n"
printf "  Build provenance:\n"
sed 's/^/    /' /etc/hcs-image-build.txt 2>/dev/null || echo "    /etc/hcs-image-build.txt missing"
echo ""

# ── cloud-init ────────────────────────────────────────────────────────────────
hdr "cloud-init"

CI_STATUS="$(cloud-init status 2>/dev/null | awk '{print $NF}' || echo unknown)"
if [ "$CI_STATUS" = "done" ]; then
  ok "cloud-init status: done"
else
  fail "cloud-init status: $CI_STATUS (expected 'done')"
fi

CI_LONG="$(sudo cloud-init status --long 2>/dev/null)"
if [ $? -ne 0 ]; then
  warn "cloud-init status --long failed — cannot check for errors"
elif echo "$CI_LONG" | grep -qE '^errors: \[.+\]'; then
  warn "cloud-init reported errors — check: sudo cloud-init status --long"
else
  ok "no cloud-init errors logged"
fi

# ── Instance identity: unique per instance ────────────────────────────────────
hdr "Instance identity"

MACHINE_ID="$(cat /etc/machine-id | tr -d '[:space:]')"
if [ "${#MACHINE_ID}" -eq 32 ]; then
  ok "machine-id set and 32 chars: ${MACHINE_ID}"
else
  fail "machine-id is empty or malformed: '${MACHINE_ID}'"
fi

DBUS_ID="$(cat /var/lib/dbus/machine-id 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$DBUS_ID" = "$MACHINE_ID" ]; then
  ok "/var/lib/dbus/machine-id matches /etc/machine-id"
else
  fail "/var/lib/dbus/machine-id differs from /etc/machine-id"
fi

HOST_KEY_COUNT="$(ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l)"
if [ "$HOST_KEY_COUNT" -gt 0 ]; then
  ok "SSH host keys generated (${HOST_KEY_COUNT} files)"
else
  fail "no SSH host keys found"
fi

HOSTNAME="$(hostname)"
if [ -n "$HOSTNAME" ] && [ "$HOSTNAME" != "localhost" ] && [ "$HOSTNAME" != "packer-build" ]; then
  ok "hostname set from metadata: $HOSTNAME"
else
  warn "hostname is '$HOSTNAME' — metadata may not have provided one"
fi

# ── Networking and DNS ────────────────────────────────────────────────────────
hdr "Networking and DNS"

if systemctl is-active systemd-resolved >/dev/null 2>&1; then
  ok "systemd-resolved is active"
else
  fail "systemd-resolved is not active"
fi

RESOLV="$(readlink /etc/resolv.conf 2>/dev/null || echo NOT_SYMLINK)"
if [ "$RESOLV" = "/run/systemd/resolve/stub-resolv.conf" ]; then
  ok "/etc/resolv.conf → stub-resolv.conf"
else
  fail "/etc/resolv.conf is not the expected symlink: $RESOLV"
fi

if resolvectl query google.com >/dev/null 2>&1; then
  ok "DNS resolves public names (google.com)"
else
  fail "DNS resolution failed for google.com"
fi

HCS_DNS="$(resolvectl status 2>/dev/null | grep 'Current DNS Server' | awk '{print $NF}' | head -1)"
if [ -n "$HCS_DNS" ]; then
  ok "per-link DNS from HCS: $HCS_DNS"
else
  warn "no per-link DNS from HCS datasource — global DNS= only"
fi

# ── Time sync ─────────────────────────────────────────────────────────────────
hdr "Time sync (chrony)"

if systemctl is-active chrony >/dev/null 2>&1; then
  ok "chrony is active"
else
  fail "chrony is not active"
fi

OFFSET="$(chronyc tracking 2>/dev/null | awk '/System time/{print $4, $5}' || true)"
if [ -n "$OFFSET" ]; then
  ok "chrony tracking: offset ${OFFSET}"
else
  warn "chronyc tracking returned no data — NTP may not be reachable yet"
fi

# ── SSH ───────────────────────────────────────────────────────────────────────
hdr "SSH"

if sudo sshd -T 2>/dev/null | grep -qi 'passwordauthentication no'; then
  ok "PasswordAuthentication no (sshd runtime config)"
else
  fail "PasswordAuthentication is not 'no' in sshd runtime config"
fi

if sudo sshd -T 2>/dev/null | grep -qi 'pubkeyauthentication yes'; then
  ok "PubkeyAuthentication yes"
else
  fail "PubkeyAuthentication not yes in sshd runtime config"
fi

# ── Ubuntu Pro ────────────────────────────────────────────────────────────────
hdr "Ubuntu Pro client"

if command -v pro >/dev/null 2>&1; then
  ok "ubuntu-pro-client present ($(pro --version 2>/dev/null || echo version unknown))"
else
  fail "ubuntu-pro-client missing"
fi

# ── Guest agent ───────────────────────────────────────────────────────────────
hdr "QEMU guest agent"

if systemctl is-active qemu-guest-agent >/dev/null 2>&1; then
  ok "qemu-guest-agent is active"
else
  warn "qemu-guest-agent is not active — HCS console/metadata features may not work"
fi

# ── Hardening: cis-l1 and cis-l2 ─────────────────────────────────────────────
if [ "$PROFILE" = "cis-l1" ] || [ "$PROFILE" = "cis-l2" ]; then

  hdr "Hardening ($PROFILE)"

  if systemctl is-active auditd >/dev/null 2>&1; then
    ok "auditd is active"
  else
    fail "auditd is not active"
  fi

  # auditctl -l (list) works even with -e 2 immutable mode; -e 2 only blocks changes.
  if sudo auditctl -l 2>/dev/null | grep -qF -- '-w /etc/passwd'; then
    ok "auditd rules loaded (identity rules present)"
  else
    warn "auditd identity rules not visible — may still be loading"
  fi

  if systemctl is-active apparmor >/dev/null 2>&1; then
    ok "AppArmor is active"
  else
    fail "AppArmor is not active"
  fi

  ENFORCED="$(sudo aa-status 2>/dev/null | grep 'profiles are in enforce mode' | awk '{print $1}' || echo 0)"
  if [ "${ENFORCED:-0}" -gt 0 ]; then
    ok "AppArmor: $ENFORCED profile(s) in enforce mode"
  else
    warn "AppArmor: no profiles in enforce mode"
  fi

  if [ -f /var/lib/aide/aide.db ]; then
    ok "AIDE database initialised"
  else
    AIDE_STATE="$(systemctl is-active hcs-aide-init.service 2>/dev/null || echo inactive)"
    if [ "$AIDE_STATE" = "activating" ]; then
      warn "AIDE: hcs-aide-init.service still running — wait and re-check"
    elif systemctl is-enabled hcs-aide-init.service >/dev/null 2>&1; then
      warn "AIDE: DB not yet present but service is enabled — may not have run yet"
    else
      fail "AIDE: DB missing and hcs-aide-init.service is not enabled"
    fi
  fi

  # Verify key-only auth is enforced end-to-end
  if grep -qr 'PasswordAuthentication no' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
    ok "PasswordAuthentication no in sshd config files"
  else
    fail "PasswordAuthentication no not found in sshd config files"
  fi

fi

# ── L2-specific ───────────────────────────────────────────────────────────────
if [ "$PROFILE" = "cis-l2" ]; then

  hdr "Hardening: L2"

  FWD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo -1)"
  if [ "$FWD" = "0" ]; then
    ok "net.ipv4.ip_forward=0"
  else
    fail "net.ipv4.ip_forward=$FWD (expected 0 for cis-l2)"
  fi

  FWD6="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo -1)"
  if [ "$FWD6" = "0" ]; then
    ok "net.ipv6.conf.all.forwarding=0"
  else
    fail "net.ipv6.conf.all.forwarding=$FWD6 (expected 0)"
  fi

  if systemctl is-enabled hcs-aide-check.timer >/dev/null 2>&1; then
    ok "hcs-aide-check.timer enabled (daily AIDE check)"
  else
    fail "hcs-aide-check.timer not enabled"
  fi

  BANNER="$(cat /etc/issue.net 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$BANNER" ]; then
    ok "login banner set (/etc/issue.net)"
  else
    fail "/etc/issue.net is empty — L2 banner step did not run"
  fi

fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}Results:${NC}  ${GREEN}%d passed${NC}" "$NPASS"
[ "$NWARN" -gt 0 ] && printf "  ${YELLOW}%d warnings${NC}" "$NWARN"
[ "$NFAIL" -gt 0 ] && printf "  ${RED}%d failed${NC}" "$NFAIL"
printf "\n\n"

if [ "$NFAIL" -gt 0 ]; then
  echo "Instance did NOT pass validation. Do not publish this image."
  exit 1
fi

echo "Instance passed validation."
[ "$NWARN" -gt 0 ] && echo "Review warnings above before publishing."
exit 0
