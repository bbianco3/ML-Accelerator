# Simulation

This document is the reference for how the simulated system behaves: what
is modelled, what is not, and every knob you can turn.

## The simulated system

```
   +-----------------------+ AXI4-Lite + link delay+--------------+  AXI4 (timed)  +-----------+
   | host_bfm.sv           |---------------------->|  accel_top   |--------------->| hbm_model |
   |  RV64G ISS (C, DPI)   |<--------- irq --------|  (RTL, DUT)  |                |  .sv      |
   +-----------+-----------+                       +--------------+                +-----+-----+
               |                                                                         |
               |           platform.c: host RAM, HBM bytes, ELF loader, console          |
               +------------- functional (host side: cache model in the ROI) -------------+
```

| Piece | File | Accuracy |
|---|---|---|
| Accelerator | `hw/rtl/*` | cycle-accurate RTL (the thing you design) |
| HBM | `sim/tb/hbm_model.sv` + storage in `sim/csrc/platform.c` | transaction-level AXI4 slave with latency, back-pressure and bandwidth limits |
| Host CPU | `sim/csrc/rv64_iss.c` + `host_model.c` via `sim/tb/host_bfm.sv` | instruction-accurate RV64G; inside the region of interest a 2 GHz core with a time and energy model ([host-model.md](host-model.md)) |
| Testbench | `sim/tb/tb_top.sv` | clock, reset, timeout, pass/fail |

## Clock and time

* One clock, drawn with a period of 1 ns (`timescale 1ns/1ps`), so
  **waveform time in ns = cycle number** and `%t` prints cycles.
* What a cycle is worth in real time is the make variable `CLK_PERIOD` (the
  synthesis target, default 2.5 ns). It sets how much time the 2 GHz host
  gets per cycle and how many cycles the host link delay is. Whether your
  RTL really meets that period is decided by [synthesis](synthesis.md).
* Reset (`rst_n` low) is held for the first 10 cycles.
* The host ISS, the HBM model and the DUT all advance on the same clock edge.

## Host CPU model

* Executes **RV64IMAFD + Zicsr + Zifencei** (RV64G) in machine mode. No C
  extension, no virtual memory, no PMP. Floating point uses the simulation
  machine's IEEE arithmetic with correct rounding modes and flags (RMM is
  approximated by RNE).
* **Timing outside the region of interest**: on every clock the ISS
  retires up to `+host_ipc=N` instructions (default 1), with no time or
  energy accounting. This is for setup and result checking.
* **Timing inside the region of interest** (`roi_begin()` ... `roi_end()`):
  a 2 GHz core with instruction latencies, a two-level data cache, a branch
  predictor and an energy model. The log ends with the region's time and
  host energy. See [host-model.md](host-model.md).
* **MMIO**: a load/store to the accelerator CSR window (`0x1000_0000`) stops
  the ISS and becomes a real AXI4-Lite transaction on the DUT's `s_axil`
  port: `LINK_DELAY_NS` (default 5 ns) to get there, 3-4 cycles of
  handshake, and `LINK_DELAY_NS` back. `irq` is delayed by the same amount.
  Only aligned 32-bit accesses are allowed; anything
  else is an access fault. AMOs and FP loads/stores to MMIO are not
  supported.
* **HBM and host RAM** accesses by the host are functional. They cost
  nothing outside the region of interest and ordinary memory-access time
  (cache model) inside it. Host and accelerator see the same bytes (see
  [memory-map.md](memory-map.md) for the coherence rule).
* **Interrupts**: the DUT's `irq` drives `mip.MEIP`. Standard machine-mode
  trap entry via `mtvec` (direct mode) and `mret` are supported. `wfi` stalls
  the ISS until `mip & mie` is non-zero, which is how `accel_wait_irq()`
  sleeps without a trap handler.
* **Unhandled exceptions** (illegal instruction, access fault, `ecall` with
  no `mtvec` installed) stop the simulation with a `HOST FATAL` message
  giving the cause, PC and `mtval`. The test fails with exit code 255.
