#!/usr/bin/env python3
"""Drive the vm80a pin-level harness from a K3 manifest and compare K4 traces.

  vm80a.py run <manifest.json> <outdir> [--seed N] -- <simulator command...>
  vm80a.py com <file.COM> <outdir> [--seed N] [--max-tstates N] [--trace] -- <simulator command...>
  vm80a.py args <manifest> <side-dir> <side-ref> <out-ref> [--trace]
  vm80a.py check <manifest> <outdir>
  vm80a.py com-manifest <file.COM> <out.json>
  vm80a.py compare <expected.trace> <actual.trace>
  vm80a.py bincheck <mem.hex> <file.bin> <start-hex> <size-hex>

`run` writes <outdir>/<id>.{trace,result.json,mem.hex}, checks the result
against the manifest's `expect` (only the fields a pin-level runner can
observe) and exits non-zero on any difference. `compare` applies the `~`
masks of the expected trace and lists every mismatch as `n` + field.
"""
import hashlib
import json
import os
import subprocess
import sys

FIELDS = "n a do di sync dbin wr_n wait hlda inte ready hold int reset".split()
OBSERVABLE = ["fault", "stop_reason", "halted", "instructions", "tstates", "memory_sha256", "io_out"]


def hexint(s):
    return int(s, 16) if isinstance(s, str) else int(s)


def read_trace(path):
    header, rows = {}, []
    for raw in open(path, encoding="utf-8"):
        line = raw.split("#", 1)[0].split()
        if not line:
            for tok in raw.lstrip("# ").split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    header[k] = v
            continue
        if len(line) != len(FIELDS):
            raise SystemExit(f"{path}: expected {len(FIELDS)} fields, got {line}")
        rows.append(line)
    return header, rows


def masked(exp, act):
    return all(e == "~" * len(e) or e == a for e, a in zip(exp, act)) and len(exp) == len(act)


def compare(expected, actual, quiet=False):
    eh, er = read_trace(expected)
    ah, ar = read_trace(actual)
    if eh.get("pre_sync", "*") != "*" and eh.get("pre_sync") != ah.get("pre_sync"):
        return f"pre_sync: expected {eh.get('pre_sync')} got {ah.get('pre_sync')}"
    bad = [f"n={e[0]} field={name}: expected {ev} got {av}"
           for e, a in zip(er, ar) for name, ev, av in zip(FIELDS, e, a) if not masked(ev, av)]
    if len(er) != len(ar):
        bad.append(f"row count: expected {len(er)} got {len(ar)}")
    return "\n         ".join(bad) if bad else None


def parse_result(path):
    res = {"wlist": []}
    for line in open(path, encoding="utf-8"):
        k, _, v = line.strip().partition("=")
        if k == "write":
            res["wlist"].append(v)
        else:
            res[k] = v
    return res


