// File-driven pin-level harness around vm80a_core (1801BM1/vm80a, CC BY 3.0).
// One source for Icarus Verilog (-g2012) and Verilator 5 (--binary --timing).
// Formats: i8080-stimulus v1 and i8080-pin-trace v1 (radio86rk-contracts K4).
//
// Plusargs:
//   +image=<file>      hex bytes (whitespace separated), loaded at +origin=<hex>
//   +origin=<hex>      default 0
//   +fill=<hex>        initial byte of all memory, default 00
//   +ram_start= +ram_size= +rom_start= +rom_size=   hex; access outside both
//                      regions, or a write to ROM, is a fault
//   +stim=<file>       stimulus schedule; default: reset released at sample 4
//   +max_tstates=<dec> budget in trace samples, default 1000000
//   +tail=<dec>        samples recorded after the first halted T-state, default 2
//   +idle_din=<hex>    byte on the data input when nothing reads, default ff
//   +dump_start=<hex> +dump_size=<hex>   range written by +memdump/+membin
//                      (default the whole 64 KiB; bytes outside the regions are 00)
//   +trace= +result= +vcd=               output files
//   +memdump=<file>    one hex byte per line
//   +membin=<file>     raw bytes
//
// Bus cycles are classified by the status byte at SYNC: IN (42), OUT (10) and
// INTA (23, 2b; and 02, the address bytes of an interrupt CALL) never touch memory; everything else is a memory cycle.
//   io <port> <byte>...   (stimulus) bytes returned by successive IN from port
//   inta <byte>...        (stimulus) bytes returned by successive INTA cycles
//   +in_default=<hex>     IN byte when a port has no bytes left, default ff
//   +io_out=<file>        one "port value" hex line per OUT
//   +stop_ports=<hex,..>  stop after the OUT to any listed port (stop_reason=port)
//   +halt_stop=0          do not stop at the halt cycle
//   +shim=1               K5 CP/M shim: 0000 OUT FF/HLT, 0005 JMP FE00, handler at FE00
//   +boot=<file> +boot_len=<hex> +boot_pc=<hex>   preamble (hex bytes) executed from
//                         0000 until the first instruction fetch at boot_pc; the bytes
//                         it overlays are restored then; the trace, n, the machine-cycle
//                         anchors, instructions and tstates all start at that fetch
`timescale 1ns/1ps

module i8080_tb;

reg         clk = 1'b0, f1 = 1'b0, f2 = 1'b0;
reg         pin_reset = 1'b1, pin_ready = 1'b1, pin_hold = 1'b0, pin_int = 1'b0;
reg  [7:0]  pin_din = 8'hff;
wire [15:0] pin_a;
wire [7:0]  pin_dout;
wire        pin_aena, pin_dena, pin_hlda, pin_wait, pin_inte;
wire        pin_sync, pin_dbin, pin_wr_n;

vm80a_core dut
(
   .pin_clk   (clk),   .pin_f1    (f1),       .pin_f2   (f2),
   .pin_reset (pin_reset),                     .pin_a    (pin_a),
   .pin_dout  (pin_dout), .pin_din (pin_din),
   .pin_aena  (pin_aena), .pin_dena (pin_dena),
   .pin_hold  (pin_hold), .pin_hlda (pin_hlda),
   .pin_ready (pin_ready), .pin_wait (pin_wait),
   .pin_int   (pin_int),  .pin_inte (pin_inte),
   .pin_sync  (pin_sync), .pin_dbin (pin_dbin),
   .pin_wr_n  (pin_wr_n)
);

reg [7:0]   mem [0:65535];
integer     ram_start = 0, ram_size = 0, rom_start = 0, rom_size = 0;
integer     max_tstates = 1000000, tail = 2;
reg [7:0]   idle_din = 8'hff, fill = 8'h00;
integer     origin = 0;

// stimulus events: sig 0 reset, 1 ready, 2 hold, 3 int
integer     nev = 0;
integer     ev_sig [0:255];
integer     ev_val [0:255];
integer     ev_anch [0:255];
integer     ev_a [0:255];   // absolute sample, or machine cycle
integer     ev_k [0:255];   // T-states after T1 (anchored)

reg [8*256-1:0] sbuf;
reg [8*16-1:0]  sname;
integer     tfd, rfd, mfd, bfd, sfd, i, vval, wa, wk;
integer     dump_start = 0, dump_size = 65536;
reg [7:0]   dbyte;
integer     have_stim, have_trace, have_result, have_memdump;

// run state
integer     r = 0, r_release = 0, released = 0, started = 0;
integer     n = 0, pre_sync = 0, cyc = -1, r_t1 = 0;
integer     instr = 0, nwrites = 0, xcount = 0, done = 0;
integer     twh_seen = 0, tail_left = 0, counted = 0, halt_cycle = 0;
integer     fault = 0, wlog_n = 0, di_active = 0;
reg [15:0]  pc_halt = 16'h0000;
reg         prev_wr_n = 1'b1;
reg [15:0]  prev_a = 16'h0000;
reg [7:0]   prev_do = 8'h00, di_cur = 8'h00, status = 8'h00;
reg [15:0]  fault_addr = 16'h0000;
reg [8*12-1:0] stop_reason = "budget";
reg [8*12-1:0] fault_kind = "";
reg [8*80-1:0] err = "";
reg [7:0]   in_default = 8'hff;
integer     nio = 0, nia = 0, ia_pos = 0, nin = 0, nout = 0, ninta = 0, dup_err = 0;
integer     io_p [0:4095];
integer     io_b [0:4095];
integer     io_used [0:4095];
reg [7:0]   ia_b [0:255];
reg [255:0] stop_mask = 256'h0;
integer     halt_stop = 1, stop_pending = 0, ofd = 0, have_ioout = 0;
integer     cyc_kind = 0;       // 0 memory read, 1 memory write, 2 IN, 3 OUT, 4 INTA
integer     shim = 0, boot = 0, boot_pc = 0, boot_len = 0;
reg [7:0]   boot_save [0:255];
reg [7:0]   boot_img [0:255];
reg [7:0]   port_b;
reg [8*12-1:0] stop_why = "hlt";
reg [8*64-1:0] spbuf;
integer     spi, spv, spn;
reg [8*28-1:0] shim_handler = 224'h79fe02ca0efefe09ca12fed3fec97bd301c91afe24c8d30113c312fe;
reg [15:0]  wlog_a [0:63];
reg [7:0]   wlog_d [0:63];

function in_ram(input [15:0] ad);
   in_ram = (ram_size != 0) && (ad >= ram_start) && (ad < ram_start + ram_size);
endfunction
function in_rom(input [15:0] ad);
   in_rom = (rom_size != 0) && (ad >= rom_start) && (ad < rom_start + rom_size);
endfunction

task set_fault(input [8*12-1:0] kind, input [15:0] ad);
begin
   if (!fault) begin
      fault = 1; fault_kind = kind; fault_addr = ad;
      stop_reason = "fault"; done = 1;
   end
end
endtask

task fail(input [8*80-1:0] msg);
begin
   err = msg; stop_reason = "error"; done = 1;
end
endtask

// Apply the inputs of sample r (before the first clock edge of the T-state).
task apply_inputs;
   integer e;
   reg hit;
begin
   for (e = 0; e < nev; e = e + 1) begin
      hit = 1'b0;
      if (ev_anch[e] == 0) hit = (ev_a[e] == r);
      else hit = started && (cyc == ev_a[e]) && ((r - r_t1) == ev_k[e]);
      if (hit)
         case (ev_sig[e])
            0: pin_reset = ev_val[e];
            1: pin_ready = ev_val[e];
            2: pin_hold  = ev_val[e];
            3: pin_int   = ev_val[e];
         endcase
   end
   if (!pin_reset && !released) begin released = 1; r_release = r; end
end
endtask

// One line of the trace for the sample just taken.
task emit_row;
begin
   if (have_trace) begin
      $fwrite(tfd, "%0d %04h", n, pin_a);
      if (pin_dena) $fwrite(tfd, " %02h", pin_dout); else $fwrite(tfd, " zz");
      if (pin_dbin || di_active) $fwrite(tfd, " %02h", di_cur); else $fwrite(tfd, " zz");
      $fwrite(tfd, " %b %b %b %b %b %b %b %b %b %b\n", pin_sync, pin_dbin, pin_wr_n,
              pin_wait, pin_hlda, pin_inte, pin_ready, pin_hold, pin_int, pin_reset);
   end
end
endtask

// State update for the sample taken after the second edge of T-state r.
task write_header;
begin
   if (have_trace) begin
      $fwrite(tfd, "# i8080-pin-trace v1\n");
      $fwrite(tfd, "# source=vm80a_core profile=i8080a/1 pre_sync=%0d\n", pre_sync);
      $fwrite(tfd, "# n a do di sync dbin wr_n wait hlda inte ready hold int reset\n");
   end
end
endtask

task sample;
   reg show_di;
begin
   if (released && !boot && ((^{pin_a, pin_sync, pin_dbin, pin_wr_n, pin_wait, pin_hlda, pin_inte}) === 1'bx
                    || (pin_dena && (^pin_dout) === 1'bx)))
      xcount = xcount + 1;
   if (released && !started && pin_sync === 1'b1) begin
      started = 1; pre_sync = r - r_release; n = 0;
      if (!boot) write_header;
   end
   if (started) begin
      if (pin_sync === 1'b1) begin
         cyc = cyc + 1; r_t1 = r; status = pin_dout;
         halt_cycle = (status == 8'h8a);
         // vm80a shows status 02 (no MEMR, no INTA bit) in M2/M3 of an interrupt CALL
         cyc_kind = (status[0] || status == 8'h02) ? 4 : (status == 8'h42) ? 2 : (status == 8'h10) ? 3
                  : !status[1] ? 1 : 0;
         if (boot && status == 8'ha2 && pin_a == boot_pc[15:0]) begin
            for (spi = 0; spi < boot_len; spi = spi + 1) mem[spi] = boot_save[spi];
            boot = 0; instr = 0; n = 0; cyc = 0;
            pre_sync = r - r_release; write_header;
         end
         if (status[5]) instr = instr + 1;
      end
      // read data: taken from the address of the first DBIN sample, held
      // through the first following sample without DBIN
      if (pin_dbin === 1'b1 && !di_active) begin
         if (cyc_kind == 2) begin
            di_cur = in_default; nin = nin + 1;
            for (spi = 0; spi < nio; spi = spi + 1)
               if (io_p[spi] == pin_a[7:0] && !io_used[spi]) begin
                  di_cur = io_b[spi]; io_used[spi] = 1; spi = nio;
               end
         end else if (cyc_kind == 4) begin
            ninta = ninta + 1;
            if (ia_pos < nia) begin di_cur = ia_b[ia_pos]; ia_pos = ia_pos + 1; end
            else begin set_fault("inta", pin_a); di_cur = idle_din; end
         end else if (!(in_ram(pin_a) || in_rom(pin_a))) begin
            set_fault("read", pin_a);
            di_cur = idle_din;
         end else di_cur = mem[pin_a];
         di_active = 1;
      end
      if (!boot) emit_row;
      if (pin_dbin !== 1'b1) di_active = 0;
      // write: first sample with WR low; address and data of the sample before
      if (pin_wr_n === 1'b0 && prev_wr_n === 1'b1) begin
         if (cyc_kind == 3) begin
            port_b = prev_a[7:0];
            if (prev_a[15:8] != port_b) dup_err = dup_err + 1;
            nout = nout + 1;
            if (have_ioout) $fwrite(ofd, "%02h %02h\n", port_b, prev_do);
            if (stop_mask[port_b]) stop_pending = 1;
         end else if (cyc_kind == 1) begin
            if (!in_ram(prev_a)) set_fault(in_rom(prev_a) ? "rom write" : "write", prev_a);
            else begin
               mem[prev_a] = prev_do;
               if (wlog_n < 64) begin wlog_a[wlog_n] = prev_a; wlog_d[wlog_n] = prev_do; end
               wlog_n = wlog_n + 1;
            end
            nwrites = nwrites + 1;
         end
      end
      prev_wr_n = pin_wr_n; prev_a = pin_a; prev_do = pin_dout;
      // stop: halt cycle, then +tail samples
      if (twh_seen) begin
         tail_left = tail_left - 1;
         if (tail_left <= 0 && !done) begin stop_reason = stop_why; done = 1; end
      end else if (stop_pending && pin_wr_n === 1'b1) begin
         twh_seen = 1; counted = n; tail_left = tail - 1; stop_why = "port";
         if (pin_sync === 1'b1 && status[5]) instr = instr - 1;   // next fetch, not part of the run
         if (tail_left <= 0 && !done) begin stop_reason = "port"; done = 1; end
      end else if (halt_cycle && pin_wait === 1'b1 && halt_stop) begin
         twh_seen = 1; counted = n + 1; tail_left = tail; pc_halt = pin_a; stop_why = "hlt";
         if (tail <= 0 && !done) begin stop_reason = "hlt"; done = 1; end
      end
      n = n + 1;
      if (n >= max_tstates && !done) begin stop_reason = "budget"; done = 1; end
   end else if (r >= max_tstates && !done) begin
      stop_reason = "budget"; done = 1;
   end
   // data input for the next T-state
   pin_din = (pin_dbin === 1'b1 || di_active) ? di_cur : idle_din;
end
endtask

task one_tstate;
begin
   f1 = 1'b1; f2 = 1'b0;                    // edge A: phase 1 update
   #2 clk = 1'b1; #3 clk = 1'b0; #2;
   f1 = 1'b0; f2 = 1'b1;                    // edge B: phase 2 update
   #2 clk = 1'b1; #1;
   sample;
   #2 clk = 1'b0; #2;
end
endtask

// Hand-written scanner: the simulators disagree on $sscanf with packed
// vectors, but not on $fgetc.
integer     lb [0:255];
integer     ll, lp, ch, numv, numok, eof;

task skipsp;
begin
   while (lp < ll && (lb[lp] == 32 || lb[lp] == 9 || lb[lp] == 13)) lp = lp + 1;
end
endtask

task getnum;
begin
   numv = 0; numok = 0;
   while (lp < ll && lb[lp] >= 48 && lb[lp] <= 57) begin
      numv = numv * 10 + lb[lp] - 48; numok = 1; lp = lp + 1;
   end
end
endtask

task gethex;
begin
   numv = 0; numok = 0;
   if (lp + 1 < ll && lb[lp] == 48 && (lb[lp+1] == 120 || lb[lp+1] == 88)) lp = lp + 2;
   while (lp < ll && ((lb[lp] >= 48 && lb[lp] <= 57) || (lb[lp] >= 97 && lb[lp] <= 102)
                      || (lb[lp] >= 65 && lb[lp] <= 70))) begin
      numv = numv * 16 + ((lb[lp] <= 57) ? lb[lp] - 48 : (lb[lp] | 32) - 87);
      numok = 1; lp = lp + 1;
   end
end
endtask

task parse_stim;
   integer sigv, ioport;
begin
   sfd = $fopen(sbuf, "r");
   if (sfd == 0) fail("cannot open stimulus file");
   eof = (sfd == 0);
   while (!eof && !done) begin
      ll = 0; ch = $fgetc(sfd);
      while (ch != -1 && ch != 10) begin
         if (ll < 255) begin lb[ll] = ch; ll = ll + 1; end
         ch = $fgetc(sfd);
      end
      if (ch == -1) eof = 1;
      lp = 0; skipsp;
      if (lp < ll && lb[lp] != 35) begin       // not blank, not a comment
         sname = 0;
         while (lp < ll && lb[lp] != 32 && lb[lp] != 9) begin
            sname = (sname << 8) | lb[lp]; lp = lp + 1;
         end
         sigv = (sname == "reset") ? 0 : (sname == "ready") ? 1 : (sname == "hold") ? 2 :
                (sname == "int") ? 3 : (sname == "io") ? 4 : (sname == "inta") ? 5 : -1;
         if (sigv < 0) fail("unsupported stimulus statement");
         if (sigv >= 4) begin                       // io <port> <byte>... | inta <byte>...
            ioport = 0;
            if (sigv == 4) begin
               skipsp; gethex; ioport = numv;
               if (!numok || ioport > 255) fail("bad io port");
            end
            skipsp;
            while (lp < ll && lb[lp] != 35 && !done) begin
               gethex;
               if (!numok || numv > 255) fail("bad io byte");
               else if (sigv == 4) begin
                  if (nio >= 4096) fail("too many io bytes");
                  else begin io_p[nio] = ioport; io_b[nio] = numv; io_used[nio] = 0; nio = nio + 1; end
               end else begin
                  if (nia >= 256) fail("too many inta bytes");
                  else begin ia_b[nia] = numv; nia = nia + 1; end
               end
               skipsp;
            end
         end else begin
         skipsp; getnum; vval = numv;
         if (!numok || vval > 1) fail("bad stimulus value");
         skipsp;
         if (lp >= ll || lb[lp] != 64) fail("expected @<when>");
         lp = lp + 1;
         if (lp < ll && lb[lp] == 109) begin     // m<c>+<k>
            lp = lp + 1; getnum; wa = numv;
            if (!numok || lp >= ll || lb[lp] != 43) fail("bad anchored time");
            lp = lp + 1; getnum; wk = numv;
            if (!numok) fail("bad anchored time");
            if (wk < 1) fail("anchor must be after T1 of the cycle");
            ev_anch[nev] = 1; ev_a[nev] = wa; ev_k[nev] = wk;
         end else begin
            getnum; wa = numv;
            if (!numok) fail("bad stimulus time");
            ev_anch[nev] = 0; ev_a[nev] = wa; ev_k[nev] = 0;
         end
         skipsp;
         if (lp < ll && lb[lp] != 35) fail("trailing text in stimulus statement");
         ev_sig[nev] = sigv; ev_val[nev] = vval;
         nev = nev + 1;
         end
      end
   end
   if (sfd != 0) $fclose(sfd);
end
endtask

initial begin
   for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
   if ($value$plusargs("fill=%h", vval)) fill = vval;
   for (i = 0; i < 65536; i = i + 1) mem[i] = fill;
   if ($value$plusargs("ram_start=%h", vval)) ram_start = vval;
   if ($value$plusargs("ram_size=%h", vval)) ram_size = vval;
   if ($value$plusargs("rom_start=%h", vval)) rom_start = vval;
   if ($value$plusargs("rom_size=%h", vval)) rom_size = vval;
   if ($value$plusargs("max_tstates=%d", vval)) max_tstates = vval;
   if ($value$plusargs("tail=%d", vval)) tail = vval;
   if ($value$plusargs("idle_din=%h", vval)) idle_din = vval;
   if ($value$plusargs("origin=%h", vval)) origin = vval;
   if ($value$plusargs("in_default=%h", vval)) in_default = vval;
   if ($value$plusargs("halt_stop=%d", vval)) halt_stop = vval;
   pin_din = idle_din;
   if ($value$plusargs("image=%s", sbuf)) $readmemh(sbuf, mem, origin, 65535);
   if ($value$plusargs("shim=%d", vval)) shim = vval;
   if (shim) begin
      mem[0] = 8'hd3; mem[1] = 8'hff; mem[2] = 8'h76;
      mem[5] = 8'hc3; mem[6] = 8'h00; mem[7] = 8'hfe;
      for (i = 0; i < 28; i = i + 1) mem[16'hfe00 + i] = shim_handler[8*(27-i) +: 8];
   end
   if ($value$plusargs("boot=%s", sbuf)) begin
      if (!$value$plusargs("boot_len=%h", boot_len) || boot_len < 1 || boot_len > 256) fail("boot needs boot_len 1..100");
      if (!$value$plusargs("boot_pc=%h", boot_pc) || boot_pc < boot_len) fail("boot needs boot_pc >= boot_len");
      for (i = 0; i < 256; i = i + 1) boot_img[i] = 8'hxx;
      $readmemh(sbuf, boot_img);
      for (i = 0; i < boot_len; i = i + 1) begin boot_save[i] = mem[i]; mem[i] = boot_img[i]; end
      boot = 1;
   end
   if ($value$plusargs("stop_ports=%s", spbuf)) begin
      spn = -1; spv = 0;
      for (spi = 8*64 - 8; spi >= -8; spi = spi - 8) begin
         vval = (spi >= 0) ? spbuf[spi +: 8] : 44;
         if (vval == 0) begin end
         else if (vval == 44) begin if (spn >= 0) stop_mask[spv] = 1'b1; spn = -1; spv = 0; end
         else begin
            spn = 1;
            spv = spv * 16 + ((vval <= 57) ? vval - 48 : (vval | 32) - 87);
         end
      end
   end
   have_ioout = $value$plusargs("io_out=%s", sbuf);
   if (have_ioout) ofd = $fopen(sbuf, "w");
   have_trace = $value$plusargs("trace=%s", sbuf);
   if (have_trace) tfd = $fopen(sbuf, "w");
   if ($value$plusargs("vcd=%s", sbuf)) begin
      $dumpfile(sbuf); $dumpvars(0, i8080_tb);
   end
   if ($value$plusargs("stim=%s", sbuf)) parse_stim;
   else begin
      ev_sig[0] = 0; ev_val[0] = 0; ev_anch[0] = 0; ev_a[0] = 4; ev_k[0] = 0; nev = 1;
   end
   while (!done) begin
      apply_inputs;
      one_tstate;
      r = r + 1;
   end
   if (have_trace) $fclose(tfd);
   if (have_ioout) $fclose(ofd);
   if ($value$plusargs("dump_start=%h", vval)) dump_start = vval;
   if ($value$plusargs("dump_size=%h", vval)) dump_size = vval;
   if (dump_start + dump_size > 65536) begin
      err = "dump range beyond 64 KiB"; stop_reason = "error";
      dump_size = 0;
   end
   if ($value$plusargs("memdump=%s", sbuf)) begin
      mfd = $fopen(sbuf, "w");
      for (i = dump_start; i < dump_start + dump_size; i = i + 1)
         $fwrite(mfd, "%02x\n", (in_ram(i) || in_rom(i)) ? mem[i] : 8'h00);
      $fclose(mfd);
   end
   if ($value$plusargs("membin=%s", sbuf)) begin
      bfd = $fopen(sbuf, "wb");
      for (i = dump_start; i < dump_start + dump_size; i = i + 1) begin
         dbyte = (in_ram(i) || in_rom(i)) ? mem[i] : 8'h00;
         $fwrite(bfd, "%c", dbyte);
      end
      $fclose(bfd);
   end
   if ($value$plusargs("result=%s", sbuf)) begin
      rfd = $fopen(sbuf, "w");
      $fwrite(rfd, "stop_reason=%0s\n", stop_reason);
      $fwrite(rfd, "halt_a=%04h\n", pc_halt);
      $fwrite(rfd, "halted=%0d\n", twh_seen && stop_why == "hlt");
      $fwrite(rfd, "instructions=%0d\n", instr);
      $fwrite(rfd, "tstates=%0d\n", counted);
      $fwrite(rfd, "samples=%0d\n", n);
      $fwrite(rfd, "pre_sync=%0d\n", pre_sync);
      $fwrite(rfd, "x_samples=%0d\n", xcount);
      $fwrite(rfd, "writes=%0d\n", nwrites);
      $fwrite(rfd, "inputs=%0d\noutputs=%0d\nintas=%0d\nport_dup_errors=%0d\n", nin, nout, ninta, dup_err);
      for (i = 0; i < wlog_n && i < 64; i = i + 1)
         $fwrite(rfd, "write=%04h %02h\n", wlog_a[i], wlog_d[i]);
      if (fault) $fwrite(rfd, "fault=%0s %04h\n", fault_kind, fault_addr);
      if (err != 0) $fwrite(rfd, "error=%0s\n", err);
      $fclose(rfd);
   end
   $finish;
end

endmodule
