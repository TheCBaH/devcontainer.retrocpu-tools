FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git ca-certificates curl xz-utils make patch file \
    && rm -rf /var/lib/apt/lists/*