def prepare(man, here, side_dir, side_ref, out_ref, trace=True):
    """Plusargs for a manifest. Side files (image, preamble, schedule) are
    written to side_dir and named by side_ref; results by out_ref."""
    mid = man["id"]
    os.makedirs(side_dir, exist_ok=True)
    img = bytes.fromhex(man["image"]["hex"])
    if hashlib.sha256(img).hexdigest() != man["image"]["sha256"]:
        raise SystemExit(f"{mid}: image sha256 does not match the manifest")
    if man.get("shim") not in (None, "cpm/1"):
        raise SystemExit(f"{mid}: unknown shim {man['shim']!r}")
    regions = man["memory"]["regions"]
    ram = [r for r in regions if r["kind"] == "ram"]
    rom = [r for r in regions if r["kind"] == "rom"]
    if len(ram) > 1 or len(rom) > 1 or len(ram) + len(rom) != len(regions):
        raise SystemExit(f"{mid}: at most one ram and one rom region")
    stop = man["stop"]

    def side(ext, text):
        with open(os.path.join(side_dir, f"{mid}.run.{ext}"), "w", encoding="utf-8") as f:
            f.write(text)
        return f"{side_ref}/{mid}.run.{ext}"

    def out(ext):
        return f"{out_ref}/{mid}.{ext}"

    args = [
        "+image=" + side("img", "\n".join("%02x" % b for b in img) + "\n"),
        f"+origin={hexint(man['image']['origin']):x}", f"+fill={hexint(man['memory']['fill']):x}",
        f"+max_tstates={stop['max_tstates']}",
        f"+result={out('result')}", f"+memdump={out('mem')}", f"+io_out={out('ioout')}",
    ]
    if trace:
        args.append(f"+trace={out('trace')}")
    if ram:
        args += [f"+ram_start={hexint(ram[0]['start']):x}", f"+ram_size={hexint(ram[0]['size']):x}"]
    if rom:
        args += [f"+rom_start={hexint(rom[0]['start']):x}", f"+rom_size={hexint(rom[0]['size']):x}"]
    # K4: io/inta statements of the schedule override the manifest's io.in
    stim = []
    if man.get("stimulus"):
        stim += open(os.path.join(here, man["stimulus"]), encoding="utf-8").read().splitlines()
    for port, vals in man["io"]["in"].items():
        stim.append("io %x %s" % (hexint(port), " ".join("%x" % hexint(v) for v in vals)))
    if stim:
        text = "\n".join(stim) + "\n"
        if not man.get("stimulus"):
            text = "# i8080-stimulus v1\nreset 0 @4\n" + text
        args.append("+stim=" + side("stim", text))
    if man["io"].get("in_default") is not None:
        args.append("+in_default=%x" % hexint(man["io"]["in_default"]))
    if stop["ports"]:
        args.append("+stop_ports=" + ",".join("%x" % hexint(q) for q in stop["ports"]))
    if not stop["on_hlt"]:
        args.append("+halt_stop=0")
    if man.get("shim"):
        args.append("+shim=1")
    # Pins cannot set registers: a preamble at 0000 loads SP, BC, DE, HL and A
    # (flags clear, f=0x02) and jumps to pc; the harness restores the bytes it overlays.
    init = man.get("initial", {})
    regs = {k: hexint(init.get(k, 0)) for k in "pc sp a b c d e h l f".split()}
    regs["f"] = regs["f"] or 2
    if any(v for k, v in regs.items() if k != "f") or regs["f"] != 2:
        if regs["f"] != 2 or init.get("inte", 0):
            raise SystemExit(f"{mid}: a pin-level run supports f=0x02 and inte=0 only")
        pre = bytes([0x31, regs["sp"] & 255, regs["sp"] >> 8,
                     0x01, regs["c"], regs["b"], 0x11, regs["e"], regs["d"], 0x21, regs["l"], regs["h"],
                     0x3e, 0x01, 0xb7, 0x3e, regs["a"], 0xc3, regs["pc"] & 255, regs["pc"] >> 8])
        args += ["+boot=" + side("boot", "\n".join("%02x" % b for b in pre) + "\n"),
                 "+boot_len=%x" % len(pre), "+boot_pc=%x" % regs["pc"]]
    return args


def check(man, outdir, quiet=False):
    """Compare the files a run left in outdir with the manifest's expect."""
    mid = man["id"]
    out = {k: os.path.join(outdir, f"{mid}.{k}") for k in ("trace", "result", "mem", "ioout")}
    res = parse_result(out["result"])
    if "error" in res:
        raise SystemExit(f"{mid}: harness error: {res['error']}")
    mem = bytes.fromhex("".join(open(out["mem"]).read().split()))
    if len(mem) != 65536:
        raise SystemExit(f"{mid}: memory dump has {len(mem)} bytes")
    final = {
        "stop_reason": res["stop_reason"],
        "halted": res["halted"] == "1",
        "instructions": int(res["instructions"]),
        "tstates": int(res["tstates"]),
        "memory_sha256": hashlib.sha256(mem).hexdigest(),
        "io_out": [["0x%02x" % int(a, 16), "0x%02x" % int(b, 16)]
                   for a, b in (l.split() for l in open(out["ioout"]) if l.strip())],
    }
    if res.get("fault"):
        kind, _, addr = res["fault"].rpartition(" ")
        final["fault"] = {"kind": kind, "addr": "0x" + addr}
    result = {"format": "i8080-exec-result/1", "id": mid, "runner": "vm80a_core harness", **final,
              "pre_sync": int(res["pre_sync"]), "x_samples": int(res["x_samples"]),
              "writes": res["wlist"], "inputs": int(res["inputs"]), "intas": int(res["intas"])}
    if res.get("port_dup_errors", "0") != "0":
        raise SystemExit(f"{mid}: OUT/IN port not duplicated on A15-8 ({res['port_dup_errors']})")
    json.dump(result, open(os.path.join(outdir, mid + ".result.json"), "w"), indent=2)
    bad = []
    for k in OBSERVABLE:
        if k in man["expect"] and man["expect"][k] is not None and man["expect"][k] != final[k]:
            bad.append(f"{k}: expected {man['expect'][k]} got {final[k]}")
    if result["x_samples"]:
        bad.append(f"x_samples: {result['x_samples']} samples with X after reset release")
    for l in open(out["trace"]) if os.path.exists(out["trace"]) else []:
        if not l.startswith("#") and "x" in l.lower().replace("zz", ""):
            bad.append("X in trace row: " + l.strip())
            break
    if bad:
        raise SystemExit(f"{mid}: " + "; ".join(bad))
    if not quiet:
        print(f"{mid}: result ok ({final['tstates']} T-states, {final['instructions']} instructions, "
              f"{result['pre_sync']} pre-sync, writes {len(res['wlist'])}, io_out {len(final['io_out'])})")


