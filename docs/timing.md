# Diagnostic timings

`altairz80` with `set cpu 8080`, unthrottled, non-root, read-only root
filesystem. Wall clock of `docker run`, so container start (about 1 s) is
included. CI run 42403865430 at `5ef3d22`; local run on an aarch64 Docker host.

| Host | Image | 8080PRE | 8080EX1 (25 groups, all OK) |
| --- | --- | --- | --- |
| GitHub `ubuntu-24.04` (x86_64) | Debian 12 slim | 1 s | 28 s |
| GitHub `ubuntu-24.04` (x86_64) | Alpine 3.22 | 1 s | 28 s |
| GitHub `ubuntu-24.04-arm` (aarch64) | Debian 12 slim | 1 s | 18 s |
| GitHub `ubuntu-24.04-arm` (aarch64) | Alpine 3.22 | 1 s | 18 s |
| local aarch64 Docker host | both | 1 s | 16 s |

The exerciser is cheap enough to run on every push.
