# Project guide: building your accelerator

For a team of 2-4 students in computer engineering who know digital logic,
some SystemVerilog and C, and the basics of a RISC-V pipeline, and who use
an AI coding assistant.

**The goal: design the accelerator that goes inside
[`hw/rtl/accel_top.sv`](../hw/rtl/accel_top.sv)** so that the tests in
`sw/tests/` pass, it synthesizes at the clock period and area target you
set for it in [`competition.json`](../competition.json), and it gets the
best (lowest) score: area x energy x time^2
([competition.md](competition.md)).

What you are given: the top-level ports, a simulated platform (2 GHz RISC-V
host, HBM memory, testbench), the software (driver, kernels, tests,
reference model), an SRAM generator, a synthesis flow, and the description
of a *reference design* in these documents: a small RISC-V control
core that runs kernels out of HBM, a bf16 vector unit, a matrix unit and a
scratchpad. You may build exactly that, or something else: another matrix
engine (a dot-product engine or a systolic array instead of its tiled
accumulator, see [matrix-engines.md](matrix-engines.md)), more or fewer
units, a different instruction set or memory format. New terms are in the
[glossary](glossary.md).

## What is fixed and what is yours

| Fixed (do not edit) | Yours |
|---|---|
| the ports of `accel_top` | everything inside `hw/rtl/` (add files to `filelist.f`) |
| `sim/` (testbench, host CPU and its time/energy model, HBM model) | the instruction set: `accel_pkg.sv` + `sw/common/accel_isa.h` + `docs/isa.md`, kept in sync |
| the `platform` section of `competition.json` (link delay, HBM latency, tolerance) and `sw/common/check.h` | the `design` and `synth` sections of `competition.json`: **your clock period, area target and synthesis settings** |
| | the kernels (`sw/tests/*/kernel.S`), the driver (`sw/common/accel.h`) and how work is split between host CPU and accelerator ([software-optimization.md](software-optimization.md)) |
| what each test checks: the results in `main.c`, within tolerance | the memory layout of matrices (`sw/common/mat_layout.h`) |
| `hw/sram/`, `hw/synth/` | the hardware parameters you use (`make help`) |

If you change the instruction set or a kernel, the test's `main.c` must
still check the same results. Never make a test pass by weakening its
check.

## Milestones

As distributed, every test fails with a timeout, because the empty shell
never answers the host. Work up this ladder; each step is a test that
starts passing.

