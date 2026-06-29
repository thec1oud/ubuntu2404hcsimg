# Override any of these as needed, e.g.:  packer build -var 'hardening_profile=base' .
# (The Makefile sets hardening_profile per target, so this default only applies
# to a bare `packer build .`.)
image_name = "ubuntu-2404-hcs"
disk_size  = "40G"
hardening_profile = "cis-l1"   # base | cis-l1 | cis-l2

# Time sync: set to your HCS/datacenter NTP (space-separated). Empty keeps the
# public Ubuntu pool. Set this for production, especially in airgapped sites.
ntp_servers = ""

# Apply security updates on first boot (like stock AWS/Azure images). Slows the
# first boot; unattended-upgrades already handles ongoing drift.
patch_on_first_boot = false

# Absolute path to the CloudResetPwdAgent.zip from YOUR HCS 8.5.1 environment.
# Leave empty to skip the agent. (Consumed by finalize.sh, not Packer.)
# With key-only auth this should stay empty.
reset_agent_zip = ""
