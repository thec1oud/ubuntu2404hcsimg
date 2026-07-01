#!/usr/bin/env bash
#
# 20-harden.sh — Profile-aware hardening for HCS Ubuntu 24.04.
#
# Tiers (set via HARDENING_PROFILE):
#   base    -> skip entirely (HCS contract only; key-only SSH still comes from
#              cloud-init's ssh_pwauth:false in 10-hcs-prep.sh)
#   cis-l1  -> the [H*] baseline below (CIS Level 1-style, cloud-safe)
#   cis-l2  -> cis-l1 PLUS the [L2-*] block at the end (stricter, more breakage
#              risk — validate against your workload)
#
# Design principles for a GOLDEN IMAGE (not a one-off server):
#   * Never bake in something that can lock every instance out (host firewall,
#     GRUB password, root account lock). Those are documented OPT-INS in the
#     README, not defaults here.
#   * Anything that depends on per-instance identity (AIDE baseline, host keys)
#     is initialised on FIRST BOOT, after cloud-init, not at build time.
#   * Don't fight cloud-init: it injects the login key and renders the network.
#
# Sub-toggles (export before build to change defaults):
#   HARDEN_TMP=true|false       nodev/nosuid/noexec on /tmp,/dev/shm,/var/tmp
#   SSH_PERMIT_ROOT=no|prohibit-password   root SSH policy (default no)
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PROFILE="${HARDENING_PROFILE:-cis-l1}"
HARDEN_TMP="${HARDEN_TMP:-true}"
SSH_PERMIT_ROOT="${SSH_PERMIT_ROOT:-no}"

case "$PROFILE" in
  base)
    echo "==> profile=base: HCS contract only, no CIS baseline. Skipping."
    exit 0 ;;
  cis-l1|cis-l2)
    echo "==> Applying hardening profile: $PROFILE" ;;
  *)
    echo "ERROR: unknown HARDENING_PROFILE='$PROFILE' (expected base|cis-l1|cis-l2)" >&2
    exit 1 ;;
esac

###############################################################################
echo "==> [H1] SSH: key-only auth + strong crypto"
###############################################################################
# Our file sorts after cloud-init's 50-cloud-init.conf, so these win.
cat > /etc/ssh/sshd_config.d/80-hcs-hardening.conf <<EOF
# --- Authentication: keys only ---
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
PermitRootLogin ${SSH_PERMIT_ROOT}

# --- Reduce surface / session hygiene ---
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
Banner none

# --- Modern crypto only ---
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
EOF
# Validate config so a typo can't ship a broken sshd.
sshd -t -f /etc/ssh/sshd_config

###############################################################################
echo "==> [H2] Kernel/sysctl hardening"
###############################################################################
cat > /etc/sysctl.d/80-hcs-hardening.conf <<'EOF'
# Network
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Kernel
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.perf_event_paranoid = 3
# Filesystem
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
EOF

###############################################################################
echo "==> [H3] Disable unused kernel modules (filesystems + net protocols)"
###############################################################################
cat > /etc/modprobe.d/80-hcs-blacklist.conf <<'EOF'
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install udf /bin/false
install usb-storage /bin/false
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
EOF
# NOTE: squashfs is intentionally NOT blacklisted (snapd depends on it). Add it
# only if you are certain no snaps are in use.

###############################################################################
echo "==> [H4] auditd + a baseline ruleset"
###############################################################################
apt-get update
apt-get install -y --no-install-recommends auditd audispd-plugins
cat > /etc/audit/rules.d/80-hcs.rules <<'EOF'
# Identity / auth changes
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
# SSH + cloud-init config
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/cloud/ -p wa -k cloudinit
# Privilege escalation
-w /var/log/sudo.log -p wa -k actions
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k setuid
# Time + module changes
-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
-a always,exit -F arch=b64 -S init_module,delete_module,finit_module -k modules
EOF
# The immutable flag (-e 2) MUST be the last rule loaded across ALL rules.d
# files, so it lives in its own 99-sorted file — otherwise it would block the
# cis-l2 81-* rules from loading.
echo '-e 2' > /etc/audit/rules.d/99-immutable.rules
systemctl enable auditd

###############################################################################
echo "==> [H5] Accounts / PAM: lockout, password quality, sudo logging"
###############################################################################
apt-get install -y --no-install-recommends libpam-pwquality
mkdir -p /etc/security/pwquality.conf.d
cat > /etc/security/pwquality.conf.d/80-hcs.conf <<'EOF'
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
difok = 3
maxrepeat = 3
gecoscheck = 1
EOF

