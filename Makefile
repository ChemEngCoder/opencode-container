.PHONY: build build-latest shell clean tag-latest build-builder-tools prune-cache

ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
USER_UID := $(shell id -u)
USER_GID := $(shell id -g)
VERSION ?=

build:
	$(ENGINE) build --build-arg USER_UID=$(USER_UID) --build-arg USER_GID=$(USER_GID) $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),) -t opencode-container$(if $(VERSION),:$(VERSION),) .

build-builder-tools:
	$(ENGINE) build --build-arg USER_UID=$(USER_UID) --build-arg USER_GID=$(USER_GID) $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),) --target builder-tools -t opencode-container:builder-tools .

tag-latest:
ifndef VERSION
	$(error VERSION is required. Usage: make tag-latest VERSION=1.18.18)
endif
	$(ENGINE) tag opencode-container:$(VERSION) opencode-container:latest

build-latest:
	@VERSION=$$(curl -s https://api.github.com/repos/anomalyco/opencode/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
	echo "Building opencode-container:$$VERSION..." && \
	$(MAKE) build VERSION=$$VERSION && \
	$(MAKE) tag-latest VERSION=$$VERSION

shell: build-builder-tools
	mkdir -p homebase config workspace secrets
	$(ENGINE) run --rm -it --workdir /workspace --read-only \
		--tmpfs /tmp:exec,size=512m,mode=1777 --cap-drop=ALL \
		--security-opt=no-new-privileges --memory=2g --cpus=2 \
		-v $(shell pwd)/homebase:/app:rw \
		-v $(shell pwd)/config:/app/.config/opencode:rw \
		-v $(shell pwd)/workspace:/workspace:rw \
		-v $(shell pwd)/secrets:/run/secrets:ro \
		--entrypoint /bin/bash \
		opencode-container:builder-tools

clean:
	$(ENGINE) rmi opencode-container || true

prune-cache:
	$(ENGINE) builder prune -af
