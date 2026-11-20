# Hardware parameters

These are the hardware parameters of the reference design. The shell
declares all of them on `accel_top` and the Makefile passes them down; in
your design, use them, give them the meaning that fits, or add your own.
(The clock period, area target and synthesis settings are not hardware
parameters: they are in `competition.json`, see
[competition.md](competition.md).) In the flows they are make variables: `make run VLEN=512`, `make synth MXU_ROWS=16`.
Illegal values stop elaboration with a `$fatal` explaining the rule (in
simulation; DC trusts you).

| Parameter | Default | Legal values | Meaning |
|---|---|---|---|
| `VLEN` | 256 | power of 2, >= 32 | bits per vector register. `VLMAX = VLEN/16` bf16 lanes. |
| `MAT_DIM` | 16 | power of 2, >= 2 | tile size: tiles are `MAT_DIM x MAT_DIM` |
| `NUM_TREGS` | 4 | 2..32 | number of bf16 tile registers |
| `NUM_ACCS` | 2 | 1..32 | number of fp32 accumulators |
| `MXU_ROWS` | 4 | divides `MAT_DIM` | output rows computed per cycle by `mmacc` |
| `HBM_DATA_W` | 256 | power of 2, >= 32 | AXI data width (bits) = I-cache line size |
| `HBM_ADDR_W` | 32 | 32 | AXI address width (kernel addresses are 32-bit) |
| `HBM_ID_W` | 4 | `2^HBM_ID_W >= NUM_CORES` | AXI ID width (ID = core index) |
| `ICACHE_LINES` | 16 | power of 2, >= 2 | I-cache lines (per core) |
| `NUM_CORES` | 2 | 1..16 | compute cores, each with its own control core, I-cache and scratchpad |
| `NUM_VPUS` | `NUM_CORES` | 0..`NUM_CORES` | cores `0 .. NUM_VPUS-1` have a vector unit |
| `NUM_MXUS` | `NUM_CORES` | 0..`NUM_CORES` | cores `0 .. NUM_MXUS-1` have a matrix unit |
| `FP_PIPE` | 1 | 0, 1, 2 | register stages in the VPU and MXU floating-point datapaths |
| `SPAD_KB` | 16 | 0 or power of 2, <= 16384 | scratchpad KiB **per core** (0 = no scratchpad) |

Also required: one transfer (`XFER_W = max(VLEN, MAT_DIM*16, HBM_DATA_W)`
bits) must fit in 256 AXI beats, and a scratchpad must hold at least two
`XFER_W`-bit words (its SRAM word is `XFER_W` bits wide).

Everything in a core (registers, units, I-cache, scratchpad) is replicated
`NUM_CORES` times, except that only the first `NUM_VPUS` / `NUM_MXUS` cores
get a vector / matrix unit.

### Unit counts: `NUM_VPUS`, `NUM_MXUS`

A unit always belongs to one core and uses that core's scratchpad; units of
different cores never wait for each other. The counts let you buy only the
units a workload uses:

| Configuration | Cores |
|---|---|
| `NUM_CORES=2` (default) | 2 x (VPU + MXU) |
| `NUM_CORES=4 NUM_VPUS=1` | 1 x (VPU + MXU), 3 x MXU only |
| `NUM_CORES=4 NUM_MXUS=1` | 1 x (VPU + MXU), 3 x VPU only |
| `NUM_CORES=4 NUM_VPUS=2 NUM_MXUS=2` | 2 x (VPU + MXU), 2 x scalar only |

An instruction for a unit the core does not have stops the run with
`ILLEGAL`. A kernel asks with `csrr t0, CSR_UNITS` (bit 0 = VPU, bit 1 =
MXU); the host reads `num_vpus`, `num_mxus` and `num_full_cores` (cores
with both) from `accel_get_config()`. The example tests assume core 0 has
both. See `sw/tests/units`.

### Pipelining: `FP_PIPE`

