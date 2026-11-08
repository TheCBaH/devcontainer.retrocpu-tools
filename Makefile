include versions.env
ARCH := $(shell uname -m | sed 's/arm64/aarch64/')
DOCKER_BUILD = docker build --build-arg ALPINE_IMAGE=$(ALPINE_IMAGE) --build-arg ARCH=$(ARCH)

.PHONY: submodule meta build test vm80a-submodule vm80a-test
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

# vm80a pin-level harness: Icarus Verilog and Verilator (needs iverilog, verilator, python3)
VM80A_RTL = sources/vm80a/org/rtl/vm80a.v
VM80A_HDL = hdl/vm80a/harness.v
VM80A_OUT = build/vm80a

vm80a-submodule:
	git -c safe.directory="$(CURDIR)" -c safe.directory="$(CURDIR)/*" submodule update --init --depth 1 sources/vm80a

$(VM80A_OUT)/icarus/tb.vvp: $(VM80A_HDL) $(VM80A_RTL)
	mkdir -p $(@D)
	iverilog -g2012 -Wall -Wno-timescale -s i8080_tb -o $@ $(VM80A_HDL) $(VM80A_RTL)

$(VM80A_OUT)/verilator/vm80a_sim: $(VM80A_HDL) $(VM80A_RTL)
	mkdir -p $(@D)
	verilator --binary --timing --trace --top-module i8080_tb --x-initial unique \
		-Wno-fatal -Wno-lint -Wno-style -Mdir $(@D)/obj -o vm80a_sim $(VM80A_HDL) $(VM80A_RTL)
	cp $(@D)/obj/vm80a_sim $@

vm80a-test: $(VM80A_OUT)/icarus/tb.vvp $(VM80A_OUT)/verilator/vm80a_sim
	scripts/test-vm80a.sh $(VM80A_OUT)
