# Accelerator architecture

This describes the reference accelerator in `hw/rtl/`. It is deliberately
simple: correct, readable and parameterised, not fast. It's meant as a
working baseline that you replace piece by piece. [Ideas for
improvement](#where-to-go-from-here) are listed at the end.

## Block diagram

```
                              accel_top
 host  AXI4-Lite  +-----------------------------------------------------------------+
 ---------------->| accel_csr   start, pc, a0..a7, CORES        run status (all cores)|
 <---- irq -------|  (registers) --------+----------------------------^              |
                  |                      |                            |              |
                  |   core 0             v             core 1 .. NUM_CORES-1 (same)  |
                  |  +-------------------------------------------+   +-----------+   |
                  |  | accel_core (control core)                 |   |           |   |
                  |  |  FETCH -> EXEC FSM, x0..x31, pc, vl       |   |   ...     |   |
                  |  |  +---------+  +------------+ +----------+ |   |           |   |
                  |  |  | icache  |  | accel_vpu  | | accel_mxu| |<->| barrier / |   |
                  |  |  |         |  | v0..v31    | | tr*, acc*| |   | abort     |   |
                  |  |  +---------+  +------------+ +----------+ |   |           |   |
                  |  +---------------------+---------------------+   +-----+-----+   |
                  |                        | req / resp                    |         |
                  |  +---------------------v---------------------+         |         |
                  |  | accel_spad: address router + scratchpad   |        ...        |
                  |  |   0x2000_0000.. --> accel_sram_1rw (SRAM) |         |         |
                  |  |   anything else --> accel_axi_master      |         |         |
                  |  +---------------------+---------------------+         |         |
                  |                        | AXI4, ID = core index         |         |
                  |                  +-----v-------------------------------v-----+   |
                  |                  | accel_axi_arbiter (N -> 1, round robin)    |   |
                  |                  +---------------------+----------------------+   |
                  +----------------------------------------+--------------------------+
                                                           | AXI4 (HBM_DATA_W bits)
                                                           v
                                                          HBM
```

The accelerator has `NUM_CORES` identical **compute cores**. Each one is a
complete small accelerator: a control core with its own vector unit (VPU),
matrix unit (MXU, the "TPU"), instruction cache and private scratchpad
SRAM. All cores share the HBM port. The host launches 1..NUM_CORES of them
on the same kernel, and they split the work by core index (SPMD, like
threads in a GPU block).

| Module | File | Role |
|---|---|---|
| `accel_top` | `accel_top.sv` | Wrapper. All external ports, parameter checks, `NUM_CORES` core instances, run status, barrier. This is what you integrate. |
| `accel_csr` | `accel_csr.sv` | AXI4-Lite slave: control/status registers, kernel arguments, IRQ. |
| `accel_core` | `accel_core.sv` | Control core: fetch/decode/execute FSM, scalar RV32I datapath, sequencing of all memory, vector and matrix operations. |
| `accel_icache` | `accel_icache.sv` | Direct-mapped instruction cache, one line = one HBM beat, flushed at every launch. |
| `accel_vpu` | `accel_vpu.sv` | Vector register file and VLMAX bf16 lanes. |
| `accel_mxu` | `accel_mxu.sv` | Tile/accumulator registers and the MAT_DIM x MXU_ROWS MAC array. |
| `accel_spad` | `accel_spad.sv` | Per-core scratchpad and address router: scratchpad addresses go to the SRAM, everything else to HBM. |
| `accel_sram_1rw` | `accel_sram_1rw.sv` | Generic single-port SRAM. A behavioral array in simulation, tiled out of generated ASAP7 SRAM macros in synthesis ([sram.md](sram.md)). |
| `accel_axi_master` | `accel_axi_master.sv` | Turns "move 2^n aligned bytes" requests into AXI4 bursts. |
| `accel_axi_arbiter` | `accel_axi_arbiter.sv` | Shares the HBM port between the cores; routes responses back by AXI ID. |
| `accel_pkg` | `accel_pkg.sv` | Opcodes, CSR offsets, error codes, scratchpad address. |
| `accel_fp_pkg` | `accel_fp_pkg.sv` | Synthesizable bf16/fp32 functions (see [numerics.md](numerics.md)). |

## External interface

`accel_top` has one clock domain and four port groups:

| Group | Signals | Notes |
|---|---|---|
| Clock/reset | `clk`, `rst_n` | Single clock. **Synchronous, active-low** reset; hold for at least 1 cycle. |
| Host control | `s_axil_*` | AXI4-Lite slave, 32-bit data, 12-bit (4 KiB) address. Register map in [memory-map.md](memory-map.md). |
| Interrupt | `irq` | Level-sensitive, active high. `IRQ_EN & (DONE | ERROR)`. Cleared by writing 1s to `STATUS` or by starting a new kernel. |
| HBM | `m_axi_*` | AXI4 master: `AW/W/B/AR/R` with ID, LEN, SIZE, BURST. `AxLOCK/CACHE/PROT/QOS/REGION/USER` are not present; tie them to their defaults (0, `0011`, `000`, 0) when connecting to a real HBM controller. |

The HBM port uses only INCR bursts with full-width beats (`AxSIZE =
log2(HBM_DATA_W/8)`) and never crosses a 4 KiB boundary. Each core has at
most **one transaction outstanding**; its AXI ID is its core index, so with
several cores up to `NUM_CORES` transactions are in flight. Responses may
come back in any order between IDs. Write data is never interleaved.

## Execution model

1. The host writes the kernel's entry address to `START_PC`, up to eight
   arguments to `ARG0..ARG7` and the number of cores to use to `CORES`
   (1 by default), then writes `CTRL.START`.
2. Each launched core (0 .. CORES-1) flushes its I-cache, sets `pc =
   START_PC`, `x10..x17 (a0..a7) = ARG0..ARG7`, all other `x` registers to 0
   and `vl = VLMAX`, and starts fetching. All cores run the same code; a core
   finds out who it is with `csrr t0, mhartid`.
3. Each core runs on its own, out of HBM, until it executes `ecall`
   (success) or faults (illegal instruction, misaligned or out-of-range
   access, `ebreak`, bad register index). A fault on one core stops the
   others at their next instruction fetch.
4. When no launched core is running any more, the accelerator reports
   `DONE` (and `ERROR` + cause + PC + core of the first fault) in `STATUS`
   and raises `irq` if enabled.

Vector registers, tile registers and accumulators are **not** cleared
between launches. A kernel may rely on state left by a previous kernel only
if the host guarantees the order; normally kernels initialise what they use
(`mzero`, loads).

### The control core FSM

The core is an **unpipelined multi-cycle FSM**. Exactly one instruction is in
flight, and each one finishes, including all of its memory traffic, before
the next is fetched:

```
IDLE --start--> FETCH --hit--> EXEC --+--> FETCH                  (scalar ALU / branch / csrr / vsetvl)
                  |                   +--> MEM -> MEM_WAIT -> FETCH          (lw/sw, vle16/vse16)
                  +--miss--> IFILL    +--> VPU_WAIT -> FETCH                 (vector arithmetic)
                             -> IFILL_WAIT -> FETCH
                                      +--> MX_ROW -> MX_ROW_WAIT -> ... (MAT_DIM rows) -> FETCH
                                      +--> MXU_WAIT -> FETCH                 (mzero / mmacc)
                                      +--> BARRIER -> FETCH                  (barrier)
                                      +--> IDLE (ecall / fault)
```

Consequences:

* **No hazards.** A kernel never needs fences or stalls between dependent
  instructions, and memory operations are globally ordered.
* **Performance is latency-bound.** Every vector load or matrix row waits a
  full HBM round trip. See [Performance](#performance).

### Vector unit (VPU)

* 32 registers `v0..v31` of `VLEN` bits, holding `VLMAX = VLEN/16` bf16
  elements each. Element *i* is bits `[16i+15:16i]` (little-endian, same as
  memory).
* A `vl` register (set by `vsetvl`) masks every operation: elements `i >= vl`
  of the destination are **left unchanged** ("tail undisturbed").
* Element-wise ops compute all VLMAX lanes in one cycle. Each lane has one
  exact bf16 multiplier and one fp32 adder, shared by add, sub and multiply-accumulate.
* Reductions (`vfredsum`, `vfredmax`) walk elements 0..vl-1 one per cycle
  through a single adder, which fixes the summation order.
* Vector loads/stores move exactly `VLEN/8` bytes (masked by `vl` for
  stores) and must be aligned to `VLEN/8`.

### Matrix unit (MXU)

* `NUM_TREGS` tile registers `tr*`, each `MAT_DIM x MAT_DIM` bf16, and
  `NUM_ACCS` accumulators `acc*`, each `MAT_DIM x MAT_DIM` fp32.
* `mmacc acc, ta, tb` computes `acc += ta x tb`. For each `k = 0..MAT_DIM-1`
  (in order) it updates `MXU_ROWS` output rows per cycle with `MXU_ROWS x
  MAT_DIM` MAC units. One `mmacc` takes `MAT_DIM*MAT_DIM/MXU_ROWS` cycles.
  `MXU_ROWS` changes area and speed, never results.
* Each MAC is `acc = fp32_add(acc, bf16 x bf16)`. The product is exact, and
  the accumulation is rounded to fp32 once per step.
* `mld`/`mst`/`msta` move a tile one row at a time (`MAT_DIM*2` bytes per
  row) with an arbitrary row stride, so tiles can be cut out of larger
  row-major matrices. `msta` rounds the fp32 accumulator to bf16 on the way
  out.

### Memory engine

The core issues requests of the form *(read|write, address, 2^size bytes)*,
with sizes from 1 byte up to `XFER_W/8` bytes, where `XFER_W = max(VLEN,
MAT_DIM*16, HBM_DATA_W)` bits. `accel_spad` decides where each one goes:

* **Scratchpad** (`0x2000_0000 .. 0x20FF_FFFF`): served by the core's SRAM.
  The SRAM word is `XFER_W` bits, so any access, from a byte to a whole
  vector or tile row, takes **one SRAM cycle**: a request accepted in cycle
  *t* is answered in cycle *t+1*. Narrow writes use the SRAM's bit mask.
  Addresses beyond `SPAD_KB` KiB return a bus error.
* **HBM** (everything else): `accel_axi_master` turns transfers smaller than
  a bus beat into one strobed beat and larger ones into one INCR burst, and
  returns the result in one cycle as a single wide word.

### Scratchpad

Each core has `SPAD_KB` KiB of private SRAM at `SPAD_BASE = 0x2000_0000`
(the same address on every core, like GPU shared memory or a Tenstorrent
core's L1). It is ordinary memory to the kernel: `lw/sw`, `vle16/vse16` and
`mld/mst/msta` all work on it, and the strided and transposed (`.t`) tile
forms make it easy to keep tiles in any layout. The host cannot see it.
Kernels copy data in and out themselves, typically `mld` from HBM followed by
`mst` to the scratchpad. [gemm_tiled](../sw/tests/gemm_tiled/kernel.S) is the
worked example.

Why it helps: a tile row from HBM costs a full round trip (~45 cycles with
the default model), from the scratchpad 2 cycles. A tile that is used more
than once (the B panel of a tiled GEMM, weights of a layer) should be
fetched from HBM once and then re-read from the scratchpad.

In synthesis the scratchpad is built from ASAP7 SRAM macros produced by the
SRAM generator, so its area, timing and power are counted in the reports.
See [sram.md](sram.md).

### Multiple cores

* `NUM_CORES` (1..16) compute cores, each with its own VPU, MXU,
  registers, I-cache and scratchpad, so `NUM_CORES` vector or tensor
  operations run at the same time.
* `NUM_VPUS` / `NUM_MXUS` (default: all cores) give only the first cores a
  vector / matrix unit, e.g. one VPU and four MXUs. Each unit works with its
  own core's scratchpad, independently of the others
  ([parameters.md](parameters.md#unit-counts-num_vpus-num_mxus)).
* `FP_PIPE` (0, 1 or 2; default 1) puts register stages into the VPU and
  MXU datapaths ([parameters.md](parameters.md#pipelining-fp_pipe)).
* `CORES` (host register) selects how many start: cores `0 .. CORES-1`.
* Kernel CSRs: `mhartid` = core index, `0xFC0` = number of cores launched,
  `0xFC1` = scratchpad bytes, `0xFC2` = units of this core (bit 0 VPU,
  bit 1 MXU).
* `barrier` (custom-3) waits until every launched core has reached a
  barrier or finished. Because each core finishes every memory operation
  before the next instruction, all HBM writes before a barrier are visible
  to every core after it.
* HBM is shared through `accel_axi_arbiter` (round robin). Scratchpads are
  private: cores share data only through HBM.
* Run status: `DONE` when every launched core has stopped; `CYCLES` counts
  the whole run; `INSTRET` is the sum over cores. The first core to fault is
  reported in `ERR_CORE`/`ERR_PC`/`ERR_INSN` and stops the others.

### Instruction cache

Direct-mapped, `ICACHE_LINES` lines of one HBM beat (`HBM_DATA_W/32`
instructions) each, read-only, flushed at every launch. A miss costs one HBM
round trip. Keep inner loops within a few lines; with the defaults the whole
cache holds 128 instructions.

## Performance

With the default parameters and the default HBM model latency (40 cycles):

| Operation | Approximate cycles |
|---|---|
| scalar instruction (I-cache hit) | 2 |
| I-cache miss | + ~45 |
| `vle16` / `vse16` / `lw` / `sw` | ~45 (latency + 5) |
| element-wise vector op | 4 |
| reduction | vl + 4 |
| `mld` / `mst` / `msta` | MAT_DIM x ~45 (HBM), MAT_DIM x 2 (scratchpad) |
| scalar / vector load or store to the scratchpad | 4 |
| `mmacc` | MAT_DIM*MAT_DIM/MXU_ROWS + 3 |
| `barrier` | 1 after the last core arrives |

Use the `CYCLES` / `INSTRET` registers (host side) or `csrr cycle` (kernel
side) to measure. The `gemm` test prints MACs/cycle: about 2 MACs/cycle
against a peak of `MAT_DIM*MXU_ROWS` = 64 per core, because tile loads from
HBM dominate. `gemm_tiled` (64x64x64, default configuration) shows what the
scratchpad and the second core buy:

| Run | Cycles | MACs/cycle | Speed-up |
|---|---|---|---|
| 1 core, B tiles from HBM | 110,159 | 2.37 | 1.00x |
| 1 core, B panel kept in the scratchpad | 80,323 | 3.26 | 1.37x |
| 2 cores, B panel in each core's scratchpad | 40,679 | 6.44 | 2.70x |
| 4 cores (`NUM_CORES=4`), same | 20,877 | 12.55 | 5.27x |

The A tiles still stream from HBM one row at a time, so the next big step is
fetching more than one row at a time (see below).

## Where to go from here

The template is meant to be modified. Some natural projects, roughly in
order of effort:

1. **Multiple outstanding AXI transactions.** Issue all MAT_DIM row reads of
   an `mld` back to back (AXI allows many outstanding reads; the arbiter
   already routes by ID). This is the single biggest speed-up for matrix
   kernels.
2. **Decoupled execution.** Let scalar instructions run while the MXU
   computes (add a scoreboard on tile/accumulator registers), and overlap
   `mld` of the next tiles with `mmacc` of the current ones (double
   buffering with `tr2`/`tr3`).
3. **Pipelining** the control core and adding a real fetch buffer or
   branch prediction.
4. **A DMA engine** that copies HBM <-> scratchpad in the background
   (whole tiles in one burst) while the core computes, i.e. double
   buffering. Or a **shared** scratchpad that all cores can read.
5. **Systolic array MXU** (weight- or output-stationary) instead of the
   broadcast MAC array.
6. **New instructions**: strided/indexed vector loads, `vexp`/`vrecip` for
   softmax, int8 MACs, fused activation on `msta`. Add them to
   `accel_pkg.sv`, `accel_isa.h`, `docs/isa.md` and `bf16.h` together.

Any change that keeps the ISA and numerics contract keeps every existing
test passing, so `make regress` is your safety net.
