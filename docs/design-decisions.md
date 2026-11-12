# Design decisions

Why the template is built the way it is, and what was considered instead.
Read this before proposing a big architectural change. If you change one of
these decisions, update this file.

## 1. Host-accelerator interface: memory-mapped registers, not custom host instructions

**Decision.** The host talks to the accelerator only through memory-mapped
registers on an AXI4-Lite port (`START_PC`, `ARG0-7`, `CTRL`, `STATUS`) plus
an interrupt line. The host CPU (RV64G) has **no custom instructions**.

**Alternative considered.** A tightly coupled coprocessor: the host executes
custom instructions (RISC-V custom-0..3 opcodes) that are handed to the
accelerator through a coprocessor port, like Rocket's RoCC (used by Gemmini)
or the CORE-V eXtension Interface (CV-X-IF).

**Why MMIO wins here:**

| | MMIO (chosen) | Custom host instructions |
|---|---|---|
| Launch cost | ~10 register writes, ~40-60 cycles, against kernels of thousands of cycles: < 5 % | a few cycles |
| Works with | any CPU: the ISS, PicoRV32, CVA6, an FPGA soft core, even an ARM | only a host core you modify |
| Host software | plain C (`volatile` pointers in `accel.h`) | compiler/assembler macros, plus a decoder change in the host core |
| Hardware interface | standard AXI4-Lite slave; drops into any SoC/FPGA interconnect | custom port with its own rules for ordering, stalls, exceptions and register-file access |
| Status / debug | registers readable from anywhere, any time | still needs MMIO or extra instructions for status |
| Fits an *autonomous* accelerator | yes: the accelerator fetches its own program | mostly pointless: if the host issues every operation, the accelerator doesn't need its own core |

Custom host instructions pay off when the host issues **fine-grained work
continuously**, for example one matrix op every few cycles with no
accelerator-side program. That is a different architecture: no control
core, and the host CPU acts as the sequencer. It's a legitimate design, but
it couples the accelerator to one specific CPU and adds a second interface
to verify.

**If you want to learn about custom instructions anyway**, there is a small
self-contained exercise: add an `accel.launch rs1, rs2` instruction to the
host ISS (`sim/csrc/rv64_iss.c`, custom-0 opcode) that performs the same
register writes as `accel_launch()`. It's about 30 lines and touches no RTL.

## 2. An autonomous accelerator with its own small RV32I control core

**Decision.** The accelerator fetches and executes its own instruction
stream (RV32I subset + vector/matrix extensions) from HBM, so the host
launches a whole kernel and waits.

**Why:** the host is free while the kernel runs, launch overhead is paid
once per kernel, and loops/address arithmetic run next to the data. Reusing
RISC-V encodings means the standard GNU assembler builds kernels, so no
custom assembler has to be written or maintained.

**Cost:** a second (small) core to verify. The `scalar_ops` test covers it.

## 3. Simulated host: an instruction-set simulator over DPI, not RTL

**Decision.** The RV64G host is a C ISS linked into VCS through DPI-C, with
its accelerator accesses turned into real AXI4-Lite transactions. Inside a
region of interest it is timed as a 2 GHz core and charged energy per
instruction and cache/branch event ([host-model.md](host-model.md)), in the
spirit of gem5 + McPAT but without a second simulator to build and
co-simulate.

**Why:** it's fast, runs real compiled C (including floating point for
reference checks), and keeps the RTL under test = only your accelerator.
Replacing it with an RTL core later (e.g. CVA6 in one of its 32-bit
configurations, or any core with an AXI port) only requires connecting that
core's bus to the same `s_axil` port and HBM.
The software and register map stay the same.

## 4. Matrix storage formats are software, built on two hardware primitives

**Decision.** The hardware supports *strided* tile rows (`mld base, stride`)
and *transposed* tiles (`mld.t`). Row-major (any leading dimension),
column-major and tile-blocked formats are all expressed with those two, and
`sw/common/mat_layout.h` turns a format into a tile descriptor
`{base, rstep, cstep, stride, xpose}`. See
[memory-formats.md](memory-formats.md).

**Why:** a format is just address arithmetic, so it belongs in software
where it is cheap to change and easy to test. The `layouts` test proves
that all 27 format combinations of a GEMM give identical bits. Only genuinely
non-strided formats (swizzles, sparsity) need new hardware.

## 5. Registers in flip-flops, scratchpads in SRAM macros from our own generator

**Decision.** Vector registers, tiles, accumulators and the I-cache are
flip-flop arrays. Each core's scratchpad is an SRAM, built in synthesis
from ASAP7 macros produced by `hw/sram/sram_gen.py`. See [sram.md](sram.md).

**Why registers stay in flops:** they allow unlimited read ports, and the
MAC array uses that: a whole column of A, a whole row of B and `MXU_ROWS`
accumulator rows every cycle. A single-port SRAM gives one word per cycle.

**Why the scratchpad is SRAM:** it is big (16 KiB per core by default),
and it is accessed one word per cycle, which is exactly what a single-port
SRAM does well. Area per bit:

