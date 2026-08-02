.PHONY: build build-latest run shell clean tag-latest build-builder-tools

USER_UID := $(shell id -u)
USER_GID := $(shell id -g)
VERSION ?=

COMMON_DOCKER_FLAGS := --rm -it --workdir /workspace --read-only --tmpfs /tmp:exec,size=512m --cap-drop=ALL --security-opt=no-new-privileges --memory=2g --cpus=2
COMMON_VOLUME_FLAGS := -v $(shell pwd)/homebase:/app:rw -v $(shell pwd)/config:/app/.config/opencode:rw -v $(shell pwd)/workspace:/workspace:rw -v $(shell pwd)/secrets:/run/secrets:ro

build:
	docker build --build-arg USER_UID=$(USER_UID) --build-arg USER_GID=$(USER_GID) $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),) -t opencode-docker$(if $(VERSION),:$(VERSION),) .

build-builder-tools:
	docker build --build-arg USER_UID=$(USER_UID) --build-arg USER_GID=$(USER_GID) $(if $(VERSION),--build-arg OPENCODE_VERSION=$(VERSION),) --target builder-tools -t opencode-docker:builder-tools .

tag-latest:
ifndef VERSION
	$(error VERSION is required. Usage: make tag-latest VERSION=1.3.17)
endif
	docker tag opencode-docker:$(VERSION) opencode-docker:latest

build-latest:
	@VERSION=$$(curl -s https://api.github.com/repos/anomalyco/opencode/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
	echo "Building opencode-docker:$$VERSION..." && \
	$(MAKE) build VERSION=$$VERSION && \
	$(MAKE) tag-latest VERSION=$$VERSION

# Development targets: use local directories (./homebase, ./workspace, ./secrets)
# For regular use, prefer: bin/opencode-docker (uses ~/.opencode-docker/)

run:
	docker run $(COMMON_DOCKER_FLAGS) \
		$(COMMON_VOLUME_FLAGS) \
		opencode-docker:latest

shell: build-builder-tools
	docker run $(COMMON_DOCKER_FLAGS) \
		$(COMMON_VOLUME_FLAGS) \
		--entrypoint /bin/bash \
		opencode-docker:builder-tools

clean:
	docker rmi opencode-docker || true
