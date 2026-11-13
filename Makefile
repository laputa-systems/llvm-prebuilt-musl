# Local entry points. CI runs the same targets.
#
#   make fetch    download, verify, and extract the sources pinned in sources.lock.json
#   make build    fetch, build and package in a container, then name the release assets
#   make verify   test the package in a clean container and check the release assets
#   make lint     static checks
#   make clean    remove this target's build tree and packages
#   make          build and verify
#
# TARGET selects the package (x86_64-unknown-linux-musl or aarch64-unknown-linux-musl) and
# defaults to the host architecture; the architecture and the matching Docker platform derive
# from it. Versions come from sources.lock.json, which needs jaq (scripts/install-jaq.sh).

UNAME := $(shell uname -sm)
ifeq ($(UNAME),Linux x86_64)
  HOST_TARGET := x86_64-unknown-linux-musl
else ifeq ($(UNAME),Linux aarch64)
  HOST_TARGET := aarch64-unknown-linux-musl
else ifeq ($(UNAME),Linux arm64)
  HOST_TARGET := aarch64-unknown-linux-musl
else ifeq ($(UNAME),Darwin arm64)
  HOST_TARGET := aarch64-unknown-linux-musl
endif

TARGET ?= $(HOST_TARGET)
ifeq ($(TARGET),x86_64-unknown-linux-musl)
  ARCH := x86_64
  DOCKER_PLATFORM := linux/amd64
else ifeq ($(TARGET),aarch64-unknown-linux-musl)
  ARCH := aarch64
  DOCKER_PLATFORM := linux/arm64
else
  $(error TARGET must be x86_64-unknown-linux-musl or aarch64-unknown-linux-musl, got '$(TARGET)')
endif
export TARGET

lock = $(shell jaq -r --arg name '$(1)' --arg field '$(2)' '.inputs[] | select(.name == $$name) | .[$$field] // empty' sources.lock.json)

LLVM_VERSION     := $(call lock,llvm-project,version)
MUSL_VERSION     := $(call lock,musl,version)
ZLIB_VERSION     := $(call lock,zlib,version)
MIMALLOC_VERSION := $(call lock,mimalloc,version)
ifeq ($(strip $(LLVM_VERSION)$(MUSL_VERSION)$(ZLIB_VERSION)$(MIMALLOC_VERSION)),)
  $(error cannot read sources.lock.json; install jaq with scripts/install-jaq.sh)
endif

# Generated files live under WORK_DIR (ignored by git). LLVM_DIR may point at
# an existing checkout of the pinned release; it is patched but never removed.
WORK_DIR          ?= $(CURDIR)/.work
LLVM_DIR          ?= $(WORK_DIR)/$(call lock,llvm-project,dir)
MUSL_DIR          ?= $(WORK_DIR)/$(call lock,musl,dir)
ZLIB_DIR          ?= $(WORK_DIR)/$(call lock,zlib,dir)
MIMALLOC_DIR      ?= $(WORK_DIR)/$(call lock,mimalloc,dir)
LLVM_DOWNLOAD_DIR ?= $(WORK_DIR)/download
MUSL_DOWNLOAD_DIR ?= $(LLVM_DOWNLOAD_DIR)
ZLIB_DOWNLOAD_DIR ?= $(LLVM_DOWNLOAD_DIR)
MIMALLOC_DOWNLOAD_DIR ?= $(LLVM_DOWNLOAD_DIR)
OUT_DIR           ?= $(CURDIR)/dist/release
CCACHE_HOST_DIR   ?= $(WORK_DIR)/ccache
USE_CCACHE        ?= 1
LLVM_PARALLEL_LINK_JOBS ?= 2
STATE_DIR         := $(WORK_DIR)/$(ARCH)
export WORK_DIR STATE_DIR OUT_DIR
export LLVM_DIR LLVM_DOWNLOAD_DIR MUSL_DIR MUSL_DOWNLOAD_DIR
export ZLIB_DIR ZLIB_DOWNLOAD_DIR MIMALLOC_DIR MIMALLOC_DOWNLOAD_DIR

PACKAGE        := clang+llvm-$(LLVM_VERSION)-$(ARCH)-linux-musl
BUILD_IMAGE    := llvm-prebuilt-musl-build:$(ARCH)
VALIDATE_IMAGE := llvm-prebuilt-musl-validate:$(ARCH)

.PHONY: all fetch build compile package verify validate-container lint build-image validate-image clean distclean
.DEFAULT_GOAL := all

all: build verify

fetch:
	sh scripts/fetch-sources.sh

build-image:
	docker build --platform $(DOCKER_PLATFORM) -f docker/build.Dockerfile -t $(BUILD_IMAGE) docker

validate-image:
	docker build --platform $(DOCKER_PLATFORM) -f docker/validate.Dockerfile -t $(VALIDATE_IMAGE) docker

build: compile package

