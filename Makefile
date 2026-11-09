# Local entry points. CI runs the same targets.
#
#   make build       fetch + verify the pinned source, build and package in a container
#   make validate    test the package in a clean container
#   make             both
#
# LLVM_ARCH selects the package (x86_64 or aarch64) and defaults to the host
# architecture; the matching Docker platform is derived from it.

include llvm-source.env
include musl-source.env
include zlib-source.env

LLVM_ARCH ?= $(shell uname -m)
ARCH := $(patsubst amd64,x86_64,$(patsubst arm64,aarch64,$(LLVM_ARCH)))
ifeq ($(ARCH),x86_64)
  DOCKER_PLATFORM := linux/amd64
else ifeq ($(ARCH),aarch64)
  DOCKER_PLATFORM := linux/arm64
else
  $(error LLVM_ARCH must be x86_64 or aarch64, got '$(LLVM_ARCH)')
endif

# Generated files live under WORK_DIR (ignored by git). LLVM_DIR may point at
# an existing checkout of the pinned release; it is patched but never removed.
WORK_DIR          ?= $(CURDIR)/work
LLVM_DIR          ?= $(WORK_DIR)/llvm-project-$(LLVM_VERSION)
MUSL_DIR          ?= $(WORK_DIR)/musl-$(MUSL_VERSION)
ZLIB_DIR          ?= $(WORK_DIR)/zlib-$(ZLIB_VERSION)
ZLIB_DOWNLOAD_DIR ?= $(LLVM_DOWNLOAD_DIR)
LLVM_DOWNLOAD_DIR ?= $(WORK_DIR)/download
MUSL_DOWNLOAD_DIR ?= $(LLVM_DOWNLOAD_DIR)
CCACHE_HOST_DIR   ?= $(WORK_DIR)/ccache
USE_CCACHE        ?= 1
LLVM_PARALLEL_LINK_JOBS ?= 2
STATE_DIR         := $(WORK_DIR)/$(ARCH)
export LLVM_VERSION LLVM_SOURCE_SHA256 LLVM_DIR LLVM_DOWNLOAD_DIR
export MUSL_VERSION MUSL_SOURCE_SHA256 MUSL_DIR MUSL_DOWNLOAD_DIR
export ZLIB_VERSION ZLIB_SOURCE_SHA256 ZLIB_DIR ZLIB_DOWNLOAD_DIR

PACKAGE        := clang+llvm-$(LLVM_VERSION)-$(ARCH)-linux-musl
BUILD_IMAGE    := llvm-prebuilt-musl-build:$(ARCH)
VALIDATE_IMAGE := llvm-prebuilt-musl-validate:$(ARCH)

.PHONY: all build validate source build-image validate-image clean distclean
.DEFAULT_GOAL := all

all: build validate

source:
	scripts/fetch-llvm-source.sh
	scripts/fetch-musl-source.sh
	scripts/fetch-zlib-source.sh

build-image:
	docker build --platform $(DOCKER_PLATFORM) -f docker/build.Dockerfile -t $(BUILD_IMAGE) docker

validate-image:
	docker build --platform $(DOCKER_PLATFORM) -f docker/validate.Dockerfile -t $(VALIDATE_IMAGE) docker

# One container runs every build phase (scripts/build.sh). It runs as the
# invoking user so nothing under WORK_DIR ends up root-owned.
build: source build-image
	mkdir -p "$(STATE_DIR)" "$(CCACHE_HOST_DIR)"
	docker run --rm --platform $(DOCKER_PLATFORM) --user "$$(id -u):$$(id -g)" \
		-v "$(CURDIR):/work/repo:ro" \
		-v "$(LLVM_DIR):/work/src" \
		-v "$(MUSL_DIR):/work/musl-src:ro" \
		-v "$(ZLIB_DIR):/work/zlib-src:ro" \
		-v "$(STATE_DIR):/work/state" \
		-v "$(CCACHE_HOST_DIR):/ccache" \
		-e HOME=/tmp \
		-e LLVM_VERSION=$(LLVM_VERSION) \
		-e MUSL_VERSION=$(MUSL_VERSION) \
		-e ZLIB_VERSION=$(ZLIB_VERSION) \
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

# The validation container has no network, no source, and no build tree: only
# the package, the test programs, and the validation script.
validate: validate-image
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

# Removes this architecture's build tree, install tree, and packages. The
# source, downloads, and ccache stay. The last line removes leftovers of the
# previous bootstrap layout.
clean:
	rm -rf "$(STATE_DIR)"
	rm -rf llvm-build llvm-host llvm-install build-*.log

distclean: clean
	rm -rf "$(WORK_DIR)/x86_64" "$(WORK_DIR)/aarch64" "$(WORK_DIR)/download" "$(WORK_DIR)/ccache"
	test "$(LLVM_DIR)" != "$(WORK_DIR)/llvm-project-$(LLVM_VERSION)" || rm -rf "$(LLVM_DIR)"
	test "$(MUSL_DIR)" != "$(WORK_DIR)/musl-$(MUSL_VERSION)" || rm -rf "$(MUSL_DIR)"
	test "$(ZLIB_DIR)" != "$(WORK_DIR)/zlib-$(ZLIB_VERSION)" || rm -rf "$(ZLIB_DIR)"
	-docker rmi $(BUILD_IMAGE) $(VALIDATE_IMAGE)