* Reset state: `pc` = ELF entry (`_start`), registers 0, `mstatus.MPP=M`.

## HBM model

An AXI4 slave with these properties:

| Property | Value / plusarg |
|---|---|
| Read latency (AR handshake to first R beat) | `+hbm_rd_latency=N`, default **40** cycles |
| Write latency (last W beat to B) | `+hbm_wr_latency=N`, default **20** cycles |
| Bandwidth | one `HBM_DATA_W` beat per cycle on R and on W (peak `HBM_DATA_W/8` B/cycle each) |
| Outstanding requests | `+hbm_max_outstanding=N`, default 8 (reads and writes counted separately), served in order |
| Random back-pressure | `+hbm_stall_pct=P`: each cycle each ready/valid is dropped with probability P% (default 0) |
| Address range | `HBM_BASE .. HBM_BASE+HBM_SIZE` (1 GiB). Outside it: `DECERR` |
| Bursts | INCR only, full-width `AxSIZE`. Anything else gives `SLVERR` + `$error`. 4 KiB crossings give `$error`. |
| Storage | sparse 64 KiB pages, zero-initialised |
| Statistics | printed at the end: transactions, beats, bytes, average bytes/cycle |

Back-pressure must never change results, only timing. Running the
regression with `SIM_ARGS=+hbm_stall_pct=25` is a cheap robustness check for
any change to the memory path.

## Runtime plusargs

Pass with `make run TEST=x SIM_ARGS="+a +b=1"`. Per-test defaults can go in
`sw/tests/<test>/plusargs` (one line of plusargs). `SIM_ARGS` is appended
after them, so it wins.

| Plusarg | Default | Effect |
|---|---|---|
| `+elf=<file>` | set by make | host program to load (required) |
| `+timeout=<cycles>` | 50,000,000 | fail the test after this many cycles |
| `+host_ipc=<n>` | 1 | host instructions per cycle **outside** the region of interest. Raise it (16-64) when the host spends long stretches computing reference results. It does not affect the accelerator or the measured region. |
| `+clk_period_ns=<t>` | set by make from `CLK_PERIOD` | real duration of one accelerator clock cycle |
| `+link_delay_ns=<t>` | set by make from `LINK_DELAY_NS` (5) | one-way latency of the host link (register accesses, irq) |
| `+host_trace` | off | print every host instruction (`[host] pc=... insn=...`) |
| `+accel_trace` | off | print every accelerator instruction (`[accel] cyc=... pc=... insn=...`) |
| `+hbm_trace` | off | print every AXI transaction |
| `+hbm_rd_latency=<n>` | 40 | see HBM model |
| `+hbm_wr_latency=<n>` | 20 | |
| `+hbm_max_outstanding=<n>` | 8 | |
| `+hbm_stall_pct=<0-100>` | 0 | random back-pressure |
| `+vcd` | off | dump `waves.vcd` (portable, any viewer, large and slow) |

Decode instruction words in traces with the disassemblies in
`build/sw/<test>/`: `kernel.dis` (accelerator code) and `<test>.dis` (host).

## Compile-time knobs (make variables)

| Variable | Default | Meaning |
|---|---|---|
| `TEST` | `hello` | directory in `sw/tests/` |
| `VLEN MAT_DIM NUM_TREGS NUM_ACCS MXU_ROWS HBM_DATA_W ICACHE_LINES NUM_CORES SPAD_KB NUM_VPUS NUM_MXUS FP_PIPE` | 256 16 4 2 4 256 16 2 16 `NUM_CORES` `NUM_CORES` 1 | RTL parameters, see [parameters.md](parameters.md) |
| `SIM_SRAM` | `behav` | `macro`: build the scratchpads out of the generated ASAP7 SRAM macro models, as synthesis does (runs `hw/sram/sram_gen.py` once; [sram.md](sram.md)) |
| `WAVES` | 0 | 1 = compile with debug access and dump `waves.fsdb` for Verdi |
| `CLK_PERIOD` | `clk_period_ns` in `competition.json` (2.5) | ns per accelerator cycle, shared with `make synth` ([host-model.md](host-model.md)) |
| `LINK_DELAY_NS` | `link_delay_ns` in `competition.json` (5) | one-way host link latency |
| `KERNEL_MARCH` | `rv32i_zicsr` | what the assembler accepts in kernels (`sw/sw.mk`) |
| `SIM_ARGS` | empty | extra plusargs |
| `UNIT_N` | 200000 | iterations of `make unit` |
| `HOST_MARCH`, `HOST_MABI`, `RISCV_PREFIX` | see `sw/sw.mk` | host toolchain |

