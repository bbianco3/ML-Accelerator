# Glossary

The documents use these terms, and only these, for the things below.

## The system

| Term | Meaning |
|---|---|
| **template** | this repository |
| **platform** | everything around the accelerator that is fixed: host CPU, link, HBM, testbench |
| **host CPU** (short: **host**) | the simulated 2 GHz RV64G processor that runs the host program |
| **accelerator** | the design inside `accel_top`: what you build |
| **shell** | `hw/rtl/accel_top.sv` as distributed: the fixed ports with nothing behind them |
| **reference design** | a complete accelerator built by the template's authors. It is not distributed; the documents describe it, the software targets it and the reference results were measured on it |
| **link** | the connection between host CPU and accelerator (host registers and interrupt), with a fixed one-way delay |
| **HBM** | the memory shared by host CPU and accelerator, reached by the accelerator through its AXI4 port |
| **settings file** | `competition.json`: design and synthesis settings (yours) and platform settings (fixed) |

## Inside the reference design

| Term | Meaning |
|---|---|
| **compute core** (short: **core**) | one control core with its units, instruction cache and scratchpad. The accelerator has `NUM_CORES` of them |
| **control core** | the small processor inside a compute core that fetches and executes kernel instructions |
| **unit** | a vector unit or a matrix unit |
| **vector unit (VPU)** | executes the bf16 vector instructions; `VLEN` bits per register |
| **matrix unit (MXU)** | executes the tile and matrix instructions. Other texts call this a tensor unit or TPU |
| **matrix engine** | the part of a matrix unit that multiplies: a tiled accumulator, dot-product engines or a systolic array ([matrix-engines.md](matrix-engines.md)) |
| **scratchpad** | a core's private SRAM at `SPAD_BASE` |
| **instruction cache (I-cache)** | a core's small cache of kernel instructions |
| **memory path** | everything between a core's load/store request and the scratchpad or HBM |
| **ISS** | instruction-set simulator: the C model of the host CPU |
| **host registers** | the accelerator's memory-mapped registers on the AXI4-Lite port (`ID`, `CTRL`, `STATUS`, ...), accessed by the host CPU |
| **kernel CSRs** | read-only registers a kernel reads with `csrr` (`mhartid`, `CSR_NCORES`, ...) |

## Data

| Term | Meaning |
|---|---|
| **bf16** | 16-bit brain floating point: the format of all data in memory and in vector and tile registers |
| **fp32** | IEEE single precision: the format of intermediate results and accumulators |
| **vector register** | `v0..v31`, `VLMAX = VLEN / 16` bf16 elements each |
| **tile** | a `MAT_DIM x MAT_DIM` block of a matrix |
| **tile register** | `tr0..`, holds one bf16 tile |
| **accumulator** | `acc0..`, holds one fp32 tile of running sums |
| **multiply-accumulate (MAC)** | `acc += a x b`, the basic operation of a matrix engine |
| **memory format** | how a matrix is laid out in memory: row-major, column-major or blocked |

## Software

| Term | Meaning |
|---|---|
| **host program** | the C program of a test (`main.c`), run by the host CPU |
| **kernel** | a program run by the accelerator (a `.S` file), launched by the host program |
| **driver** | `sw/common/accel.h`: the host-side functions that access the host registers |
| **reference model** | `sw/common/bf16.h`: the C definition of the arithmetic |
| **test** | a directory in `sw/tests/`: one host program with its kernels |
| **launch** | the host starting a kernel on one or more cores |

## Measuring

| Term | Meaning |
|---|---|
| **region of interest** | the part of a host program between `roi_begin()` and `roi_end()`: the only part that is timed and charged energy |
| **clock period** | the accelerator's clock period, `design.clk_period_ns` / `CLK_PERIOD`, used by synthesis and simulation alike |
| **area target** | `design.max_area_um2` / `MAX_AREA_UM2`: the area synthesis aims for and `make limits` checks |
| **tolerance** | how far a matrix result may be from the reference model and still pass |
| **score** | area x energy x time^2 for a test's region of interest; lower is better |
| **configuration** | one choice of hardware parameters (`VLEN`, `MAT_DIM`, `NUM_CORES`, ...) |
