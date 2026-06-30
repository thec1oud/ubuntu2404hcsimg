# Makefile — build the HCS Ubuntu 24.04 image catalogue.
#
#   make setup      -> install host deps (qemu, packer, etc.) — run once per build host
#   make base       -> dist/ubuntu-2404-hcs-base-<sha>.qcow2
#   make cis-l1     -> dist/ubuntu-2404-hcs-cis-l1-<sha>.qcow2
#   make cis-l2     -> dist/ubuntu-2404-hcs-cis-l2-<sha>.qcow2
#   make all        -> all three (each build runs validate.sh automatically)
#
# Optional overrides:
#   make cis-l1 NTP_SERVERS="ntp1.corp ntp2.corp"
#   make cis-l1 PATCH=true
#   make cis-l1 RESET_AGENT=/path/CloudResetPwdAgent.zip   # (skip with key-only)
#   make base ACCEL=tcg                                     # software emulation (no /dev/kvm)
#   make cis-l1 HARDEN_TMP=false                           # skip noexec on /tmp (exec-from-tmp workloads)
#   make cis-l1 SSH_PERMIT_ROOT=no                         # fully block root SSH (default: prohibit-password)
#
# Validation (offline, on the built qcow2):
#   make check-base / make check-cis-l1 / make check-cis-l2
#   make check          -> all three
#   make check-base IMAGE_SHA=abc1234   # check a build from a different commit
# On-instance (after deploying to HCS):
#   ssh ubuntu@<ip> 'bash -s' < scripts/validate-instance.sh
#
SHELL      := /bin/bash
IMAGE_NAME := ubuntu-2404-hcs
SHA        := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit)
DIST       := dist

# IMAGE_SHA: the commit SHA embedded in the dist/ filename to check.
# Defaults to the current git HEAD. Override when validating a build made at an
# earlier commit:  make check-base IMAGE_SHA=abc1234
IMAGE_SHA  ?= $(SHA)

PACKER_VARS := -var 'git_sha=$(SHA)'
ifdef NTP_SERVERS
PACKER_VARS += -var 'ntp_servers=$(NTP_SERVERS)'
endif
ifdef PATCH
PACKER_VARS += -var 'patch_on_first_boot=$(PATCH)'
endif
ifdef ACCEL
PACKER_VARS += -var 'accelerator=$(ACCEL)'
endif
ifdef HARDEN_TMP
PACKER_VARS += -var 'harden_tmp=$(HARDEN_TMP)'
endif
ifdef SSH_PERMIT_ROOT
PACKER_VARS += -var 'ssh_permit_root=$(SSH_PERMIT_ROOT)'
endif

.PHONY: all base cis-l1 cis-l2 prepare init validate setup check check-base check-cis-l1 check-cis-l2 clean distclean

all: base cis-l1 cis-l2

prepare: build/image.sha256
build/image.sha256:
	./prepare.sh

setup:
	@echo "=== Installing build dependencies ==="
	sudo apt-get -o DPkg::Lock::Timeout=60 update -qq
	sudo apt-get -o DPkg::Lock::Timeout=60 install -y qemu-system-x86 qemu-utils libguestfs-tools gnupg curl xorriso
	@if ! { command -v packer &>/dev/null && packer version 2>/dev/null | grep -qE '^Packer v[0-9]'; }; then \
	  echo "--- Installing HashiCorp Packer ---"; \
	  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; \
	  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $$(. /etc/os-release && echo $$VERSION_CODENAME) main" \
	    | sudo tee /etc/apt/sources.list.d/hashicorp.list; \
	  sudo apt-get -o DPkg::Lock::Timeout=60 update -qq && sudo apt-get -o DPkg::Lock::Timeout=60 install -y packer; \
	fi
	chmod +x validate.sh scripts/validate-instance.sh
	@echo "=== Setup complete — run 'make prepare' next ==="

init:
	packer init .
	chmod +x validate.sh scripts/validate-instance.sh

validate: prepare init
	packer validate $(PACKER_VARS) .

# One recipe, three profiles. $@ is the profile name (= hardening_profile).
base cis-l1 cis-l2: prepare init
	@echo "=== Building profile: $@  (commit $(SHA)) ==="
	rm -rf output/$@
	packer build $(PACKER_VARS) -var 'hardening_profile=$@' .
	./finalize.sh output/$@/$(IMAGE_NAME)-$@.qcow2 $(RESET_AGENT)
	@mkdir -p $(DIST)
	cp output/$@/$(IMAGE_NAME)-$@.qcow2 $(DIST)/$(IMAGE_NAME)-$@-$(SHA).qcow2
	bash validate.sh $(DIST)/$(IMAGE_NAME)-$@-$(SHA).qcow2 $@
	@{ \
	  echo '{'; \
	  echo '  "image": "$(IMAGE_NAME)",'; \
	  echo '  "hardening_profile": "$@",'; \
	  echo '  "git_commit": "$(SHA)",'; \
	  echo "  \"base_image_sha256\": \"$$(cat build/image.sha256)\","; \
	  echo "  \"artifact_sha256\": \"$$(sha256sum $(DIST)/$(IMAGE_NAME)-$@-$(SHA).qcow2 | cut -d' ' -f1)\","; \
	  echo "  \"built_utc\": \"$$(date -u +%Y-%m-%dT%H:%M:%SZ)\""; \
	  echo '}'; \
	} > $(DIST)/$(IMAGE_NAME)-$@-$(SHA).manifest.json
	@echo "=== Done: $(DIST)/$(IMAGE_NAME)-$@-$(SHA).qcow2 (+ .manifest.json) ==="

# Standalone image validation (offline, no HCS needed).
# 'make check-<sku>' re-runs validate.sh against a previously built image.
# 'make check' validates all three SKUs.
check: check-base check-cis-l1 check-cis-l2

check-base check-cis-l1 check-cis-l2:
	@test -f $(DIST)/$(IMAGE_NAME)-$(subst check-,,$@)-$(IMAGE_SHA).qcow2 || \
	  { echo "ERROR: $(DIST)/$(IMAGE_NAME)-$(subst check-,,$@)-$(IMAGE_SHA).qcow2 not found — run 'make $(subst check-,,$@)' first (or pass IMAGE_SHA=<sha> to target a specific build)"; exit 1; }
	bash validate.sh $(DIST)/$(IMAGE_NAME)-$(subst check-,,$@)-$(IMAGE_SHA).qcow2 $(subst check-,,$@)

clean:
	rm -rf output

distclean: clean
	rm -rf dist build
