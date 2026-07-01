# Ubuntu 24.04 → Huawei Cloud Stack 8.5.1 (ManageOne) golden image

A reproducible, auditable Packer build that turns Canonical's **GPG-verified**
official Ubuntu 24.04 (Noble) cloud image into an HCS-ready private image. Built
because you shouldn't have to trust a vendor-baked image you didn't assemble.

## What this does

1. **`prepare.sh`** — downloads Canonical's official Noble cloud image and
   verifies it against Canonical's GPG signing key
   (`D2EB 4462 6FDD C30B 513D 5BB7 1A5D 6C4C 7DB8 7C81`). Generates an
   ephemeral SSH key for the build VM.
2. **`packer build .`** — boots the verified image under KVM and runs:
   - `scripts/10-hcs-prep.sh` — the HCS contract (virtio in initramfs,
     cloud-init OpenStack datasource, datasource-driven networking, fstab→UUID,
     serial console).
   - `scripts/20-harden.sh` — cloud-safe hardening baseline (key-only SSH, auditd,
     sysctl, PAM lockout, AppArmor, mount hardening — see table below).
   - `scripts/99-seal.sh` — strips machine-id, SSH host keys, logs, cloud-init
     state so every instance is unique.
3. **`finalize.sh`** — offline: removes the build user + credentials,
   optionally installs your HCS password-reset agent, and sparsifies the qcow2.

## Requirements (build host)

