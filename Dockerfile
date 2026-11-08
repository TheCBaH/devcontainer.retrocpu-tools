# syntax=docker/dockerfile:1
ARG ALPINE_IMAGE=alpine:3.22
FROM ${ALPINE_IMAGE} AS builder
RUN apk add --no-cache build-base cmake ninja git patch tar xz file

FROM builder AS tools
COPY sources/simh /src/simh
COPY sources/asl-releases /src/asl-releases
COPY scripts/build-simh.sh scripts/build-asl.sh /repo/scripts/
RUN /repo/scripts/build-simh.sh /src/simh /opt/retrocpu \
 && /repo/scripts/build-asl.sh /src/asl-releases /opt/retrocpu

FROM tools AS diagnostics
COPY sources/i8080-core /repo/sources/i8080-core
COPY patches /repo/patches
COPY asm /repo/asm
COPY scripts/build-diagnostics.sh /repo/scripts/
RUN /repo/scripts/build-diagnostics.sh /repo /opt/retrocpu/bin /opt/retrocpu/share/diagnostics

FROM builder AS verilator
RUN apk add --no-cache autoconf automake flex flex-dev bison help2man perl python3 bash ccache zlib-dev zlib-static
ENV CCACHE_DIR=/ccache CCACHE_MAXSIZE=400M CCACHE_COMPRESS=1
# Seeded from the GitHub Actions cache; verilator itself picks ccache up for the model
COPY --from=ccache . /ccache

FROM verilator AS vm80a-sim
COPY sources/verilator /src/verilator
COPY hdl/vm80a/harness.v hdl/vm80a/trace.vlt /repo/hdl/vm80a/
COPY sources/vm80a/org/rtl/vm80a.v /repo/sources/vm80a/org/rtl/
COPY scripts/build-vm80a-sim.sh scripts/fstdump.c /repo/scripts/
RUN /repo/scripts/build-vm80a-sim.sh /repo /src/verilator /opt/verilator /opt/vm80a-sim

FROM scratch AS ccache-out
COPY --from=vm80a-sim /ccache/ /

FROM diagnostics AS package
ARG ARCH
RUN apk add --no-cache python3
COPY --from=vm80a-sim /opt/vm80a-sim /opt/vm80a-sim
COPY LICENSE versions.env /repo/
COPY licenses /repo/licenses
COPY scripts /repo/scripts
COPY run /repo/run
COPY --from=meta . /meta
COPY sources/simh/LICENSE.txt sources/simh/scp.c /repo/sources/simh/
COPY sources/simh/AltairZ80 /repo/sources/simh/AltairZ80
COPY sources/simh/sim_*.c sources/simh/sim_*.h /repo/sources/simh/
COPY sources/asl-releases/COPYING /repo/sources/asl-releases/
COPY sources/verilator/LICENSE sources/verilator/Artistic /repo/sources/verilator/
COPY sources/verilator/include/gtkwave/fstapi.c sources/verilator/include/gtkwave/lz4.c sources/verilator/include/gtkwave/fastlz.c /repo/sources/verilator/include/gtkwave/
COPY sources/vm80a/license.md /repo/sources/vm80a/
COPY sources/vm80a/org/rtl/vm80a.v /repo/sources/vm80a/org/rtl/
COPY hdl /repo/hdl
COPY fixtures /repo/fixtures
RUN /repo/scripts/package.sh /repo /meta /opt/retrocpu /dist "${ARCH}" /opt/vm80a-sim

FROM scratch AS dist
COPY --from=package /dist/ /
