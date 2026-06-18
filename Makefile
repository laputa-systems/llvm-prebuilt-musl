LLVM_VERSION ?= 22.1.8
LLVM_ARCH     ?= $(shell uname -m | sed 's/arm64/aarch64/')
DOCKER_TAG    := llvm-prebuilt-musl:alpine
ifeq ($(shell uname -m),arm64)
  DOCKER_PLATFORM := linux/arm64
else
  DOCKER_PLATFORM := linux/amd64
endif
USE_CCACHE    ?= 1

LLVM_TARBALL  := llvm-project-$(LLVM_VERSION).src.tar.xz
LLVM_URL      := https://github.com/llvm/llvm-project/releases/download/llvmorg-$(LLVM_VERSION)/$(LLVM_TARBALL)
LLVM_DIR      ?= $(shell pwd)/../llvm-project-$(LLVM_VERSION).src
WORKDIR       := $(shell pwd)

.PHONY: all build source docker-image clean distclean

all: build

build: source docker-image
	@echo "=== Building LLVM $(LLVM_VERSION) for $(LLVM_ARCH) ==="
	@mkdir -p "$(LLVM_DIR)" "$(WORKDIR)/llvm-install" "$(WORKDIR)/llvm-build" "$(WORKDIR)/llvm-host"
ifeq ($(USE_CCACHE),1)
	docker volume create llvm-musl-ccache 2>/dev/null || true
	docker run --rm --platform $(DOCKER_PLATFORM) \
		-v "$(WORKDIR):/work/llvm-prebuilt" \
		-v "$(LLVM_DIR):/work/llvm-project" \
		-v "$(WORKDIR)/llvm-install:/work/llvm-install" \
		-v "$(WORKDIR)/llvm-build:/work/llvm-build" \
		-v "$(WORKDIR)/llvm-host:/work/llvm-host" \
		-v llvm-musl-ccache:/root/.ccache \
		-e LLVM_VERSION=$(LLVM_VERSION) \
		-e LLVM_ARCH=$(LLVM_ARCH) \
		-e LLVM_USE_CCACHE=1 \
		-e CCACHE_DIR=/root/.ccache \
		-e CCACHE_COMPRESS=1 \
		$(DOCKER_TAG) /work/llvm-prebuilt/scripts/build-llvm-musl.sh
else
	docker run --rm --platform $(DOCKER_PLATFORM) \
		-v "$(WORKDIR):/work/llvm-prebuilt" \
		-v "$(LLVM_DIR):/work/llvm-project" \
		-v "$(WORKDIR)/llvm-install:/work/llvm-install" \
		-v "$(WORKDIR)/llvm-build:/work/llvm-build" \
		-v "$(WORKDIR)/llvm-host:/work/llvm-host" \
		-e LLVM_VERSION=$(LLVM_VERSION) \
		-e LLVM_ARCH=$(LLVM_ARCH) \
		$(DOCKER_TAG) /work/llvm-prebuilt/scripts/build-llvm-musl.sh
endif

source: $(LLVM_DIR)

$(LLVM_DIR):
	@echo "=== Downloading LLVM $(LLVM_VERSION) source ==="
	curl -fsSL -o /tmp/$(LLVM_TARBALL) "$(LLVM_URL)"
	mkdir -p "$(LLVM_DIR)"
	tar -xf /tmp/$(LLVM_TARBALL) -C "$(LLVM_DIR)" --strip-components=1
	rm -f /tmp/$(LLVM_TARBALL)

docker-image:
	@echo "=== Building Docker image ==="
	docker build --platform $(DOCKER_PLATFORM) \
		-f docker/alpine-llvm-musl.Dockerfile \
		-t $(DOCKER_TAG) .

clean:
	@echo "=== Cleaning build artifacts ==="
	rm -rf "$(WORKDIR)/llvm-install" "$(WORKDIR)/llvm-host" "$(WORKDIR)/llvm-build"

distclean: clean
	@echo "=== Full clean (including source and image) ==="
	rm -rf "$(LLVM_DIR)"
	docker rmi $(DOCKER_TAG) 2>/dev/null || true
	docker volume rm llvm-musl-ccache 2>/dev/null || true

.DEFAULT_GOAL := build
