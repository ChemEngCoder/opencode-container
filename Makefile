.PHONY: build build-latest tag-latest shell inspect test clean prune-cache

# Single runtime; falls back to singularity, override with APPTAINER=/path/to/bin
APPTAINER ?= $(shell command -v apptainer 2>/dev/null || command -v singularity 2>/dev/null || echo apptainer)

# Apptainer >= 1.1 builds unprivileged via fakeroot emulation. On older
# releases, or if your kernel disallows unprivileged user namespaces:
#   make build SUDO=sudo
SUDO ?=

DEF ?= opencode-container.def
IMAGE_DIR ?= images
IMAGE_NAME ?= opencode-container
VERSION ?=

SIF := $(IMAGE_DIR)/$(IMAGE_NAME)$(if $(VERSION),-$(VERSION),).sif
LATEST_SIF := $(IMAGE_DIR)/$(IMAGE_NAME).sif

# Build args require Apptainer >= 1.3
BUILD_ARGS := $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),)

# Apptainer forwards proxy variables into %post and into the docker layer fetch,
# so they only need to be present in the build environment -- no --build-arg
# matrix. Normalize so both cases are set regardless of which the caller exported.
HTTP_PROXY_EFF := $(or $(HTTP_PROXY),$(http_proxy))
HTTPS_PROXY_EFF := $(or $(HTTPS_PROXY),$(https_proxy))
NO_PROXY_EFF := $(or $(NO_PROXY),$(no_proxy))
PROXY_ENV := $(strip \
    $(if $(HTTP_PROXY_EFF),HTTP_PROXY=$(HTTP_PROXY_EFF) http_proxy=$(HTTP_PROXY_EFF),) \
    $(if $(HTTPS_PROXY_EFF),HTTPS_PROXY=$(HTTPS_PROXY_EFF) https_proxy=$(HTTPS_PROXY_EFF),) \
    $(if $(NO_PROXY_EFF),NO_PROXY=$(NO_PROXY_EFF) no_proxy=$(NO_PROXY_EFF),))

build: $(SIF)

# Unlike a Dockerfile, the output is a real file, so make can do real
# dependency tracking: the image rebuilds only when its inputs change.
$(SIF): $(DEF) bootstrap.py
	@mkdir -p $(IMAGE_DIR)
	$(SUDO) env $(PROXY_ENV) $(APPTAINER) build --force $(BUILD_ARGS) $@ $(DEF)

tag-latest:
ifndef VERSION
	$(error VERSION is required. Usage: make tag-latest VERSION=1.18.25)
endif
	ln -sfn $(IMAGE_NAME)-$(VERSION).sif $(LATEST_SIF)

build-latest:
	@VERSION=$$(curl -s https://api.github.com/repos/anomalyco/opencode/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
	echo "Building $(IMAGE_NAME)-$$VERSION.sif..." && \
	$(MAKE) build VERSION=$$VERSION && \
	$(MAKE) tag-latest VERSION=$$VERSION

# Debug shell in the real runtime image -- no separate builder stage needed.
shell: $(LATEST_SIF)
	$(APPTAINER) shell --containall --workdir $$(mktemp -d) \
		--bind $(CURDIR):/workspace:rw --pwd /workspace $(LATEST_SIF)

inspect: $(LATEST_SIF)
	$(APPTAINER) inspect $(LATEST_SIF)
	$(APPTAINER) inspect --runscript $(LATEST_SIF)

test: $(LATEST_SIF)
	$(APPTAINER) test $(LATEST_SIF)

clean:
	rm -f $(IMAGE_DIR)/$(IMAGE_NAME)*.sif

prune-cache:
	$(APPTAINER) cache clean --force
