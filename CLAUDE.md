# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Packer + QEMU build pipeline that produces HCS-ready (Huawei Cloud Stack 8.5.1 / ManageOne) golden images from Canonical's GPG-verified Ubuntu 24.04 Noble cloud image. Outputs a catalogue of three SKUs (`base`, `cis-l1`, `cis-l2`) as qcow2 images in `dist/`.

## Build host requirements

KVM must be available (`/dev/kvm`). Required tools:

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils libguestfs-tools gnupg curl
packer init .   # or: make init
```

## Commands

```bash
# First time / new base image: download + GPG-verify the upstream image, generate ephemeral build SSH key
./prepare.sh           # or: make prepare

# Validate Packer config
make validate

# Build all three SKUs into dist/
make all

# Build a single SKU
make base
make cis-l1
make cis-l2

# With overrides
make cis-l1 NTP_SERVERS="ntp1.corp ntp2.corp"
make cis-l1 PATCH=true
make cis-l1 RESET_AGENT=/path/to/CloudResetPwdAgent.zip
make base ACCEL=tcg                              # software emulation (no /dev/kvm)
make cis-l1 HARDEN_TMP=false                    # skip noexec on /tmp
make cis-l1 SSH_PERMIT_ROOT=no                  # fully block root SSH

# Clean build artifacts (keeps dist/)
make clean

# Clean everything including dist/ and build/
make distclean
```

## Build flow

Each `make <sku>` runs three sequential steps:

1. **`prepare.sh`** — downloads `noble-server-cloudimg-amd64.img` from Canonical, verifies it against the cloud-image signing key (`D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81`), pins the sha256, and generates an ephemeral ed25519 SSH key. Outputs land in `build/` (gitignored).

2. **`packer build -var hardening_profile=<sku> .`** — boots the verified image under KVM, runs the three provisioner scripts in order, then shuts down. Output lands in `output/<sku>/`.

3. **`finalize.sh output/<sku>/ubuntu-2404-hcs-<sku>.qcow2 [agent.zip]`** — offline post-processing via `virt-customize`: removes the `packer` build user, optionally installs the HCS password-reset agent, then sparsifies with `virt-sparsify`. The final qcow2 + `.manifest.json` are copied to `dist/`.

## Provisioner scripts

Scripts run inside the build VM as root via `sudo env {{ .Vars }} bash`. Order matters:

- **`scripts/10-hcs-prep.sh`** — HCS platform contract: virtio modules in initramfs, cloud-init wired to the HCS OpenStack datasource (`http://169.254.169.254`), fstab → UUID, serial console, chrony, qemu-guest-agent, ubuntu-pro-client, i6300ESB watchdog. Reads `$NTP_SERVERS` and `$PATCH_ON_FIRST_BOOT` from Packer env.

- **`scripts/20-harden.sh`** — Profile-aware hardening. Reads `$HARDENING_PROFILE`:
  - `base`: exits immediately (no-op — HCS contract only)
  - `cis-l1`: applies controls H1–H11 (SSH key-only + strong crypto, sysctl hardening, module blacklist, auditd, PAM/pwquality, no core dumps, AppArmor, unattended-upgrades, mount hardening, AIDE first-boot init, package trim)
  - `cis-l2`: cis-l1 plus expanded auditd, daily AIDE timer, stricter sysctl (disables IP forwarding + unprivileged userns — **breaks Kubernetes, rootless containers, NAT gateways**), extra module blacklist, tighter SSH, password history, login banners, Ctrl+Alt+Del disabled

  Sub-toggles: `harden_tmp=false` (skip noexec on /tmp), `ssh_permit_root=no` (full root SSH block). Pass via `make HARDEN_TMP=false` or `-var 'harden_tmp=false'`.

- **`scripts/99-seal.sh`** — Strips instance identity: truncates machine-id, removes SSH host keys, wipes logs, clears cloud-init state, removes bash history and network leases. Stamps `/etc/hcs-image-build.txt` with provenance (profile, git commit, base image sha256).

## Key design constraints

- **Key-only SSH is non-negotiable.** Both `ssh_pwauth:false` (cloud-init) and `PasswordAuthentication no` (sshd) are enforced. Every instance **must** be launched with an HCS key pair or it will be unreachable.

- **Build user removed offline, not in 99-seal.sh.** The `packer` user is still active during seal (it's the SSH session). `finalize.sh` removes it post-shutdown via `virt-customize`.

- **AIDE DB is not baked.** Initialised on first boot after cloud-init via `hcs-aide-init.service` (conditional on `/var/lib/aide/aide.db` not existing), because host keys and machine-id change on first boot.

- **Networking comes from the HCS datasource.** No competing static netplan is shipped. The OpenStack datasource at `169.254.169.254` provides network config (`net,ver=2`), matching the behaviour of the stock HCS image. See README for the opt-in DHCP-override snippet.

- **auditd `-e 2` (immutable) lives in `99-immutable.rules`**, sorted last, so the L2 `81-hcs-l2.rules` loads before it is applied.

- **`RESET_AGENT` is a Makefile-only variable**, passed directly to `finalize.sh` — it is not a Packer variable. The CloudResetPwdAgent package is environment-specific (not publicly downloadable).

## Variables

**Packer variables** — defined in `ubuntu-2404-hcs.pkr.hcl`, with defaults in `variables.auto.pkrvars.hcl`. Override via `-var`, `make VAR=...`, or by editing `variables.auto.pkrvars.hcl`:

| Variable | Default | Notes |
|---|---|---|
| `image_name` | `"ubuntu-2404-hcs"` | Base name for output files; also drives `vm_name` in Packer |
| `hardening_profile` | `cis-l1` | `base` \| `cis-l1` \| `cis-l2`; Makefile overrides per target |
| `ntp_servers` | `""` | Space-separated; empty keeps public Ubuntu pool; set for airgapped sites |
| `patch_on_first_boot` | `false` | Enables cloud-init `package_upgrade` on first boot |
| `harden_tmp` | `true` | Mount /tmp,/dev/shm,/var/tmp noexec (cis-l1/l2); set `false` for workloads that exec from /tmp |
| `ssh_permit_root` | `"prohibit-password"` | `PermitRootLogin` in sshd: `prohibit-password` (key-only root) or `no` (full block) |
| `accelerator` | `"kvm"` | QEMU accelerator: `kvm` (fast, needs /dev/kvm) or `tcg` (software, no KVM required) |
| `disk_size` | `10G` | Keep ≤ 128G for HCS |
| `git_sha` | `nogit` | Makefile passes `git rev-parse --short HEAD` automatically |

**Makefile-only variable** — passed directly to `finalize.sh`, not a Packer variable:

| Variable | Default | Notes |
|---|---|---|
| `RESET_AGENT` | `""` | Absolute path to `CloudResetPwdAgent.zip`; e.g. `make cis-l1 RESET_AGENT=/path/to/agent.zip` |

## Artifacts

```
build/                          # gitignored: base image, sha256, ephemeral SSH key
output/<sku>/                   # gitignored: raw packer output
dist/ubuntu-2404-hcs-<sku>-<sha>.qcow2          # final deliverable
dist/ubuntu-2404-hcs-<sku>-<sha>.manifest.json   # provenance (profile, commits, sha256s, build time)
```

In-image provenance is also stamped at `/etc/hcs-image-build.txt` so instances can be identified after launch.
