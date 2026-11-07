# devcontainer.retrocpu-tools

Static musl builds of retro-CPU oracle tools, plus diagnostics assembled
with them, for the Radio-86RK / i8080 sub-projects.

| Component | Source (pinned submodule) | Licence |
| --- | --- | --- |
| `altairz80` (Open SIMH) | `sources/simh` | X11-style, see `sources/simh/LICENSE.txt` |
| `asl`, `p2bin`, `p2hex` (Macroassembler AS) | `sources/asl-releases` (branch `upstream`) | GPL-2.0 |
| `8080PRE`, `8080EX1` exercisers | `sources/i8080-core/asm` | GPL-2.0+ (Cringle, Bartholomew) |

Only clearly redistributable components are used: no TST8080, no CPUTEST.
The `.COM` files in `sources/i8080-core/assets` are used only as an
independent byte-for-byte reference for the AS output, never shipped.
Everything runs from a Debian devcontainer that builds in Alpine through
Docker (`make build`).