# One container runs every build phase (scripts/build.sh). It runs as the
# invoking user so nothing under WORK_DIR ends up root-owned.
compile: fetch build-image
	mkdir -p "$(STATE_DIR)" "$(CCACHE_HOST_DIR)"
	docker run --rm --platform $(DOCKER_PLATFORM) --user "$$(id -u):$$(id -g)" \
		-v "$(CURDIR):/work/repo:ro" \
		-v "$(LLVM_DIR):/work/src" \
		-v "$(MUSL_DIR):/work/musl-src:ro" \
		-v "$(ZLIB_DIR):/work/zlib-src:ro" \
		-v "$(MIMALLOC_DIR):/work/mimalloc-src:ro" \
		-v "$(STATE_DIR):/work/state" \
		-v "$(CCACHE_HOST_DIR):/ccache" \
		-e HOME=/tmp \
		-e LLVM_VERSION=$(LLVM_VERSION) \
		-e MUSL_VERSION=$(MUSL_VERSION) \
		-e ZLIB_VERSION=$(ZLIB_VERSION) \
		-e MIMALLOC_VERSION=$(MIMALLOC_VERSION) \
		-e LLVM_ARCH=$(ARCH) \
		-e LLVM_USE_CCACHE=$(USE_CCACHE) \
		-e LLVM_PARALLEL_LINK_JOBS=$(LLVM_PARALLEL_LINK_JOBS) \
		-e CCACHE_DIR=/ccache \
		-e CCACHE_COMPRESS=1 \
		-e CCACHE_MAXSIZE=5G \
		-e CCACHE_COMPILERCHECK='%compiler% -v' \
		-e CCACHE_BASEDIR=/work \
		-e CCACHE_NOHASHDIR=1 \
		-e CCACHE_SLOPPINESS=pch_defines,time_macros \
		$(BUILD_IMAGE) bash /work/repo/scripts/build.sh

# Publishes each package under the standard llvm[-dev]-<version>-<target> names with a manifest,
# and under the clang+llvm-<version>-<arch>-linux-musl names that existing consumers pin.
package:
	sh scripts/package.sh "$(OUT_DIR)"

verify: validate-container
	sh scripts/verify-release.sh "$(OUT_DIR)"

# The validation container has no network, no source, and no build tree: only
# the package, the test programs, and the validation script.
validate-container: validate-image
	test -f "$(STATE_DIR)/dist/$(PACKAGE).tar.xz" && test -f "$(STATE_DIR)/dist/$(PACKAGE)-dev.tar.xz" || { echo "run 'make build' first"; exit 1; }
	docker run --rm --platform $(DOCKER_PLATFORM) --network none \
		-v "$(STATE_DIR)/dist:/dist:ro" \
		-v "$(CURDIR)/tests:/tests:ro" \
		-v "$(CURDIR)/scripts/validate.sh:/validate.sh:ro" \
		-v "$(CURDIR)/scripts/check-purity.sh:/check-purity.sh:ro" \
		-e LLVM_VERSION=$(LLVM_VERSION) \
		-e MUSL_VERSION=$(MUSL_VERSION) \
		-e LLVM_ARCH=$(ARCH) \
		$(VALIDATE_IMAGE) bash /validate.sh /dist/$(PACKAGE).tar.xz /dist/$(PACKAGE)-dev.tar.xz

# build.sh predates the lint target; its SC2046 (the mimalloc version split) is excluded until
# it is fixed there. The scripts that run in CI or the host are checked as written.
lint:
	shellcheck -x -S warning -e SC2046 scripts/*.sh
	jaq -e '.schema_version == 1 and (.inputs | length > 0)' sources.lock.json >/dev/null

# Removes this target's build tree, install tree, and packages. The
# source, downloads, and ccache stay. The last line removes leftovers of the
# previous bootstrap layout.
clean:
	rm -rf "$(STATE_DIR)"
	rm -f "$(OUT_DIR)"/llvm-*-$(TARGET).* "$(OUT_DIR)/$(PACKAGE).tar.xz" "$(OUT_DIR)/$(PACKAGE)-dev.tar.xz"
	rm -rf llvm-build llvm-host llvm-install build-*.log

distclean: clean
	rm -rf "$(WORK_DIR)/x86_64" "$(WORK_DIR)/aarch64" "$(WORK_DIR)/download" "$(WORK_DIR)/ccache" "$(CURDIR)/dist"
	test "$(LLVM_DIR)" != "$(WORK_DIR)/llvm-project-$(LLVM_VERSION)" || rm -rf "$(LLVM_DIR)"
	test "$(MUSL_DIR)" != "$(WORK_DIR)/musl-$(MUSL_VERSION)" || rm -rf "$(MUSL_DIR)"
	test "$(ZLIB_DIR)" != "$(WORK_DIR)/zlib-$(ZLIB_VERSION)" || rm -rf "$(ZLIB_DIR)"
	test "$(MIMALLOC_DIR)" != "$(WORK_DIR)/mimalloc-$(MIMALLOC_VERSION)" || rm -rf "$(MIMALLOC_DIR)"
	-docker rmi $(BUILD_IMAGE) $(VALIDATE_IMAGE)
