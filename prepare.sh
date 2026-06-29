#!/usr/bin/env bash
#
# prepare.sh — Establish trust in the base image and set up build inputs.
#
# This is the step that actually addresses "I don't trust their image": we pull
# Canonical's OFFICIAL Ubuntu 24.04 (Noble) cloud image and verify it against
# Canonical's GPG signing key before anything else touches it. Everything the
# Packer build produces is then a modification of an image whose provenance you
# proved yourself.
#
# Outputs (consumed by Packer):
#   build/noble-server-cloudimg-amd64.img   verified base image
#   build/image.sha256                       pinned checksum (fed to Packer)
#   build/build_key , build/build_key.pub    ephemeral SSH key for the build VM
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${HERE}/build"
mkdir -p "${BUILD}"

IMG_NAME="noble-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/noble/current"

# Canonical "UEC Image Automatic Signing Key" — the key that signs the cloud
# image SHA256SUMS. (Note: this is DIFFERENT from the releases.ubuntu.com ISO
# key 8439...EFE21092. We use the cloud image, so this is the correct one.)
CLOUDIMG_KEY="D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"

echo "==> Downloading image, checksum manifest and signature"
cd "${BUILD}"
curl -fLO "${BASE_URL}/${IMG_NAME}"
curl -fLO "${BASE_URL}/SHA256SUMS"
curl -fLO "${BASE_URL}/SHA256SUMS.gpg"

echo "==> Importing Canonical cloud-image signing key"
# Prefer the key shipped in the distro keyring if present; otherwise fetch it.
if [ -f /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg ]; then
  KEYRING=(--keyring /usr/share/keyrings/ubuntu-cloudimage-keyring.gpg --no-default-keyring)
else
  gpg --keyid-format long --keyserver hkp://keyserver.ubuntu.com \
      --recv-keys "0x${CLOUDIMG_KEY}"
  KEYRING=()
fi

echo "==> Verifying the SHA256SUMS signature"
gpg "${KEYRING[@]}" --verify SHA256SUMS.gpg SHA256SUMS

echo "==> Verifying the image hash against the now-trusted manifest"
grep " *${IMG_NAME}\$" SHA256SUMS | sha256sum -c -

# Pin the checksum we just verified, for Packer to re-check.
# Ubuntu SHA256SUMS uses binary format: "hash *filename" — strip the leading *
# before comparing so both "hash  filename" and "hash *filename" are handled.
PINNED_SHA="$(awk -v f="${IMG_NAME}" '{sub(/^\*/, "", $2)} $2 == f {print $1}' SHA256SUMS)"
if [ -z "$PINNED_SHA" ]; then
  echo "ERROR: ${IMG_NAME} not found in SHA256SUMS — cannot pin checksum" >&2
  exit 1
fi
echo "$PINNED_SHA" > image.sha256
echo "==> Verified. Pinned sha256: ${PINNED_SHA}"

echo "==> Generating an ephemeral SSH key for the build VM (not shipped)"
if [ ! -f build_key ]; then
  ssh-keygen -t ed25519 -N "" -C "packer-build-ephemeral" -f build_key
fi

echo "==> prepare.sh complete. You can now run: packer build ."