Each hardware configuration gets its own simulator in `build/sim/<cfg>/`
(e.g. `v256_m16_t4_a2_r4_d256_i16_c2_s16`, plus `_sram` with
`SIM_SRAM=macro`), so switching configurations does not throw away earlier
builds.

## Outputs

```
build/sw/<test>/<test>.elf, .dis            host program + kernels, disassembly
build/sim/<cfg>/simv, compile.log           simulator
build/runs/<cfg>/<test>/sim.log             everything printed during the run
build/runs/<cfg>/<test>/waves.fsdb          with WAVES=1
```

Log line prefixes: `[platform]` ELF loading and host fatal errors, `[tb]`
configuration and result, `[host]` the host program's `printf`, `[accel]`
kernel completion of each core (always) and the instruction trace (with the
core number), `[hbm]` statistics and the transaction trace.

## Pass / fail

The host program's `main()` return value is the test result: `0` prints
`*** TEST PASSED ***`, anything else (or a timeout, or a host fatal error)
prints `*** TEST FAILED ***`. `make run` greps for the pass line and returns
a matching exit status, so `make regress` and CI scripts can rely on it.

## Determinism

Simulations are fully deterministic: same ELF, same plusargs, same RTL gives
the same cycle counts and the same log. `$urandom` (used for back-pressure)
is seeded from VCS's default seed. Pass VCS's `+ntb_random_seed=<n>` to vary
it. Test programs use the deterministic `rand_u32()` from `runtime.c`.

## Waveforms

```sh
make run TEST=matmul WAVES=1      # writes build/runs/<cfg>/matmul/waves.fsdb
make verdi TEST=matmul WAVES=1    # opens Verdi with the design database
```

`WAVES=1` builds a separate simulator with `-debug_access+all`, which
simulates somewhat slower. Over a slow remote connection, either copy the
FSDB back (`run_on_ews.sh` does) or use `SIM_ARGS=+vcd` with GTKWave.

Useful signals (core *i* is `tb_top.dut.g_core[i]`):
`g_core[0].u_core.state_q`, `pc_q`, `insn_q` (what the core is doing);
`u_core.g_vpu.u_vpu.vrf`, `u_core.g_mxu.u_mxu.tile` / `acc` (register contents);
`g_core[0].u_spad.accept`, `s_resp_q` and `u_sram` (scratchpad accesses);
`tb_top.dut.c_bar_wait`, `bar_go` (barriers); `tb_top.dut.u_arb.ar_gnt` and
`tb_top.araddr/arvalid/arid/rvalid/rid` (HBM traffic and which core owns it).

## Tests

