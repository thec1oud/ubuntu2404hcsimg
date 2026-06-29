###############################################################################
# ubuntu-2404-hcs.pkr.hcl
#
# Builds a Huawei Cloud Stack (HCS) 8.5.1 / ManageOne-ready Ubuntu 24.04 image
# from Canonical's GPG-verified Noble cloud image.
#
# Flow (use the Makefile to build the whole catalogue):
#   make all            -> base + cis-l1 + cis-l2 into dist/
#   make cis-l1         -> one SKU
# Under the hood, per profile:
#   1. ./prepare.sh       (verifies the base image, makes the build key)
#   2. packer build -var hardening_profile=<p> .   (provision, harden, seal)
#   3. ./finalize.sh      (offline: removes build user, optional reset agent, sparsify)
#
# Requires KVM on the build host (nested virt if building inside a VM).
###############################################################################

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "image_name" {
  type    = string
  default = "ubuntu-2404-hcs"
}

variable "disk_size" {
  type    = string
  default = "40G" # keep <= 128G for HCS
}

variable "output_dir" {
  type    = string
  default = "output"
}

# Hardening tier (the only thing that varies between SKUs):
#   base    - HCS contract only, no CIS baseline (analogous to stock AWS/Azure AMI)
#   cis-l1  - CIS Level 1-style baseline (scripts/20-harden.sh)
#   cis-l2  - cis-l1 PLUS stricter L2 controls (more breakage risk; test per app)
# base is still key-only via cloud-init; "base" drops the CIS baseline, not hygiene.
variable "hardening_profile" {
  type    = string
  default = "cis-l1"
  validation {
    condition     = contains(["base", "cis-l1", "cis-l2"], var.hardening_profile)
    error_message = "hardening_profile must be one of: base, cis-l1, cis-l2."
  }
}

# Short git commit of this build tree, for in-image provenance. The Makefile
# passes this automatically; defaults to "nogit" for a bare `packer build`.
variable "git_sha" {
  type    = string
  default = "nogit"
}

# Space-separated NTP hosts for chrony (e.g. "ntp1.corp ntp2.corp"). If set, the
# public Ubuntu pool is disabled in the image (airgap-safe). Empty = keep pool.
variable "ntp_servers" {
  type    = string
  default = ""
}

# Apply security updates on first boot (cloud-init package_upgrade), like the
# stock AWS/Azure images. Off by default — it slows first boot.
variable "patch_on_first_boot" {
  type    = bool
  default = false
}

locals {
  base_image = "${path.root}/build/noble-server-cloudimg-amd64.img"
  base_sha   = trimspace(file("${path.root}/build/image.sha256"))
}

source "qemu" "ubuntu2404" {
  # Base image (already GPG-verified by prepare.sh) + re-pinned checksum.
  iso_url          = local.base_image
  iso_checksum     = "sha256:${local.base_sha}"
  disk_image       = true
  disk_size        = var.disk_size
  format           = "qcow2"

  accelerator      = "kvm"
  cpus             = 2
  memory           = 2048
  headless         = true
  net_device       = "virtio-net"
  disk_interface   = "virtio"

  # Build-time cloud-init seed: creates a temporary 'packer' user with our
  # ephemeral key so Packer can SSH in. This user is removed in finalize.sh.
  cd_label = "cidata"
  cd_content = {
    "meta-data" = file("${path.root}/seed/meta-data")
    "user-data" = templatefile("${path.root}/seed/user-data.pkrtpl", {
      ssh_pubkey = trimspace(file("${path.root}/build/build_key.pub"))
    })
  }

  ssh_username         = "packer"
  ssh_private_key_file = "${path.root}/build/build_key"
  ssh_timeout          = "10m"

  shutdown_command = "sudo shutdown -P now"
  output_directory = "${var.output_dir}/${var.hardening_profile}"
  vm_name          = "${var.image_name}-${var.hardening_profile}.qcow2"

  qemuargs = [["-serial", "stdio"]]
}

build {
  sources = ["source.qemu.ubuntu2404"]

  # 1. HCS contract: virtio/initramfs, cloud-init datasource, datasource-driven
  #    networking, fstab->UUID, time sync, Pro client, optional first-boot patch.
  #    (The one-click password-reset agent is installed offline in finalize.sh,
  #    since the package is specific to your HCS environment.)
  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "NTP_SERVERS=${var.ntp_servers}",
      "PATCH_ON_FIRST_BOOT=${var.patch_on_first_boot}",
    ]
    script = "${path.root}/scripts/10-hcs-prep.sh"
  }

  # 2. Hardening tier (base = skipped; cis-l1 / cis-l2 applied).
  provisioner "shell" {
    execute_command  = "sudo -E bash '{{ .Path }}'"
    environment_vars = ["HARDENING_PROFILE=${var.hardening_profile}"]
    script           = "${path.root}/scripts/20-harden.sh"
  }

  # 3. Seal: strip instance identity + logs, stamp in-image provenance.
  provisioner "shell" {
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_PROFILE=${var.hardening_profile}",
      "GIT_SHA=${var.git_sha}",
      "BASE_SHA=${local.base_sha}",
    ]
    script = "${path.root}/scripts/99-seal.sh"
  }
}