- KVM available (`/dev/kvm`). If building inside a VM, enable nested virt.
- `packer`, `qemu-system-x86`, `qemu-utils`, `libguestfs-tools`, `gnupg`, `curl`.

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils libguestfs-tools gnupg curl
# install Packer from HashiCorp's apt repo, then:
packer init .
```

## Build

This produces a **catalogue of SKUs** from one shared build — `base` plus
hardened tiers — exactly how AWS/Azure structure their Ubuntu offerings (a
minimal base image and separate CIS-hardened SKUs). The HCS contract
(`10-hcs-prep.sh` + `99-seal.sh`) is identical in every SKU; only the hardening
tier varies.

```bash
chmod +x prepare.sh finalize.sh scripts/*.sh
make all          # builds base, cis-l1, cis-l2
# or one at a time:
make base
make cis-l1
make cis-l2
# with options:
make cis-l1 NTP_SERVERS="ntp1.corp ntp2.corp" PATCH=true
```

Each SKU lands in `dist/` named with its profile and the git commit, alongside a
provenance manifest:

```
dist/ubuntu-2404-hcs-base-<sha>.qcow2     + .manifest.json
dist/ubuntu-2404-hcs-cis-l1-<sha>.qcow2   + .manifest.json
dist/ubuntu-2404-hcs-cis-l2-<sha>.qcow2   + .manifest.json
```

The same provenance is stamped **inside** each image at
`/etc/hcs-image-build.txt`, so on HCS you can always tell which SKU and commit an
instance came from and reproduce it.

### The three SKUs

| Profile | Analogous to | What it is |
|---|---|---|
| `base` | stock AWS/Azure Ubuntu AMI/image | HCS contract only; `20-harden.sh` skipped. **Still key-only** (via cloud-init `ssh_pwauth:false`) and sealed — "base" drops the CIS baseline, not cloud hygiene. |
| `cis-l1` | CIS Level 1 hardened SKU | the `[H*]` baseline (auditd, sysctl, PAM lockout, AppArmor, mount hardening, key-only SSH + strong crypto). |
| `cis-l2` | CIS Level 2 hardened SKU | cis-l1 **plus** `[L2-*]`: expanded auditd, AIDE daily checks, IP-forwarding/userns off, extra module blacklist, stricter SSH/PAM, warning banners. |

> **cis-l2 breaks workloads on purpose.** L2 disables IP forwarding and
> unprivileged user namespaces — that **breaks Kubernetes nodes, rootless
> containers, NAT gateways, and routers**. That's precisely why it's a separate
> SKU, not the default. Pick L1 unless a control mandates L2, and validate L2
> against the actual workload.

### Validation is per-SKU — budget for it

Every tier needs its **own** boot test, SSH test, and (for hardened tiers) a CIS
audit run, because a control that's fine on L1 can break cloud-init or your app
on L2. You're validating N images, not one. To turn a hardened SKU into a
*certified* one, run USG or OpenSCAP with the matching profile on a test
instance and keep the audit report as that SKU's evidence (commands in the
footer of `scripts/20-harden.sh`).

### Build knobs (set in `variables.auto.pkrvars.hcl`, `-var`, or `make VAR=...`)

**Packer variables** (set in `variables.auto.pkrvars.hcl`, `-var`, or `make VAR=...`):

| Variable | Default | Purpose |
|---|---|---|
| `hardening_profile` | `cis-l1` | `base` \| `cis-l1` \| `cis-l2` (the Makefile sets this per target) |
| `ntp_servers` | `""` | Space-separated NTP hosts for chrony. **Set for production**; if set, the public pool is disabled (airgap-safe). |
| `patch_on_first_boot` | `false` | Apply security updates on first boot, like stock AWS/Azure images. Slows first boot. |
| `disk_size` | `10G` | System disk size (keep ≤ 128G). |

**Makefile-only variable** (passed directly to `finalize.sh`, not via Packer):

| Variable | Default | Purpose |
|---|---|---|
| `RESET_AGENT` | `""` | Path to your HCS `CloudResetPwdAgent.zip` (`make cis-l1 RESET_AGENT=/path/to/agent.zip`). Leave empty with key-only auth. |

Sub-toggles for the hardening scripts (env, e.g. via the provisioner):
`HARDEN_TMP=false` (skip `/tmp` noexec), `SSH_PERMIT_ROOT=no` (forbid root SSH).

### First-party cloud-image parity

This image targets the **HCS-native equivalent** of an AWS/Azure first-party
Ubuntu image — *not* a literal copy. The provider agents (amazon-ssm-agent,
walinuxagent, azure-vm-utils) and kernels (`linux-aws`/`linux-azure`) are bound
to those clouds' control planes and are deliberately **not** included; on HCS
they'd be inert or counterproductive. The portable equivalents are all present:
clean GPG-verified base, OpenStack datasource, `qemu-guest-agent`, `ubuntu-pro-client`
(for ESM/Livepatch/USG/FIPS attach), chrony time sync, root-disk auto-grow,
host-key/machine-id regen, serial console, i6300ESB watchdog — plus a hardening
baseline that exceeds the *minimal* stock AWS/Azure images.

## Datasource (confirmed for this platform)

The metadata datasource was confirmed on an HCS 8.5.1 instance:

```
cloud-init query subplatform   ->  metadata (http://169.254.169.254)
cloud-init query platform      ->  openstack
cloud-init query cloud_name    ->  openstack
# /var/log/cloud-init.log:      Loaded datasource DataSourceOpenStackLocal [net,ver=2]
```

So HCS serves a **standard OpenStack metadata service at the bare link-local IP**
`http://169.254.169.254` (no `/clouddc` path — an earlier guess), and it **pushes
network config** that cloud-init applies. The build reflects this:
`scripts/10-hcs-prep.sh` pins `metadata_urls: ['http://169.254.169.254']`, trims
`datasource_list` to `[ OpenStack, ConfigDrive, NoCloud, None ]`, and leaves
`apply_network_config` at its default so platform addressing is honoured.

If you ever need to re-confirm on a different region/version, the runtime query
above is the ground truth — match `metadata_urls` to whatever `subplatform`
reports (or, if it reports `config-drive`, drop the URL and rely on the
`ConfigDrive` entry).

## Networking strategy

Default (what this build ships): **let cloud-init render the network from the
HCS datasource**, exactly like the stock HCS image. This honours both DHCP and
platform-assigned static IPs. The seal step (`99-seal.sh`) ships one Netplan
file — `/etc/netplan/99-hcs-fallback.yaml` — as a hardware-agnostic DHCP
bootstrap for the very first boot, before cloud-init has had a chance to render
its config and reach the metadata service. The file uses `match: name: "en*"` so
it matches any virtio NIC regardless of PCI slot or MAC. Once cloud-init renders
`/etc/netplan/50-cloud-init.yaml`, that file's systemd-networkd unit
(`50-netplan-*.network`) sorts alphabetically before the fallback's unit
(`99-netplan-any-eth.network`), and systemd-networkd's first-match-wins rule
means cloud-init's config takes full precedence from that point forward.

Alternative (only if you deliberately want to ignore platform network config and
force DHCP on every NIC): disable cloud-init network rendering and replace the
fallback with an unconditional config. Useful in some homogeneous fleets, but it
will override static-IP ports — don't use it unless that's what you want.

```bash
# In scripts/10-hcs-prep.sh, replace the section [4] body with:
printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
rm -f /etc/netplan/50-cloud-init.yaml
cat > /etc/netplan/90-hcs-dhcp.yaml <<'YAML'
network:
  version: 2
  renderer: networkd
  ethernets:
    hcs-en:  {match: {name: "en*"},  dhcp4: true, dhcp6: false, optional: true}
    hcs-eth: {match: {name: "eth*"}, dhcp4: true, dhcp6: false, optional: true}
YAML
chmod 600 /etc/netplan/90-hcs-dhcp.yaml
```

## Upload and register on HCS

1. Upload `ubuntu-2404-hcs.qcow2` to the OBS bucket your tenant uses (OBS
   Browser+ or `obsutil`).
2. In **IMS → Private Images → Create Private Image**:
   - Source: **Image File**, select the qcow2 from OBS.
   - Type: **System disk image**, **Linux**, OS **Ubuntu**.
   - Boot mode: **UEFI** (the Noble cloud image is UEFI/GPT — match this or the
     instance won't boot).
   - System disk ≥ the image's disk size.
3. Wait for status **Normal**.

## Validate before publishing (do not skip)

Launch a throwaway instance from the new image and confirm:

- it boots and gets an IP via DHCP;
- the injected SSH key works (key-only: a console *password* will NOT — expected);
- hostname is set from metadata;
- `chronyc sources` shows your NTP server(s) reachable and the clock in sync;
- `pro status` runs (Pro client present) — attach is optional;
- `cat /etc/machine-id` is non-empty and **differs** from a second instance;
- `ls /etc/ssh/ssh_host_*` shows freshly generated keys (different per instance);
- if you installed the reset agent: `systemctl status cloudResetPwdAgent`;
- if watchdog is enabled for the instance: `systemctl status watchdog` is `active`, `dmesg | grep i6300` shows the timer initialized.

Only after that, share the image to your projects/tenants.

## Watchdog

HCS ECS exposes a virtual **Intel i6300ESB** watchdog device when the watchdog feature is enabled for an instance (ECS console → **Manage Watchdog Status** → Enable). The image comes pre-wired:

- `watchdog` package installed; `i6300esb` module loaded via `modules-load.d`
- `/etc/watchdog.conf`: 5-second heartbeat interval, real-time priority
- `watchdog.service` enabled with a `ConditionPathExists=/dev/watchdog` guard so it only activates on ECSes where the watchdog device is actually present

No action is needed in the image or at launch — simply enable the feature in the ECS console and the daemon starts automatically on the next (or current) boot.

## What the hardening baseline does (`scripts/20-harden.sh`)

Applied at `cis-l1` and above, all cloud-safe — none of these can lock an
instance out on their own:

| # | Control |
|---|---------|
| H1 | **Key-only SSH** + modern KEX/cipher/MAC, no agent/TCP forwarding, root = `prohibit-password` |
| H2 | sysctl: ASLR, `kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, kexec off, BPF hardening, anti-spoof/redirect, syncookies, protected links |
| H3 | Blacklist unused filesystems (cramfs, hfs, udf, usb-storage…) and net protocols (dccp, sctp, rds, tipc) |
| H4 | auditd with a CIS-style ruleset (identity, sudoers, sshd, cloud-init, setuid, modules), `-e 2` immutable |
| H5 | PAM: `pwquality` (min 14, complexity), `faillock` lockout, `login.defs` aging/umask 027, SHA512 rounds, sudo `use_pty` + logging |
| H6 | Core dumps disabled (limits + systemd-coredump) |
| H7 | AppArmor enabled; journald persistent + capped |
| H8 | `unattended-upgrades` for **security** updates, no auto-reboot |
| H9 | `/tmp` (tmpfs), `/dev/shm`, `/var/tmp` mounted `nosuid,nodev,noexec` (toggle `HARDEN_TMP=false`) |
| H10 | AIDE installed; DB initialised on **first boot** after cloud-init (not baked stale) |
| H11 | Purge telnet/rsh/talk; autoremove |

Sub-toggles: `HARDEN_TMP=false` (if something needs to exec from `/tmp`),
`SSH_PERMIT_ROOT=no` (forbid root SSH entirely; ensure your sudo user's key is
injected first or you'll have no way in).

### Higher-friction controls left as opt-ins (don't bake blind)

These are valuable but can brick a *golden image* if misconfigured, so they're
documented here rather than enabled by default. Add to `20-harden.sh` only after
testing on a throwaway instance.

- **Host firewall (nftables) default-deny inbound.** On HCS, security groups
  already gate ingress, so this is defense-in-depth. The danger: a wrong rule
  locks out SSH on *every* instance. If you add it, allow established + your SSH
  port before anything else:
  ```bash
  apt-get install -y nftables
  cat > /etc/nftables.conf <<'NFT'
  table inet filter {
    chain input {
      type filter hook input priority 0; policy drop;
      ct state established,related accept
      iif "lo" accept
      tcp dport 22 accept
      ip protocol icmp accept
      ip6 nexthdr ipv6-icmp accept
    }
  }
  NFT
  systemctl enable nftables
  ```
- **CIS certification (USG / OpenSCAP).** Run a full profile *on top* of this
  baseline, then reconcile the diff — some CIS rules (e.g. forcing password auth
  settings, disabling cloud-init-needed modules) need exceptions. Commands are in
  the footer of `20-harden.sh`. Always `audit` before `fix`, and test boot + SSH.
- **GRUB password / boot lockdown.** Stops console editing of kernel args, but a
  bad superuser config can make the image unbootable and complicates recovery.
  Rarely worth it for cloud VMs; skip unless a control mandates it.
- **MFA at console / sudo** (`libpam-google-authenticator`) and **remote log
  forwarding** (rsyslog → SIEM) — environment-specific; wire to your infra.

## Design decisions worth knowing

- **Trust anchor.** The chain is: Canonical GPG key → signed `SHA256SUMS` →
  pinned image hash → your build. The final image's trustworthiness reduces to
  trusting *your* pipeline, which is where it should sit. Run `prepare.sh` on a
  clean builder and keep the transcript for audit.
- **Key-only auth.** `ssh_pwauth:false` (cloud-init) and `PasswordAuthentication
  no` (sshd) are both set. Consequence: **launch every instance with an HCS key
  pair** — one booted with the "password" login method will be unreachable. The
  one-click password-reset agent is therefore pointless here; leave
  `RESET_AGENT` unset (the default).
- **Patch cadence.** This produces a point-in-time image. `unattended-upgrades`
  covers security drift between rebuilds, but still re-run the whole build on a
  schedule and keep this directory in version control so each image is
  reproducible from a known commit.

## Offline alternative (no KVM)

If your CI can't do nested virt, the `scripts/*.sh` are plain bash and can be
driven offline with `virt-customize --run` against the base qcow2 instead of
Packer. A few steps that read the live system (`findmnt /`) need minor
adaptation for a chroot context; everything else ports directly.