| Step | Test(s) | What your design needs |
|---|---|---|
| 1 | `hello` | AXI4-Lite host registers: `ID`, `CFG0..3` ([memory-map.md](memory-map.md)) |
| 2 | `vadd` | launch/status registers, fetching a kernel from HBM over AXI4, the scalar instructions the kernel uses, `vsetvl`, vector load/store, `vfadd`, `ecall` |
| 3 | `scalar_ops`, `errors` | the full scalar subset, error reporting |
| 4 | `vector_ops` | every vector instruction, bit-exact against `bf16.h` |
| 5 | `matmul`, `gemm`, `layouts` | matrix multiply-accumulate (results within tolerance) |
| 6 | `spad`, `multicore`, `units`, `gemm_tiled` | scratchpad SRAM, several cores, barriers |
| 7 | `lenet`, then `make synth`, `make limits`, `make score TEST=lenet` | everything together, meeting the clock period and area target you chose |
| 8 | a better score | tune `competition.json` (clock period, area target, synthesis settings), the hardware parameters, the software and the design ([competition.md](competition.md#levers-roughly-by-effort)) |

`host` and `make unit` pass from the start: they test the platform and the
arithmetic functions in `accel_fp_pkg.sv`, not your design.

Tips:

* `make run TEST=<t> SIM_ARGS=+timeout=200000` fails fast while a test
  cannot pass yet.
* Use `accel_fp_pkg.sv` for bf16/fp32 arithmetic and `accel_sram_1rw` for
  memories ([sram.md](sram.md)).
* Run synthesis early (`make synth SYNTH_ELAB_ONLY=1` takes a minute and
  finds unsynthesizable code; a full run of a large design takes hours).

## Ground rules

1. **`make regress` is the definition of "works".** Run it in the default
   configuration *and* one other
   (`make regress VLEN=128 MAT_DIM=8 MXU_ROWS=8 SIM_ARGS=+hbm_stall_pct=25`),
   plus `make unit` if you touched arithmetic.
2. **Test first.** Before adding hardware, know which test will show that it
   works; write one in `sw/tests/` if none does.
3. **Don't modify the platform** (`sim/`, the `platform` section of
   `competition.json`, `check.h`). The `design` and `synth` sections are
   yours: do change them. If you change the numerics of an element-wise
   operation, change RTL and `bf16.h` together and say so.
4. **Measure everything**: time and energy from the region of interest,
   area, slack and power from `make synth`. "Faster" means a number.

### Working with an AI assistant

* Give it context: point it at `docs/` (especially `architecture.md`,
  `isa.md`, `memory-map.md` and this file), and tell it the ground rules
  above.
* Ask for small, reviewable pieces ("the AXI4-Lite register block for
  `hello`", "decode and execute for the scalar subset"), not "write the
  accelerator".
* Make it run the tests, and read the failures yourself. An AI will happily
  "fix" a failing test by changing the expected value. Never accept a change
  to a reference model, a tolerance or an expected result without
  understanding it.
* Use it to explain waveforms and logs, and to review your RTL for latches,
  missing resets and width mismatches (`make lint` helps too).

## Once it works: optimizations

The reference design is deliberately simple. These are the hardware
improvements it leaves open, each with a test that proves it works and a
number that proves it helps. File names refer to the reference design
([architecture.md](architecture.md)); use the corresponding part of your
design. Before any of them, look at the two cheapest levers: the software
([software-optimization.md](software-optimization.md)) and the settings
(clock period, area target, synthesis options:
[competition.md](competition.md)). The choice of matrix engine has its own
guide, [matrix-engines.md](matrix-engines.md).

| Project | Difficulty | Touches | Success metric |
|---|---|---|---|
| New vector instructions: `vfabs`, `vfneg`, `vfsgnj`, `vfrsub`, `vfdiv` by power of 2 | easy | `accel_vpu.sv`, `accel_core.sv`, `accel_isa.h`, `bf16.h` | new tests pass, regress passes |
| Strided vector load `vlse16` (column access) | easy-medium | core memory sequencing | new test, used in a kernel |
| **Burst merging**: when `stride == MAT_DIM*2` (blocked layout), load the whole tile in one AXI burst | medium | `accel_core.sv` (`S_MX_ROW`), transfer sizes | `layouts`: blocked tiles load several times faster |
| **Multiple outstanding reads** in `accel_axi_master.sv` (issue all row reads of an `mld` before the data returns) | medium | AXI master, core | `gemm` MACs/cycle up several times |
| Non-blocking `mmacc`: keep executing scalar/load instructions while the MXU computes, with a busy check on its registers | medium-hard | core FSM, scoreboard | `gemm` overlaps loads and compute |
| **Pipeline the floating-point paths further** than `FP_PIPE` does: split the fp32 adder into two stages, also in the accumulate loop ([synthesis.md](synthesis.md#timing-bottlenecks)) | medium-hard | VPU/MXU datapaths and FSMs | `make synth` meets a clearly shorter `CLK_PERIOD`, results unchanged, better score |
| Adder-tree reductions (faster `vfredsum`), with the new order in `bf16.h` | medium | VPU, numerics docs | reduction cycles vs `vl` |
| **im2col in hardware**: a gather instruction (or DMA mode) that builds patch rows, so convolutions stop being 75 % scalar copying (`lenet` prints the breakdown) | medium-hard | new instruction in `accel_core.sv` / `accel_spad.sv`, `lenet` kernel | `lenet` cycles/image drop, logits still bit-exact |
| **DMA engine**: copy HBM -> scratchpad in the background (one burst per tile) while the core computes, i.e. double buffering | medium-hard | new module next to `accel_spad`, a new instruction | `gemm_tiled` cycles drop |
| **Shared scratchpad**: one banked SRAM that all cores can read (A/B tiles loaded once for every core) | hard | `accel_spad`, `accel_top`, bank arbitration | HBM bytes per GEMM drop (`[hbm] stats`) |
| Better SRAM model: calibrate `sram_gen.py` against a paper or an OpenRAM/FakeRAM data point, add a dual-port macro | medium | `hw/sram/` | documented model, area/power deltas |

Suggested order inside the week: day 1 write the test and a short design
note (one paragraph and a timing sketch), days 2-4 implement and debug, day
5 run the regressions in several configurations and fix what breaks.

## Measuring and presenting

| Do | With |
|---|---|
| Regression in 3+ configurations, with back-pressure | `make regress ... SIM_ARGS=+hbm_stall_pct=25` |
| Area, worst slack, power, at more than one clock period and area target | `make synth CLK_PERIOD=...`, `make limits`, reports in `build/synth/asap7_TT_RVT/.../reports/` |
| Time, host energy, score | `make score TEST=lenet` (and your own workloads, with `roi_begin()`/`roi_end()`) |
| Report, diagram and design review | see [below](#report-diagram-and-design-review) |

## Report, diagram and design review

The score is not the only thing that counts. Every team hands in a short
report with an architecture diagram, and **is asked questions about its
design**: why it is built the way it is, how its parts work, and what the
alternatives would have been. Everyone on the team should be able to answer
for every part, including the parts an AI assistant wrote.

### The report

Short: about 2 to 4 pages plus the diagram. It should cover:

1. **Architecture overview.** What is inside `accel_top`: the blocks, what
   each one does, and how a kernel runs from launch to `DONE`.
2. **Design decisions.** The main choices you made, each with the
   alternative you considered and why you chose as you did: the matrix
   engine ([matrix-engines.md](matrix-engines.md)), the memory path,
   number of cores and units, scratchpad size, pipelining, any instruction
   set or memory format changes, what runs on the host CPU and what on the
   accelerator. [design-decisions.md](design-decisions.md) shows the style
   for the reference design.
3. **Settings.** Your clock period, area target and synthesis settings, and
   how you arrived at them (a sweep table is ideal).
4. **Results.** Time, energy, area, worst slack and score for `lenet` (and
   any other workload you measured), with a breakdown of where time and
   energy go.
5. **Verification.** Which configurations you ran, which tests you added,
   and what bugs you found.
6. **What you would do next**, and the biggest limitation of your design.

### The diagram

A block diagram of your accelerator, detailed enough that someone could
follow a single instruction or a single tile through it:

* every major block (control logic, vector unit, matrix engine, register
  files, scratchpad, instruction cache, memory path, host registers) with
  its name in your RTL,
* the datapaths between them, labelled with their **width in bits**,
* where the **pipeline registers** are (mark the stages),
* the **memories** with their size (and which use `accel_sram_1rw`),
* the two external interfaces (AXI4-Lite from the host CPU, AXI4 to HBM)
  and the interrupt,
* for the matrix engine, a second, zoomed-in drawing of how operands flow
  to the multipliers and where the sums are kept.

Any tool is fine (draw.io, Inkscape, TikZ, a clean hand drawing); ASCII
diagrams like the one in [architecture.md](architecture.md#block-diagram)
are acceptable if they are complete.

### Questions to be ready for

Expect questions like these, asked to any member of the team:

* Walk us through what happens, cycle by cycle, when your design executes
  `mmacc` (or `vle16`, or a branch).
* What is your critical path? Where does it start and end, and what would
  you change to shorten it?
* Why this matrix engine? What would a systolic array (or a tiled
  accumulator, or dot-product engines) have done better or worse here?
* How many multiply-accumulates per cycle can your design do at peak, and
  how many does it reach on `lenet`? Where does the difference go?
* Where does the energy go: host CPU or accelerator, logic or memory, busy
  or idle?
* Why this clock period and this area target? What happened to the score
  when you changed them?
* What happens when HBM stalls in the middle of a burst? When two cores
  access HBM at the same time?
* Which results are bit-exact and which are within tolerance in your
  design, and why?
* What did you move between the host CPU and the accelerator, and what did
  it change?
* Which part was hardest to get right, and how did you find the bug?

## Checklist for "done"

- [ ] `make regress` passes in the default configuration and two others
- [ ] `make unit` passes
- [ ] new features have tests in `sw/tests/` and are documented in `docs/`
- [ ] `make limits` passes and `make score TEST=lenet` is valid
- [ ] results table: time, energy, area, slack, score
- [ ] `make lint` shows no new warnings
- [ ] report and architecture diagram written; every team member can explain every block