def run(manifest_path, outdir, sim, seed, trace=True):
    man = json.load(open(manifest_path, encoding="utf-8"))
    os.makedirs(outdir, exist_ok=True)
    args = prepare(man, os.path.dirname(os.path.abspath(manifest_path)), outdir, outdir, outdir, trace)
    if seed is not None:
        args += ["+verilator+rand+reset+2", f"+verilator+seed+{seed}"]
    args += [a for a in os.environ.get("VM80A_EXTRA", "").split() if a]
    subprocess.run(sim + args, check=True, stdout=subprocess.DEVNULL)
    check(man, outdir)


def com_manifest(com, name, max_tstates):
    """K3 manifest for a CP/M .COM under the K5 shim (no expectations)."""
    img = open(com, "rb").read()
    return {
        "format": "i8080-exec-manifest/1", "id": name, "profile": "i8080a/1",
        "image": {"origin": "0x0100", "hex": img.hex(), "sha256": hashlib.sha256(img).hexdigest()},
        "memory": {"fill": "0x00", "regions": [{"start": "0x0000", "size": "0x10000", "kind": "ram"}]},
        "initial": {"pc": "0x0100", "sp": "0xfe00", "a": "0x00", "b": "0x00", "c": "0x00", "d": "0x00",
                    "e": "0x00", "h": "0x00", "l": "0x00", "f": "0x02", "inte": 0},
        "io": {"in": {}, "in_default": "0xff"}, "shim": "cpm/1", "stimulus": None,
        "stop": {"on_hlt": True, "ports": ["0xff"], "max_instructions": 0, "max_tstates": max_tstates},
        "expect": {},
    }


def console(ioout):
    return bytes(int(l.split()[1], 16) for l in open(ioout) if l.split() and l.split()[0] == "01")


def main(argv):
    if len(argv) >= 4 and argv[1] == "compare":
        err = compare(argv[2], argv[3])
        if err:
            print("MISMATCH " + err)
            return 1
        print("trace equal")
        return 0
    if len(argv) == 6 and argv[1] == "bincheck":
        mem = bytes.fromhex("".join(open(argv[2]).read().split()))
        start, size = int(argv[4], 16), int(argv[5], 16)
        got = open(argv[3], "rb").read()
        if got != mem[start:start + size]:
            print(f"MISMATCH binary dump ({len(got)} bytes) differs from hex dump [{start:#x}+{size:#x}]")
            return 1
        print(f"binary dump equals hex dump [{start:#x}+{size:#x}]")
        return 0
    if len(argv) == 4 and argv[1] == "com-manifest":
        # com-manifest <file.COM> <out.json>: K3 manifest of a CP/M .COM under the K5 shim
        name = os.path.splitext(os.path.basename(argv[2]))[0]
        json.dump(com_manifest(argv[2], name, 2000000000), open(argv[3], "w"), indent=1)
        return 0
    if len(argv) >= 6 and argv[1] == "args":
        # args <manifest> <side-dir> <side-ref> <out-ref> [--trace]: <side-dir>/<id>.args, one plusarg per line
        man = json.load(open(argv[2], encoding="utf-8"))
        args = prepare(man, os.path.dirname(os.path.abspath(argv[2])), argv[3], argv[4], argv[5],
                       trace="--trace" in argv[6:])
        with open(os.path.join(argv[3], man["id"] + ".args"), "w") as f:
            f.write("\n".join(args) + "\n")
        return 0
    if len(argv) >= 4 and argv[1] == "check":
        # check <manifest> <outdir>: results left by a run
        check(json.load(open(argv[2], encoding="utf-8")), argv[3])
        return 0
    if len(argv) >= 5 and argv[1] == "com" and "--" in argv:
        # com <file.COM> <outdir> [--seed N] [--max-tstates N] [--trace] -- <simulator...>
        i = argv.index("--")
        opts = argv[4:i]
        seed = int(opts[opts.index("--seed") + 1]) if "--seed" in opts else None
        budget = int(opts[opts.index("--max-tstates") + 1]) if "--max-tstates" in opts else 2000000000
        name = os.path.splitext(os.path.basename(argv[2]))[0]
        os.makedirs(argv[3], exist_ok=True)
        mpath = os.path.join(argv[3], name + ".manifest.json")
        json.dump(com_manifest(argv[2], name, budget), open(mpath, "w"), indent=1)
        run(mpath, argv[3], argv[i + 1:], seed, trace="--trace" in opts)
        text = console(os.path.join(argv[3], name + ".ioout"))
        open(os.path.join(argv[3], name + ".console"), "wb").write(text)
        sys.stdout.write(text.decode("latin-1"))
        return 0
    if len(argv) >= 5 and argv[1] == "run" and "--" in argv:
        i = argv.index("--")
        opts = argv[4:i]
        seed = int(opts[opts.index("--seed") + 1]) if "--seed" in opts else None
        run(argv[2], argv[3], argv[i + 1:], seed)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