| Storage | ASAP7 (default PDK) | FreePDK45 |
|---|---|---|
| flip-flop (`DFFHQNx1` / `DFF_X1`) | 0.29 um^2 cell, ~0.4-0.5 um^2 with muxing | 4.5 um^2 cell, ~6-8 um^2 with muxing |
| SRAM macro, 512 x 128 (sram_gen) | 0.034 um^2 | -- |
| SRAM macro, 64 x 32 (sram_gen) | 0.072 um^2 (periphery dominates) | -- |
| SRAM macro (OpenRAM, for comparison) | -- | 1.25 um^2 (128 x 256), 42 um^2 (16 x 2) |

**Why our own generator rather than FakeRAM7 or OpenRAM:**

* OpenRAM does not support ASAP7.
* The FakeRAM7 libraries that OpenROAD-flow-scripts ships for ASAP7 have
  area proportional to bits, but **the same placeholder timing and power for
  every size** (218 ps access, 129 uW leakage, constant energy), and they use
  ns while the ASAP7 cells use ps. With those numbers a 64 x 21 macro and a
  2048 x 39 macro look identical in timing and power reports.
* `sram_gen.py` is about 500 lines of Python: an analytical model of a 6T
  array (bit cells, decoder, column mux, sense amplifiers) whose area,
  access time, energy per read/write and leakage all depend on the size. It
  writes Liberty in ASAP7's units. The numbers are estimates, tuned to
  published 7 nm-class figures, not silicon data, but trade-offs (deep vs.
  wide, one big vs. several small macros) come out right. Students can read
  and change the model.

**Wrapper:** all RTL uses `accel_sram_1rw #(DEPTH, WIDTH)`. In simulation it
is a behavioral array. In synthesis (and in simulation with
`SIM_SRAM=macro`) it tiles the memory out of catalog macros (width <= 128,
depth <= 512, extra banks selected by address). There is one wrapper and
one catalog, so adding a macro size is a two-file change.

**Alternatives** still open: OpenRAM macros with FreePDK45 (real layouts,
`/class/ece411/sram_cache` on EWS); `bsg_fakeram` with a better config;
DesignWare `DW_ram_*` (flops/latches, no saving); commercial compilers (not
available to students).

**Architectural effect:** an SRAM gives one access per port per cycle with
one cycle of latency. That is why the scratchpad sits *next to* the tile
registers (a 2-cycle-per-row source for `mld`) instead of replacing them.

## 6. Exact, reproducible numerics

**Decision.** bf16 storage, fp32 compute, RNE, flush subnormals, canonical
NaN, fixed accumulation order. See [numerics.md](numerics.md).

**Why:** tests can compare with `==` instead of tolerances, so a one-bit
hardware bug is caught immediately, and the C reference model is short
enough to read in five minutes.

## 7. Deliberately slow reference microarchitecture

**Decision.** Unpipelined control core, one AXI transaction in flight,
blocking vector/matrix instructions.

**Why:** correctness and readability first. Every improvement (pipelining,
outstanding requests, decoupling, burst merging) is a self-contained,
measurable project, and the regression suite tells you immediately if it
broke something. See [architecture.md](architecture.md#where-to-go-from-here).

## 8. Several compute cores, not several units behind one core

**Decision.** "Multiple VPUs/MXUs" means `NUM_CORES` complete compute
cores, each with its own control core, VPU, MXU, I-cache and scratchpad,
running the same kernel (SPMD) and sharing HBM. Cores coordinate with
`barrier` and through HBM.

**Alternative considered.** One control core issuing to several VPUs/MXUs
asynchronously (like a VLIW or a decoupled TPU core): `mmacc` on MXU 0
returns immediately, the core loads tiles for MXU 1, and so on, with a
scoreboard tracking which unit owns which registers.

**Why cores:**

| | Several cores (chosen) | Several units behind one core |
|---|---|---|
| Hardware change | replicate a verified block, add an AXI arbiter and a barrier | scoreboard, hazard checks and per-unit register ownership in the core FSM |
| New hazards | none inside a core; between cores only through HBM, with `barrier` | WAR/RAW hazards between units and tile loads, a new class of bugs |
| Speed-up limited by | HBM bandwidth (shared port) | the single core's issue rate: it must load ~2 tiles per `mmacc` |
| Vector work | parallel too (each core has a VPU) | one more VPU barely helps: element-wise ops already take 1 cycle |
| Programming model | SPMD with `mhartid`, like GPU threads / Tenstorrent cores | one instruction stream, explicit unit numbers |
| Cost | the control core, I-cache and arbiter are replicated (small next to the MXU) | cheaper per extra MXU |

For a 3-week student project, the replicated core is the safer choice: the
existing regression covers each core unchanged, and the new parts (arbiter,
barrier, abort) are small and have their own tests (`multicore`,
`gemm_tiled`). A decoupled MXU inside each core is listed as a project in
[architecture.md](architecture.md#where-to-go-from-here); it combines with
multiple cores.

