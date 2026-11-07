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

FROM diagnostics AS package
ARG ARCH
COPY LICENSE versions.env /repo/
COPY licenses /repo/licenses
COPY scripts /repo/scripts
COPY run /repo/run
COPY --from=meta . /meta
COPY sources/simh/LICENSE.txt sources/simh/scp.c /repo/sources/simh/
COPY sources/simh/AltairZ80 /repo/sources/simh/AltairZ80
COPY sources/simh/sim_*.c sources/simh/sim_*.h /repo/sources/simh/
COPY sources/asl-releases/COPYING /repo/sources/asl-releases/
RUN /repo/scripts/package.sh /repo /meta /opt/retrocpu /dist "${ARCH}"

FROM scratch AS dist
COPY --from=package /dist/ /
