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
# .cache/ccache seeds the Verilator compile cache (GitHub Actions cache in CI)
# and is refreshed from the same build, whose layers the second call reuses.
CCACHE_DIR = .cache/ccache
build: meta
	mkdir -p $(CCACHE_DIR)
	$(DOCKER_BUILD) --build-context meta=.cache/meta --build-context ccache=$(CCACHE_DIR) --target dist --output type=local,dest=dist .
	$(DOCKER_BUILD) --build-context meta=.cache/meta --build-context ccache=$(CCACHE_DIR) --target ccache-out --output type=local,dest=$(CCACHE_DIR).new .
	rm -rf $(CCACHE_DIR) && mv $(CCACHE_DIR).new $(CCACHE_DIR)

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

# vm80a_sim: FST waveforms (+fst=); vm80a_sim_fast: none, built for speed.
# Keep the flags in step with scripts/build-vm80a-sim.sh.
VM80A_VFLAGS = --binary --timing --top-module i8080_tb --x-initial unique -O3 -CFLAGS -O3 \
	-Wno-fatal -Wno-lint -Wno-style
VM80A_GTKWAVE = $(shell verilator --getenv VERILATOR_ROOT)/include/gtkwave

$(VM80A_OUT)/verilator/vm80a_sim: $(VM80A_HDL) $(VM80A_RTL) hdl/vm80a/trace.vlt
	mkdir -p $(@D)
	verilator $(VM80A_VFLAGS) --trace-fst -DVM80A_FST -Mdir $(@D)/obj -o vm80a_sim \
		hdl/vm80a/trace.vlt $(VM80A_HDL) $(VM80A_RTL)
	cp $(@D)/obj/vm80a_sim $@

$(VM80A_OUT)/verilator/vm80a_sim_fast: $(VM80A_HDL) $(VM80A_RTL)
	mkdir -p $(@D)
	verilator $(VM80A_VFLAGS) -Mdir $(@D)/obj-fast -o vm80a_sim_fast $(VM80A_HDL) $(VM80A_RTL)
	cp $(@D)/obj-fast/vm80a_sim_fast $@

$(VM80A_OUT)/fstdump: scripts/fstdump.c
	mkdir -p $(@D)
	$(CC) -O2 -DFST_CONFIG_INCLUDE='"fst_config.h"' -I$(VM80A_GTKWAVE) -o $@ $< \
		$(VM80A_GTKWAVE)/fstapi.c $(VM80A_GTKWAVE)/lz4.c $(VM80A_GTKWAVE)/fastlz.c -lz -lpthread

vm80a-test: $(VM80A_OUT)/icarus/tb.vvp $(VM80A_OUT)/verilator/vm80a_sim $(VM80A_OUT)/verilator/vm80a_sim_fast $(VM80A_OUT)/fstdump
	scripts/test-vm80a.sh $(VM80A_OUT)
