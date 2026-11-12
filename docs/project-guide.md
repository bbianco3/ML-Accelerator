# Project guide: a 3-week accelerator project

For a team of 2-4 sophomores in computer engineering who know digital
logic, some SystemVerilog and C, and the basics of a RISC-V pipeline, and
who use an AI coding assistant.

**The goal is not to build an accelerator from scratch.** The template
already contains a working, verified one. Your job is to (1) program it,
(2) make one part of it measurably better without breaking anything, and
(3) report what it cost in area and timing. That is achievable in 3 weeks,
and it's the same loop real accelerator teams run.

## Ground rules

1. **`make regress` is the definition of "works".** Run it before every
   commit, in the default configuration *and* one other
   (`make regress VLEN=128 MAT_DIM=8 MXU_ROWS=8 SIM_ARGS=+hbm_stall_pct=25`),
   plus `make unit` if you touched arithmetic.
2. **Test first.** Before changing hardware, write (or have the AI write) a
   test in `sw/tests/` that shows what should change: new results for new
   features, cycle counts for speed-ups.
3. **Don't modify the infrastructure** (`sim/csrc`, `sim/tb`, `bf16.h`)
   unless your project requires it. If you change the numerics, change RTL
   and `bf16.h` together and explain why in the PR.
4. **Measure everything**: kernel cycles from `accel_cycles()`, area and
   slack from `make synth`. "Faster" means a number.

### Working with an AI assistant

* Give it context: point it at `docs/` (especially `architecture.md`,
  `isa.md` and this file) and the module you are changing.
* Ask for small, reviewable diffs ("add a `vfabs` instruction: decode in
  `accel_core.sv`, lane logic in `accel_vpu.sv`, macro in `accel_isa.h`,
  test in `sw/tests/vector_ops`"), not "make it faster".
* Make it run the tests, and read the failures yourself. An AI will happily
  "fix" a failing test by changing the expected value. Never accept a change
  to a reference model or expected result without understanding it.
* Use it to explain waveforms and logs, and to review your own RTL for
  latches, missing resets and width mismatches (`make lint` helps too).

## Week 1: run it, read it, program it (software only)

| Day | Do | Done when |
|---|---|---|
| 1 | Set up (README quick start), `make regress`, read `architecture.md` and `isa.md` | all tests pass on your account |
| 2 | Walk through `vadd` with `+accel_trace` and in Verdi (`WAVES=1`): find the FETCH/EXEC states and the AXI bursts. Then `multicore`: watch two cores meet at a `barrier` | you can explain every cycle of one loop iteration |
| 3-4 | Write two kernels of your own, with tests (ideas below) | they pass in 2 configurations |
| 5 | Record **baseline numbers**: cycles for `gemm`, your kernels, and `make synth` area/slack (the default config takes ~2 h in ASAP7, so start it in the morning; see [synthesis.md](synthesis.md#reference-results)) | a table in your team notes |

Kernel ideas, easiest first: `axpy` (`y = a*x + y`), ReLU / leaky ReLU,
vector max/argmax, mean and variance of a vector (layer-norm statistics),
matrix-vector product, GEMM + bias + ReLU with a blocked layout, a 2-layer
MLP forward pass. Then make one of them use **all cores** and the
**scratchpad** (start from `sw/tests/gemm_tiled`), and measure the speed-up.
`sw/tests/lenet` shows a complete network (pretrained LeNet-5); speeding up
its im2col in software (word copies, reusing overlapping windows) is a good
software-only exercise.

## Week 2: one hardware improvement

Pick **one** item (or one per pair of students). Each has a test that proves
it works and a number that proves it helps.

| Project | Difficulty | Touches | Success metric |
|---|---|---|---|
| New vector instructions: `vfabs`, `vfneg`, `vfsgnj`, `vfrsub`, `vfdiv` by power of 2 | easy | `accel_vpu.sv`, `accel_core.sv`, `accel_isa.h`, `bf16.h` | new tests pass, regress passes |
| Strided vector load `vlse16` (column access) | easy-medium | core memory sequencing | new test, used in a kernel |
| **Burst merging**: when `stride == MAT_DIM*2` (blocked layout), load the whole tile in one AXI burst | medium | `accel_core.sv` (`S_MX_ROW`), transfer sizes | `layouts`: blocked tiles load several times faster |
| **Multiple outstanding reads** in `accel_axi_master.sv` (issue all row reads of an `mld` before the data returns) | medium | AXI master, core | `gemm` MACs/cycle up several times |
| Non-blocking `mmacc`: keep executing scalar/load instructions while the MXU computes, with a busy check on its registers | medium-hard | core FSM, scoreboard | `gemm` overlaps loads and compute |
| **Pipeline the FP lanes** (2-3 register stages in `accel_vpu`/`accel_mxu`) to reach 1 GHz in ASAP7 | medium-hard | VPU/MXU datapaths and FSMs | `make synth CLK_PERIOD=1.0` meets timing, regress still bit-exact |
| Adder-tree reductions (faster `vfredsum`), with the new order in `bf16.h` | medium | VPU, numerics docs | reduction cycles vs `vl` |
| **im2col in hardware**: a gather instruction (or DMA mode) that builds patch rows, so convolutions stop being 75 % scalar copying (`lenet` prints the breakdown) | medium-hard | new instruction in `accel_core.sv` / `accel_spad.sv`, `lenet` kernel | `lenet` cycles/image drop, logits still bit-exact |
| **DMA engine**: copy HBM -> scratchpad in the background (one burst per tile) while the core computes, i.e. double buffering | medium-hard | new module next to `accel_spad`, a new instruction | `gemm_tiled` cycles drop |
| **Shared scratchpad**: one banked SRAM that all cores can read (A/B tiles loaded once for every core) | hard | `accel_spad`, `accel_top`, bank arbitration | HBM bytes per GEMM drop (`[hbm] stats`) |
| Better SRAM model: calibrate `sram_gen.py` against a paper or an OpenRAM/FakeRAM data point, add a dual-port macro | medium | `hw/sram/` | documented model, area/power deltas |

Suggested order inside the week: day 1 write the test and a short design
note (one paragraph and a timing sketch), days 2-4 implement and debug, day
5 run the regressions in several configurations and fix what breaks.

## Week 3: integrate, measure, present

| Day | Do |
|---|---|
| 1-2 | Merge the team's work, run `make regress` in 3+ configurations with back-pressure |
| 3 | `make synth` before/after (ASAP7, same `CLK_PERIOD`, corner and Vt): area (logic and SRAM macros), worst slack, power from `build/synth/asap7_TT_RVT/.../reports/` |
| 4 | Re-run your kernels: speed-up vs. baseline, MACs/cycle, HBM bytes/cycle (from the `[hbm] stats` line) |
| 5 | Presentation / write-up: what you changed, how you verified it, performance gained, area paid, what you'd do next |

## Checklist for "done"

- [ ] `make regress` passes in the default configuration and two others
- [ ] `make unit` passes
- [ ] new features have tests in `sw/tests/` and are documented in `docs/`
- [ ] before/after table: cycles, area, slack
- [ ] `make lint` shows no new warnings