| `FP_PIPE` | VPU lane datapath | MXU MAC datapath | Cost in cycles |
|---|---|---|---|
| 0 | multiply, add, round in one cycle | multiply and accumulate in one cycle | -- |
| 1 (default) | multiply \| add, round | multiply \| accumulate | +1 per element-wise vector op, +1 per `mmacc` |
| 2 | multiply \| add \| round | as 1 | +2 per element-wise vector op, +1 per `mmacc` |

In the MXU the stage is a real pipeline: the multipliers work on the next
step while the adders accumulate the previous one, so `mmacc` keeps its
throughput. The accumulate adder (`acc += product`) and the reduction adder
are one-cycle loops and are not split. Results are bit-identical for every
`FP_PIPE`. The point is the clock: a shorter critical path lets the design
close timing at a smaller `CLK_PERIOD` (or with less area at the same one),
at the price of pipeline registers and a few cycles.

The simulation and synthesis flows also take:

| Make variable | Default | Meaning |
|---|---|---|
| `SIM_SRAM` | `behav` | `macro`: simulate the scratchpads built from the generated SRAM macro models, exactly as synthesized ([sram.md](sram.md)) |
| `SRAM` | `macro` | synthesis: `macro` = ASAP7 SRAM macros, `flops` = flip-flop arrays (for comparison; much bigger) |

## What each parameter costs and buys

| Parameter | Storage (flip-flops) | Logic | Performance |
|---|---|---|---|
| `VLEN` | `32 x VLEN` (vector RF) | `VLEN/16` lanes, each a bf16 multiplier + fp32 adder | elements per vector instruction |
| `MAT_DIM` | `NUM_TREGS x 16 x MAT_DIM^2` + `NUM_ACCS x 32 x MAT_DIM^2` | MAC array width | work per `mmacc` grows with `MAT_DIM^3` |
| `MXU_ROWS` | -- | `MXU_ROWS x MAT_DIM` MAC units | `mmacc` takes `MAT_DIM^2 / MXU_ROWS` cycles |
| `NUM_TREGS`, `NUM_ACCS` | see `MAT_DIM` | read muxes | room for double-buffering / multiple outputs |
| `HBM_DATA_W` | I-cache data | AXI datapath width | bytes per HBM beat |
| `ICACHE_LINES` | `ICACHE_LINES x HBM_DATA_W` | -- | fewer instruction misses in big loops |
| `SPAD_KB` | none: SRAM macros, `SPAD_KB x 8 Kbit` | address router, byte shifter | tiles re-read from the scratchpad in 2 cycles/row instead of ~45 |
| `FP_PIPE` | 64 (stage 1) + 32 (stage 2) flops per VPU lane, 32 per MXU MAC unit | shorter FP paths | higher clock, +1/+2 cycles per op |
| `NUM_VPUS`, `NUM_MXUS` | the unit's registers x count | the unit's datapath x count | parallel vector / matrix work only on cores that have the unit |
| `NUM_CORES` | everything above x `NUM_CORES` | everything above x `NUM_CORES`, plus the AXI arbiter | up to `NUM_CORES` x on parallel work, until HBM bandwidth runs out |

At the defaults one core holds about 8 Kbit of vector registers, 16 Kbit of
tiles, 16 Kbit of accumulators and 4 Kbit of I-cache, roughly 45 K
flip-flops, plus a 128 Kbit scratchpad in SRAM macros. Registers stay in
flip-flops because the units read many of them every cycle. See
[design-decisions.md](design-decisions.md) and [sram.md](sram.md).

## Things that are *not* parameters (yet)

* Number of vector registers (32, set by the 5-bit encoding).
* Element type (bf16 only).
* Number of HBM ports (1) and outstanding AXI transactions per core (1).
* Scratchpad word width (always `XFER_W`) and sharing (private per core).
* Number of kernel arguments (8 = `a0..a7`; pass a pointer to a parameter
  block for more, as the `gemm` test does).

## Discovering the configuration at runtime

Software should never hard-code these values. Read them from the `CFG*`
registers (`accel_get_config()` on the host; `csrr` of `CSR_VLENB`,
`CSR_NCORES`, `CSR_SPADSZ` in a kernel) and use `vsetvl` for vector lengths. Every test in `sw/tests`
works unchanged for any legal configuration, and `make regress VLEN=...`
checks that.