# Account lockout after repeated failures (affects console/sudo; SSH is key-only)
cat > /etc/security/faillock.conf <<'EOF'
deny = 5
unlock_time = 900
fail_interval = 900
EOF

# login.defs baseline
sed -i 's/^UMASK.*/UMASK 027/'                 /etc/login.defs || true
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS 365/' /etc/login.defs || true
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS 1/'   /etc/login.defs || true
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE 7/'   /etc/login.defs || true
grep -q '^SHA_CRYPT_MIN_ROUNDS' /etc/login.defs || echo 'SHA_CRYPT_MIN_ROUNDS 65536' >> /etc/login.defs

# sudo: log + use a pty (limits escape from a compromised command)
cat > /etc/sudoers.d/10-hcs-hardening <<'EOF'
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
Defaults !visiblepw
EOF
chmod 440 /etc/sudoers.d/10-hcs-hardening
visudo -cf /etc/sudoers.d/10-hcs-hardening

###############################################################################
echo "==> [H6] Disable core dumps"
###############################################################################
echo '* hard core 0' > /etc/security/limits.d/80-hcs-nocore.conf
mkdir -p /etc/systemd/coredump.conf.d
cat > /etc/systemd/coredump.conf.d/80-hcs.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

###############################################################################
echo "==> [H7] AppArmor enforce + journald persistent"
###############################################################################
apt-get install -y --no-install-recommends apparmor apparmor-utils
systemctl enable apparmor || true
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/80-hcs.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=500M
ForwardToSyslog=no
EOF

###############################################################################
echo "==> [H8] Automatic security updates (no auto-reboot)"
###############################################################################
apt-get install -y --no-install-recommends unattended-upgrades
cat > /etc/apt/apt.conf.d/52-hcs-unattended <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

###############################################################################
echo "==> [H9] Mount hardening for /tmp, /dev/shm, /var/tmp"
###############################################################################
if [ "$HARDEN_TMP" = "true" ]; then
  # /tmp as a hardened tmpfs via systemd (survives image cloning cleanly)
  cp -f /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount 2>/dev/null || true
  mkdir -p /etc/systemd/system/tmp.mount.d
  cat > /etc/systemd/system/tmp.mount.d/80-hcs.conf <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,noexec
EOF
  systemctl enable tmp.mount || true
  # /dev/shm
  grep -q '/dev/shm' /etc/fstab || \
    echo 'tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0' >> /etc/fstab
  # /var/tmp bound to /tmp
  grep -q '/var/tmp' /etc/fstab || \
    echo '/tmp /var/tmp none rw,noexec,nosuid,nodev,bind 0 0' >> /etc/fstab
  echo "    NOTE: noexec on /tmp is CIS-recommended but can break tools that"
  echo "          exec from /tmp. Set HARDEN_TMP=false to skip if you hit that."
fi

###############################################################################
echo "==> [H10] First-boot AIDE initialisation (after cloud-init)"
###############################################################################
apt-get install -y --no-install-recommends aide aide-common
# Don't build the DB now — host keys/machine-id/users change on first boot.
cat > /etc/systemd/system/hcs-aide-init.service <<'EOF'
[Unit]
Description=Initialise AIDE database on first boot
After=cloud-final.service
ConditionPathExists=!/var/lib/aide/aide.db
[Service]
Type=oneshot
ExecStart=/usr/sbin/aideinit -y -f
[Install]
WantedBy=multi-user.target
EOF
systemctl enable hcs-aide-init.service

###############################################################################
echo "==> [H11] Attack-surface trim"
###############################################################################
apt-get purge -y telnet rsh-client talk 2>/dev/null || true
apt-get autoremove --purge -y || true

###############################################################################
# cis-l2: additive controls on top of the L1 baseline above.
###############################################################################
if [ "$PROFILE" = "cis-l2" ]; then

  echo "==> [L2-1] Expanded auditd ruleset"
  cat > /etc/audit/rules.d/81-hcs-l2.rules <<'EOF'
