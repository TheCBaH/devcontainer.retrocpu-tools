# vm80a pin-level harness

A file-driven Verilog testbench around `vm80a_core` from
[1801BM1/vm80a](https://github.com/1801BM1/vm80a) (pinned submodule
`sources/vm80a`, `323535a`), a gate-level-derived model of the KR580VM80A.
One source, `harness.v`, builds with Icarus Verilog (`-g2012`) and
Verilator 5 (`--binary --timing`); programs and schedules are plusargs and
files, so changing them needs no rebuild.

## Attribution

vm80a is copyright (c) 2014-2018 by 1801BM1 and licensed under
[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) (`sources/vm80a/license.md`).
It is used unmodified and is not part of any release archive; any binary
that embeds it (a future `vm80a_sim`) must carry this notice. The harness
is under this repository's licence. The vm80a `memini.bin` image is not used
(it bundles TST8080).

## Use

```sh
make vm80a-submodule        # fetch sources/vm80a only
make vm80a-test             # build both simulators, run the fixtures (needs iverilog, verilator, python3; present in the devcontainer)
```

`scripts/vm80a.py run <manifest> <outdir> -- <simulator>` turns a K3
manifest into plusargs, runs it and checks the observable part of `expect`
(stop reason, instructions, T-states, memory digest, `io_out`; a pin-level run
cannot see registers). `scripts/vm80a.py compare <expected> <actual>` diffs
pin traces with the `~` masks of the expected file.

| Plusarg | Meaning |
| --- | --- |
| `+image=<file>` `+origin=<hex>` | Hex bytes, loaded at the origin |
| `+fill=<hex>` | Initial byte of all memory (default `00`) |
| `+ram_start= +ram_size= +rom_start= +rom_size=` | Hex regions; an access outside them, or a write to ROM, is a fault |
| `+stim=<file>` | `i8080-stimulus v1` schedule (default: reset released at sample 4). `reset`, `ready`, `hold`, `int` with absolute or `m<c>+<k>` times; `io` and `inta` are rejected |
| `+max_tstates=<dec>` `+tail=<dec>` | Sample budget; samples recorded after the first halted T-state (default 2) |
| `+idle_din=<hex>` | Byte on the data input when nothing is read (default `ff`, a pulled-up bus as in `tb80a`) |
| `+memdump=<file>` `+membin=<file>` | Memory after the run: one hex byte per line, or raw bytes (NUL bytes kept). Bytes outside the regions are `00` |
| `+dump_start=<hex>` `+dump_size=<hex>` | Range written by both (default the whole 64 KiB); beyond 64 KiB is an error |
| `+trace= +result= +vcd=` | `i8080-pin-trace v1` file; key=value result; VCD |

One T-state is two `pin_clk` rising edges (`f1` then `f2`); the sample is
taken `#1` after the second. The harness drives `vm80a_core`, not the
`vm80a` wrapper, and reads memory at the first sample with `DBIN` high.
A write is taken at the first sample with `WR̄` low, using the address and
data of the sample before.

## Observed with the fixtures

* The hand-written MVI/STA/HLT traces (no waits, two waits on the STA write)
  match in every unmasked field. 27 and 29 counted T-states, one write of
  `2a` to `2000`, `pre_sync=1`, no X.
* In the halt cycle `A` shows `0005` (the address of `HLT`); the hand trace
  says `0006` and masks `A` there until the 8080 manual settles it.
* Reset released at sample 3 or later is clean; at sample 2 one sample shows
  X; at sample 1 or 0 the core never starts.
* With an idle data input of `00` instead of `ff`, `A` in the last T-state of
  the STA fetch is `00xx`: a masked byte, so the trace still matches.
