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

## vm80a_sim (Verilator model of the KR580VM80A)

The K5 shim and the same `.COM` files, run under the packaged static `vm80a_sim_fast`
(`vm80a_sim` runs at the same speed when no FST is requested). Local aarch64 Docker host,
8 cores shared with other work, one process per run unless noted.

| Run | T-states | Instructions | Wall clock |
| --- | --- | --- | --- |
| `8080PRE` | 9,235 | 1,254 | under 1 s |
| `8080EX1`, whole, one process | 23,803,352,043 | 2,919,049,315 | 10,496 s (2 h 55 min), 2.27 M T-states/s |
| `8080EX1`, 24 of 25 groups in parallel (6 jobs) | 3,646,465,567 | 448,752,601 | group 0 (the largest of these) 527 s |
| `8080EX1` group 2, `aluop <b,c,d,e,h,l,m,a>` | 20,156,886,476 | 2,470,296,714 | about 2.5 h; 85% of the exerciser |

Throughput is 2.15 to 2.27 million T-states per second per process, about the speed of a
2 MHz 8080 (a Radio-86RK runs at 1.78 MHz), with or without FST support compiled in. `-O3` raised it from 1.44 M/s (Verilator's default `-Os`). The
console text of the whole run equals `altairz80`'s once the line terminators are mapped (the
shim prints LF CR, SIMH's terminal turns it into LF LF): 25 groups `OK`, then `Tests complete`.

Per group (T-states): `dad` 1.14 G, `aluop nn` 0.58 G, `<daa,cma,stc,cmc>` 1.11 G, each
`<inr,dcr> r` 60 M, each `<inx,dcx> rp` 31 M, `mov` 92 M, `<rlc,rrc,ral,rar>` 121 M, the
seven groups run by `make test` (`lhld`, `shld`, `lxi`, `ldax`, `mvi`, `sta/lda`, `stax`)
0.3 to 1.9 M each. The whole exerciser therefore runs in the `exerciser` workflow (dispatch;
one process per group), not in `make test`.