-w /var/log/lastlog -p wa -k logins
-w /var/run/faillock -p wa -k logins
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
-w /var/run/utmp -p wa -k session
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S setxattr,lsetxattr,fsetxattr,removexattr,lremovexattr,fremovexattr -F auid>=1000 -F auid!=4294967295 -k perm_mod
-a always,exit -F arch=b64 -S open,openat,truncate,ftruncate,creat -F exit=-EACCES -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S open,openat,truncate,ftruncate,creat -F exit=-EPERM -F auid>=1000 -F auid!=4294967295 -k access
-a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=4294967295 -k delete
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts
EOF
  # Append a privileged-command rule per suid/sgid binary found in the image.
  find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | while read -r p; do
    echo "-a always,exit -F path=$p -F perm=x -F auid>=1000 -F auid!=4294967295 -k privileged"
  done >> /etc/audit/rules.d/81-hcs-l2.rules

  echo "==> [L2-2] AIDE daily integrity-check timer"
  cat > /etc/systemd/system/hcs-aide-check.service <<'EOF'
[Unit]
Description=HCS daily AIDE integrity check
ConditionPathExists=/var/lib/aide/aide.db
[Service]
Type=oneshot
ExecStart=/usr/bin/aide --check
EOF
  cat > /etc/systemd/system/hcs-aide-check.timer <<'EOF'
[Unit]
Description=Run AIDE integrity check daily
[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=1800
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl enable hcs-aide-check.timer

  echo "==> [L2-3] Stricter sysctl (BREAKS routers/containers — why L2 is separate)"
  cat > /etc/sysctl.d/81-hcs-l2.conf <<'EOF'
# Disable IP forwarding — do NOT use on routers, k8s nodes, or NAT gateways.
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
# Restrict unprivileged user namespaces — breaks rootless containers/sandboxes.
# 24.04 mechanism:
kernel.apparmor_restrict_unprivileged_userns = 1
# Older mechanism (silently ignored if the key is absent):
kernel.unprivileged_userns_clone = 0
EOF

  echo "==> [L2-4] Additional module blacklist (vfat kept — UEFI ESP needs it)"
  cat > /etc/modprobe.d/81-hcs-l2-blacklist.conf <<'EOF'
install bluetooth /bin/false
install firewire-core /bin/false
install gfs2 /bin/false
EOF

  echo "==> [L2-5] SSH L2 tightening"
  cat > /etc/ssh/sshd_config.d/81-hcs-l2.conf <<'EOF'
LogLevel VERBOSE
MaxStartups 10:30:60
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com
EOF
  sshd -t -f /etc/ssh/sshd_config

  echo "==> [L2-6] PAM: password history + stricter quality"
  echo 'minclass = 4' >> /etc/security/pwquality.conf.d/80-hcs.conf
  grep -q '^even_deny_root' /etc/security/faillock.conf || \
    echo 'even_deny_root' >> /etc/security/faillock.conf
  # pam-configs format is TAB-sensitive — write with explicit tabs via printf.
  printf 'Name: HCS remember last passwords\nDefault: yes\nPriority: 1024\nPassword-Type: Primary\nPassword:\n\trequisite\t\t\tpam_pwhistory.so remember=24 enforce_for_root use_authtok\n' \
    > /usr/share/pam-configs/hcs-pwhistory
  DEBIAN_FRONTEND=noninteractive pam-auth-update --enable hcs-pwhistory 2>/dev/null \
    || DEBIAN_FRONTEND=noninteractive pam-auth-update --package 2>/dev/null || true

  echo "==> [L2-7] Warning login banners"
  BANNER='Authorized access only. All activity is monitored and logged.'
  printf '%s\n' "$BANNER" | tee /etc/issue /etc/issue.net /etc/motd >/dev/null
  echo 'Banner /etc/issue.net' > /etc/ssh/sshd_config.d/82-hcs-banner.conf
  sshd -t -f /etc/ssh/sshd_config

  echo "==> [L2-8] Disable Ctrl+Alt+Del reboot"
  systemctl mask ctrl-alt-del.target || true

  echo "==> cis-l2 controls applied."
fi

echo ""
echo "==> Hardening profile '${PROFILE}' applied (key-only SSH; root: ${SSH_PERMIT_ROOT})."
echo "    For CERTIFIED CIS Level 1/2, layer one of these on a TEST instance:"
echo "      - Canonical USG (needs Ubuntu Pro):"
echo "          pro enable usg && apt-get install -y usg"
echo "          usg audit cis_level1_server ; usg fix cis_level1_server"
echo "      - OpenSCAP + SSG:"
echo "          apt-get install -y libopenscap8 ssg-base ssg-debderived"
echo "          oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_level1_server \\"
echo "            --remediate /usr/share/xml/scap/ssg/content/ssg-ubuntu2404-ds.xml"
