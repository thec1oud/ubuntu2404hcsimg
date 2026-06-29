# Makefile — build the HCS Ubuntu 24.04 image catalogue.
#
#   make base       -> dist/ubuntu-2404-hcs-base-<sha>.qcow2
#   make cis-l1     -> dist/ubuntu-2404-hcs-cis-l1-<sha>.qcow2
#   make cis-l2     -> dist/ubuntu-2404-hcs-cis-l2-<sha>.qcow2
#   make all        -> all three
#
# Optional overrides:
#   make cis-l1 NTP_SERVERS="ntp1.corp ntp2.corp"
#   make cis-l1 PATCH=true
#   make cis-l1 RESET_AGENT=/path/CloudResetPwdAgent.zip   # (skip with key-only)
#
SHELL      := /bin/bash
IMAGE_NAME := ubuntu-2404-hcs
SHA        := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit)
DIST       := dist

PACKER_VARS := -var 'git_sha=$(SHA)'
ifdef NTP_SERVERS
PACKER_VARS += -var 'ntp_servers=$(NTP_SERVERS)'
endif
ifdef PATCH
PACKER_VARS += -var 'patch_on_first_boot=$(PATCH)'
endif

.PHONY: all base cis-l1 cis-l2 prepare init validate clean distclean

all: base cis-l1 cis-l2

prepare: build/image.sha256
build/image.sha256:
	./prepare.sh

init:
	packer init .

validate: prepare init
	packer validate -var 'git_sha=$(SHA)' .

# One recipe, three profiles. $@ is the profile name (= hardening_profile).
base cis-l1 cis-l2: prepare init
	@echo "=== Building profile: $@  (commit $(SHA)) ==="
	rm -rf output/$@
	packer build $(PACKER_VARS) -var 'hardening_profile=$@' .
	./finalize.sh output/$@/$(IMAGE_NAME)-$@.qcow2 $(RESET_AGENT)
	@mkdir -p $(DIST)
	cp output/$@/$(IMAGE_NAME)-$@.qcow2 $(DIST)/$(IMAGE_NAME)-$@-$(SHA).qcow2
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

clean:
	rm -rf output

distclean: clean
	rm -rf dist build
