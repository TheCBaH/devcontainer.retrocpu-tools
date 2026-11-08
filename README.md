# devcontainer.retrocpu-tools

[![build](https://github.com/TheCBaH/devcontainer.retrocpu-tools/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/TheCBaH/devcontainer.retrocpu-tools/actions/workflows/build.yml)

Static musl builds of retro-CPU oracle tools for x86_64 and aarch64, plus
the i8080 diagnostics assembled with them, for the Radio-86RK / i8080
sub-projects.

| Component | Source (pinned submodule) | Licence |
| --- | --- | --- |
| `altairz80` (Open SIMH) | `sources/simh` | X11-style, `sources/simh/LICENSE.txt` |
| `asl`, `p2bin`, `p2hex` (Macroassembler AS) | `sources/asl-releases` (branch `upstream`) | GPL-2.0-only OR GPL-3.0-only |
| `8080PRE`, `8080EX1` exercisers | `sources/i8080-core/asm` | GPL-2.0+ (Cringle, Bartholomew) |

Only clearly redistributable components are used: no TST8080, no CPUTEST.
The `.COM` files in `sources/i8080-core/assets` serve only as an
independent byte-for-byte reference for the AS output and are never shipped.

## Build and test

```sh
make build   # docker build in Alpine; packages land in dist/
make test    # static check, licence listing, diagnostics on Debian and Alpine
```

`make` runs from the Debian devcontainer (Docker outside of Docker) or any
host with Docker.

* CI: the [build workflow](https://github.com/TheCBaH/devcontainer.retrocpu-tools/actions/workflows/build.yml?query=branch%3Amain)
  runs both targets on native `ubuntu-24.04` and `ubuntu-24.04-arm` runners
  for every push to `main` and `devel`.
* Codespace: [![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://github.com/codespaces/new?hide_repo_select=true&ref=main&repo=1449628527)
  opens the devcontainer on `main`; `make submodule` runs on creation.

## Packages

| Archive | Contents |
| --- | --- |
| `retrocpu-tools-linux-<arch>-musl.tar.xz` | `bin/{altairz80,asl,p2bin,p2hex}`, `licenses/` |
| `retrocpu-diagnostics-<arch>.tar.xz` | `8080PRE.COM`, `8080EX1.COM`, K5 shim bytes, SIMH scripts, `source/`, `licenses/` |

`licenses/` in each archive holds the licence texts of every component that
is linked in or was used to produce it (SIMH, AS, musl, the GCC runtime
library exception, the exerciser notices, this repository), with
`LICENSES.md` (component, pin, SPDX id, role, files), `SOURCES.md`
(upstream URLs and revisions) and `SHA256SUMS`. `make test` verifies that
every listed file exists and the checksums hold.

## Diagnostics

Assembling uses patches in `patches/` against `sources/i8080-core/asm`
(M80 macros and operators to AS syntax). `8080PRE.COM` equals the independent
image exactly; for `8080EX1.COM` the first 4535 bytes (the whole program)
are equal, the reference carries 73 bytes of CP/M record padding after it.

Run from the unpacked `retrocpu-diagnostics` directory:

```sh
../retrocpu-tools-x86_64/bin/altairz80 8080PRE.ini   # prints "8080 Preliminary tests complete"
../retrocpu-tools-x86_64/bin/altairz80 8080EX1.ini   # 25 test groups, each "OK"
```

The `.ini` files implement the K5 shim contract in SIMH. SIMH's data port 1
is input-only by default, so they remap it to make `OUT 0x01` the console.
SIMH has no exit-code port: the run ends at the shim's `HLT` after
`OUT 0xFF`; the pass decision comes from the console text only.

Measured durations are recorded in `docs/timing.md`.

## Release

Push a `v*` tag on a commit whose `build` run (push event) succeeded; the
`release` workflow downloads that run's packages for both architectures,
writes one `SHA256SUMS` and creates the GitHub release. It fails if the
commit has no successful build. A tag containing `-` (`v0.1.0-rc1`) is
published as a pre-release.
