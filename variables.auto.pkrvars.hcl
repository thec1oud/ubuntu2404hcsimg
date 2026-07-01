# Override any of these as needed, e.g.:  packer build -var 'hardening_profile=base' .
# (The Makefile sets hardening_profile per target, so this default only applies
# to a bare `packer build .`.)
image_name = "ubuntu-2404-hcs"
disk_size  = "10G"
hardening_profile = "cis-l1"   # base | cis-l1 | cis-l2

# Time sync: set to your HCS/datacenter NTP (space-separated). Empty keeps the
# public Ubuntu pool. Set this for production, especially in airgapped sites.
ntp_servers = ""

# Apply security updates on first boot (like stock AWS/Azure images). Slows the
# first boot; unattended-upgrades already handles ongoing drift.
patch_on_first_boot = false

# Mount /tmp, /dev/shm, /var/tmp with nodev/nosuid/noexec (cis-l1/l2 only).
# Set to false if your workload executes binaries from /tmp.
harden_tmp = true

# PermitRootLogin in sshd config (cis-l1/l2 only).
# prohibit-password = root login allowed only with a key (default; cloud-safe)
# no               = root login fully disabled
ssh_permit_root = "prohibit-password"

# QEMU accelerator. kvm = fast (requires /dev/kvm); tcg = software emulation.
accelerator = "kvm"

