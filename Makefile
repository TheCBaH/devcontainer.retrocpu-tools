include versions.env
ARCH := $(shell uname -m | sed 's/arm64/aarch64/')
DOCKER_BUILD = docker build --build-arg ALPINE_IMAGE=$(ALPINE_IMAGE) --build-arg ARCH=$(ARCH)

.PHONY: submodule meta build test
submodule:
	git -c safe.directory="$(CURDIR)" -c safe.directory="$(CURDIR)/*" submodule update --init --depth 1

meta: submodule
	mkdir -p .cache/meta
	git -c safe.directory='*' submodule foreach --quiet \
		'echo "$$(git rev-parse HEAD) $$sm_path $$(git remote get-url origin) $$(git log -1 --format=%s | tr -d "\t")"' \
		> .cache/meta/pins.txt
	git -c safe.directory='*' rev-parse HEAD > .cache/meta/commit

# Static tools, diagnostics and packages in dist/ (built in Alpine/musl)
build: meta
	$(DOCKER_BUILD) --build-context meta=.cache/meta --target dist --output type=local,dest=dist .

test: build
	scripts/test-packages.sh dist