| Test | Covers |
|---|---|
| `hello` | host ISS, console, FPU, AXI4-Lite reads of `ID`/`CFG*`; no kernel |
| `host` | the RV64G host itself (64-bit integer, W arithmetic, atomics, FP conversions) and the timed region of interest (cache hits vs. misses); no kernel |
| `vadd` | the minimal kernel (start here) |
| `scalar_ops` | every RV32I instruction the core supports, sub-word loads/stores, `csrr` |
| `vector_ops` | every vector instruction, tail-undisturbed, reductions, NaN/inf/subnormal/signed-zero inputs, 5 values of `vl` |
| `matmul` | `mld`/`mst`/`msta`/`mzero`/`mmacc`, strided tiles, accumulation across two `mmacc` |
| `gemm` | tiled GEMM + vector ReLU, parameter block read with `lw`, interrupt-driven wait |
| `layouts` | one GEMM kernel over all 27 row/col/blocked format combinations (`.t` instructions) |
| `errors` | every error cause, `ERR_PC`/`ERR_INSN`, W1C, recovery |
| `spad` | scratchpad: scalar/vector/matrix accesses, partial stores, transposed tile through the scratchpad, address sweep over every bank, out-of-range bus error, speed vs HBM |
| `units` | cores with different units (`NUM_VPUS`, `NUM_MXUS`): every core does the vector and/or matrix work its units allow in one launch, `CSR_UNITS`, illegal-instruction error on a core without the unit |
| `multicore` | `mhartid`/`ncores`, barriers with unbalanced cores, parallel vadd, `CORES` clamping, one core faulting stops the others, recovery |
| `gemm_tiled` | 64x64x64 GEMM + ReLU split into tiles over all cores, B panel staged in the scratchpad, epilogue in the scratchpad; three runs compared for speed and bit-exactness |
| `lenet` | inference with a **pretrained LeNet-5** on 16 MNIST digits, all cores: im2col + GEMM convolutions, bias/ReLU/max-pool, batched fully connected layers. Logits bit-exact vs. a C model, all 16 digits correct, cycle breakdown per phase. The slowest test (~1 min) |
| `make unit` | RTL FP functions vs the C reference, 10 checks x `UNIT_N` random operands |

`make regress` runs all of them. Before merging a hardware change, run it in
at least two configurations, with and without back-pressure:

```sh
make regress && make regress VLEN=128 MAT_DIM=8 MXU_ROWS=8 SIM_ARGS=+hbm_stall_pct=25 && make unit
make regress NUM_CORES=4 SIM_SRAM=macro        # if you touched the cores, scratchpad or SRAM
make regress FP_PIPE=0 && make regress FP_PIPE=2   # if you touched the VPU or MXU datapath
make regress NUM_CORES=4 NUM_VPUS=1            # if you touched unit selection or decode
```

Tests that need hardware a configuration does not have adapt or say so:
`spad` checks only the bus error when `SPAD_KB=0`, and `gemm_tiled` prints
`SKIP` when a tile does not fit in the scratchpad.

## How big a network can you simulate?

The simulator runs roughly 200-400 K accelerator cycles per CPU second, and
the host ISS a few tens of millions of instructions per second. Software
reference models on the simulated host are often the slow part (raise
`+host_ipc`).

| Network | MACs / image | Weights (bf16) | This design, 2 cores | Practical? |
|---|---|---|---|---|
| LeNet-5 (`sw/tests/lenet`) | 0.42 M | 123 KB | ~0.45 M cycles/image, ~1 min for 16 images incl. the reference | yes, in the regression |
| one AlexNet conv layer (e.g. conv3: 13x13x384, 3x3x256) | 150 M | 1.8 MB | ~100+ M cycles | as a one-off benchmark, minutes to tens of minutes |
| full AlexNet (224x224 ImageNet) | ~720 M | ~122 MB | ~1 G cycles | no: hours of simulation, a >120 MB ELF, and the reference model alone runs for hours |

For anything bigger than LeNet, simulate **one layer** (or a slice of one)
with real shapes, and compute the full network's time from per-layer cycle
counts.

## Known limitations

* Outside the region of interest the host's work is free, and inside it the
  host model is a simple in-order core with order-of-magnitude energy
  constants ([host-model.md](host-model.md)): good for comparing designs,
  not for predicting a real system. Host accesses to HBM cost the same as
  host RAM (HBM is not modelled as slower or faster from the host side).
* One HBM channel shared by all cores. Real HBM has many pseudo-channels;
  model them by adding more AXI ports and `hbm_model` instances.
* No X-propagation checking beyond VCS defaults. All RTL state that matters
  is reset, but large arrays (registers, caches) are not.
