# Synthesis (Design Compiler, ASAP7)

```sh
source setup_env.sh
make synth                                     # ASAP7, default configuration, settings from competition.json
make limits                                    # did it meet its clock period and area target?
make synth CLK_PERIOD=2.0 VLEN=128 MXU_ROWS=2  # any clock period / parameters
make synth MAX_AREA_UM2=0 SYNTH_RETIME=1 SYNTH_TAG=small   # other settings, in their own result directory
make synth NUM_CORES=1 SPAD_KB=0               # one core, no scratchpad
make synth SRAM=flops                          # scratchpads from flip-flops instead of SRAM macros
make synth SYNTH_ELAB_ONLY=1                   # analyze + elaborate + check_design only
make synth PDK=freepdk45 CLK_PERIOD=10         # the old 45 nm flow, still supported (no SRAM macros)
```

## The ASAP7 PDK

[ASAP7](https://asap.asu.edu/) is a **predictive 7 nm FinFET PDK** from
Arizona State University and ARM (BSD-3-Clause). It is not a real foundry
process, but its cells, delays and areas are realistic for a modern node,
which makes it the standard choice for academic synthesis and
place-and-route (it's the default platform of OpenROAD).

The template uses the 7.5-track standard-cell library `asap7sc7p5t`
(revision 28): five Liberty files (`AO`, `OA`, `SIMPLE`, `INVBUF`, `SEQ`)
at one corner and one threshold voltage.

| Knob | Default | Choices |
|---|---|---|
| `ASAP7_CORNER` | `TT` (typical, 0.7 V, 25 C) | `TT`, `FF`, `SS` |
| `ASAP7_VT` | `RVT` (regular Vt) | `RVT`, `LVT` (faster, leakier), `SLVT` (fastest, leakiest) |
| `ASAP7_DIR` | `<repo>/pdk/asap7` | any writable directory (share one between checkouts) |

### One-time setup (automatic)

The first `make synth` runs `make asap7`, which calls
[`hw/synth/pdk/asap7_setup.sh`](../hw/synth/pdk/asap7_setup.sh). It:

1. downloads the NLDM `.lib` files that OpenROAD-flow-scripts redistributes,
   pinned to one commit so everyone gets identical libraries,
2. compiles them to Synopsys `.db` with Library Compiler (`lc_shell`,
   ~20 s), into `pdk/asap7/db/<CORNER>_<VT>/`.

`pdk/` is git-ignored; nothing from the PDK is committed. Running it again
does nothing if the `.db` files exist. Each new corner/Vt combination is
downloaded and compiled on first use.

The first `make synth` also runs `make sram`, which generates the SRAM
macro catalog for the scratchpads with `hw/sram/sram_gen.py` and compiles it
into `pdk/asap7/sram/db/<CORNER>/` (a few seconds). See [sram.md](sram.md).

> **EWS quirk.** The 2024 `lc_shell` bundles old copies of `libk5crypto` and
> `libtinfo` that clash with RHEL 9's (`symbol lookup error ...
> krb5int_c_deprecated_enctype` or `... _nc_tiparm`). The setup script
> preloads the system copies for `lc_shell` only. If your machine does not
> need that, run with `LC_PRELOAD=""`.

### ASAP7 specifics the flow handles for you

* **Time unit is picoseconds** (FreePDK45 uses ns). `CLK_PERIOD` is always
  given in **ns**. The script multiplies by the library's time scale, so
  the default `CLK_PERIOD=2.5` becomes a 2500 ps clock. Reports are in **ps**.
* **Cell names** end in `_ASAP7_75t_R` (RVT), `_L` or `_SL`.
* **Don't-use cells**, the same list OpenROAD uses: fractional-drive
  cells (`*x1p*`, `*xp*`), scan flops (`SDF*`) and integrated clock gates
  (`ICG*`; these are allowed when the `clock_gating` setting is on).
* **Flip-flops** have no reset pin, so the synchronous `rst_n` becomes a
  gate in front of D. That is normal and is why reset shows up in the logic
  area.
* Inputs are driven by `BUFx2_ASAP7_75t_R`, and outputs see a 3.9 fF load.
* Areas are physical as-drawn um^2 (a DFF is 0.29 um^2, versus 4.5 um^2 in
  FreePDK45).

## What the script does

[`hw/synth/synthesis.tcl`](../hw/synth/synthesis.tcl), driven by
[`hw/synth/synth.mk`](../hw/synth/synth.mk):

1. sources the PDK configuration `hw/synth/pdk/$PDK.tcl` (`asap7.tcl` or
   `freepdk45.tcl`), which supplies the libraries, time unit, load, driving
   cell and don't-use list. Adding another PDK means writing one more such
   file,
2. reads the same `hw/rtl/filelist.f` as simulation with `SYNTHESIS`
   defined (so `$display`, traces and parameter checks drop out) and, with
   `SRAM=macro` (default for ASAP7), `ACCEL_SRAM_MACROS`, so each
   scratchpad becomes SRAM macro instances. The macro libraries are added
   to `link_library` only, so DC never uses them for anything else,
3. elaborates `accel_top` with the requested parameters and renames it back
   to `accel_top`,
4. constrains: clock `clk` with period `CLK_PERIOD`, 2 % setup uncertainty,
   input/output delays of 20 % of the period, an ideal reset network, the
   area target `MAX_AREA_UM2`, and the buffering rules if they are switched
   on. The clock is ideal (no clock tree yet), so hold is reported but not
   fixed. Hold fixing belongs after clock-tree synthesis in place and route,
5. runs `compile_ultra -no_autoungroup` (plus DesignWare for the
   arithmetic), with `-retime` and `-gate_clock` if those settings are on,
6. writes reports, a netlist, a `.ddc` and the `.sdc`,
7. if timing is still violated and `extra_passes` allows, runs
   `compile_ultra -incremental` and writes the results again, until timing
   is met, the passes are used up or the time limit is reached.

## Synthesis settings

The `design` and `synth` sections of
[`competition.json`](../competition.json) are yours to tune
([competition.md](competition.md)). Each has a make variable for one-off
experiments, and `SYNTH_TAG=<name>` keeps an experiment's results apart
from the others.

| Setting (`competition.json`) | Make variable | What it does | Cost / when to use |
|---|---|---|---|
| `design.clk_period_ns` | `CLK_PERIOD` | the clock constraint; also the cycle time in simulation | shorter: faster design, but larger cells, more power, longer compile, may not close |
| `design.max_area_um2` | `MAX_AREA_UM2` | area target (`set_max_area`). After timing is met DC recovers area until it is below the target; 0 = as far as it can | tighter: smaller design, longer compile. Checked by `make limits` (0 = no check) |
| `synth.extra_passes` | `SYNTH_EXTRA_PASSES` | up to N more `compile_ultra -incremental` runs while timing is violated | each pass can take as long as a good part of the first compile; useful when the first compile ends a few percent short |
| `synth.time_limit_min` | `SYNTH_TIME_LIMIT_MIN` | time budget, see below | |
| `synth.retime` | `SYNTH_RETIME` | DC may move registers across logic (`-retime`) to balance pipeline stages | helps designs with uneven stages, e.g. a register stage you added in a convenient but not ideal place. Register names in reports no longer match the RTL one to one |
| `synth.clock_gating` | `SYNTH_CLOCK_GATING` | registers that only load on an enable get a clock gate instead of a feedback multiplexer (`-gate_clock`) | lowers power, which counts in the score through energy; `reports/clock_gating.rpt` shows how many registers were gated |
| `synth.max_fanout` | `SYNTH_MAX_FANOUT` | nets with more loads than this get a buffer tree (`set_max_fanout`) | DC already buffers for timing; this also bounds fan-out on non-critical nets, which costs some area and makes the netlist closer to what place and route will build. Try 16 to 32 |
| `synth.buffer_ports` | `SYNTH_BUFFER_PORTS` | buffers feedthroughs and outputs that share a net (`set_fix_multiple_port_nets`) | cleaner netlist for a later place-and-route flow, slightly more area |

**Measured on the reference design** (small configuration of
[Reference results](#reference-results), `FP_PIPE=1`, 2.5 ns, `lenet`):

| Settings | Area (um^2) | Power (mW) | Worst slack | Compile time | `lenet` score |
|---|---|---|---|---|---|
| defaults (all off) | 19,277 | 6.03 | +0.04 ps | 25 min | 20.1 |
| `retime`, `clock_gating`, `max_fanout` 32, `buffer_ports` | 17,899 | 2.04 | +0.20 ps | 25 min | 17.1 |

Clock gating does most of this: 89 % of the registers got a clock gate
(446 gates), which removes their feedback multiplexers (area) and stops
their clock pins toggling when they hold (power). The four settings were
switched on together in this run, so the table does not say how much each
one contributes; that is an experiment for you. The gates are the
library's integrated clock-gating cells, which contain a latch by design;
that is not an inferred latch in your RTL.

**Time limit.** A large design can take many hours, and Design Compiler
has no way to say "stop optimizing now and keep what you have" in the
middle of a compile. `time_limit_min` therefore works in two steps:

* **Soft:** once the limit has passed, no further optimization pass is
  started. The results of the last finished pass are already on disk,
  because reports and the netlist are written after every pass.
* **Hard:** 20 minutes after the limit, `dc_shell` is stopped. If the
  *first* compile has not finished by then there are no results: raise the
  limit, loosen the clock period, or synthesize a smaller configuration
  first.

So a sensible budget is "the first compile, plus as many extra passes as
fit": e.g. `"time_limit_min": 240, "extra_passes": 3`. On a machine that
restarts every night, set the limit so that the run ends before the
restart.

**Things that are not settings but work the same way:**

* `ASAP7_VT=LVT` or `SLVT`: faster, leakier cells.
* `ASAP7_CORNER=FF` / `SS`: the fast and slow process corners.
* `SRAM=flops`: scratchpads from flip-flops, to see what the SRAM macros
  save.
* The hardware parameters (`VLEN`, `MAT_DIM`, `MXU_ROWS`, `NUM_CORES`,
  `FP_PIPE`, ...): they change the design itself
  ([parameters.md](parameters.md)).

The alib (DC's library analysis cache) for ASAP7 is built once into
`pdk/asap7/alib/` and reused by every later run.

## Outputs

`build/synth/<pdk>/<configuration>[_flops]_<period>ns[_<SYNTH_TAG>]/`, e.g.
`build/synth/asap7_TT_RVT/v256_m16_t4_a2_r4_d256_i16_c2_s16_2.5ns/`:

| File | Contents |
|---|---|
| `synth.log` | full DC log. Search for `Error`, `Warning`, `Latch` |
| `reports/settings.rpt` | the clock period, area target and synthesis settings this run was given (read by `make limits` and `make score`) |
| `reports/check_design.rpt` | structural problems after elaboration (should say "No issues found") |
| `reports/qor.rpt` | summary: area (SRAM macros under *Macro/Black Box Area*), cell counts, critical path, worst negative slack (WNS), total negative slack |
| `reports/area.rpt` | area per module (`-hierarchy`); each core is `g_core_<i>_...`, its scratchpad `.../u_spad` |
| `reports/sram.rpt` | every SRAM macro instance with its area (says "No SRAM macros" with `SRAM=flops`) |
| `reports/timing.rpt` | the 10 worst paths (ps for ASAP7) |
| `reports/violators.rpt` | constraint violations. Expected entries: hold (not fixed pre-CTS) and `max_leakage_power` with *Required 0.00*, which is DC's default "minimize leakage" goal and not a real constraint. The *Actual* column is the leakage in the library unit (pW for ASAP7). |
| `reports/power.rpt` | estimated power per module (default switching activity), SRAM read/write energy and leakage included |
| `reports/reference.rpt` | cell usage per module |
| `reports/clock_gating.rpt` | with `clock_gating`: number of clock gates and of gated registers |
| `accel_top.v`, `accel_top.ddc`, `accel_top.sdc` | netlist, DC database, constraints (inputs to OpenROAD / ICC2) |

## Reading the results

* **Slack**: `slack (MET)` or `slack (VIOLATED)`. With ASAP7 the numbers are
  in ps: a slack of -150 means the design needs `CLK_PERIOD + 0.15` ns.
  `reports/timing.rpt` names the start and end register of the worst
  paths; [Timing bottlenecks](#timing-bottlenecks) shows where they are in
  the reference design.
* **Area**: per core, dominated by storage (flip-flops for vector registers,
  tiles, accumulators), the `VLEN/16 + MXU_ROWS*MAT_DIM` FP lanes and the
  scratchpad macros. Everything scales with `NUM_CORES`. Use `area.rpt` to
  see which module.
* **SRAM timing**: macro access time is 150-260 ps, so paths from a
  scratchpad (`rd_out` -> byte shifter -> core) are far from critical at
  2.5 ns.
* **Latches**: `hdlin_check_no_latch` makes DC warn on inferred latches;
  there should be none.

## Reference results

ASAP7 RVT TT, DC W-2024.09, 2.5 ns clock, 2 cores, scratchpads in SRAM
macros. All four runs meet timing.

| Configuration | `FP_PIPE` | Area (um^2) | of which SRAM | Power (mW) | Worst slack | Compile time |
|---|---|---|---|---|---|---|
| small (`VLEN=64 MAT_DIM=4 MXU_ROWS=4 NUM_TREGS=2 NUM_ACCS=1 HBM_DATA_W=64 ICACHE_LINES=4 SPAD_KB=4`) | 0 | 19,010 | 2,478 | 5.39 | +0.01 ps | 29 min |
| small, same | 1 | 19,277 | 2,478 | 6.03 | +0.04 ps | 25 min |
| **default** (`VLEN=256 MAT_DIM=16 MXU_ROWS=4 NUM_TREGS=4 NUM_ACCS=2 HBM_DATA_W=256 ICACHE_LINES=16 SPAD_KB=16`) | 1 | 124,269 | 9,003 | 49.9 | 0.00 ps | 4 h |

Where the default configuration's area goes, per core (two cores): matrix
unit 41,009 um^2 (33 % of the chip each), vector unit 11,580 (9 %),
scratchpad 4,914 (4 %), I-cache 2,562 (2 %). The AXI arbiter, host
registers and AXI masters together are under 1 %.

The default configuration without pipelining (`FP_PIPE=0`) has not been
measured: its run was still 182 ps short of 2.5 ns after three hours when
the machine rebooted.

### Timing bottlenecks

A run that meets its clock only shows which path was hardest, not how long
it really is, because DC stops optimizing at zero slack. The critical path
of each run above:

| Run | Critical path |
|---|---|
| small, `FP_PIPE=0` | matrix unit: step counter -> tile select -> bf16 multiply -> fp32 add -> accumulator |
| small, `FP_PIPE=1` | vector unit, reduction: element index -> element select -> fp32 add -> round -> register write |
| default, `FP_PIPE=1` | matrix unit: registered row index -> accumulator row select -> fp32 add -> accumulator (94 logic levels, 2.43 ns) |

For real delays, an earlier run pushed the small configuration (single
core, no pipelining) to a 1.0 ns target, which it missed everywhere that
matters:

| Path | Delay (ps) | Contents |
|---|---|---|
| matrix unit accumulate | 1,741 | tile select, bf16 multiply, fp32 add |
| vector unit element-wise | 1,731 | multiply, fp32 add, round to bf16 |
| control core: next PC | 1,625 | decode, register read, branch compare |
| control core: memory address | 1,620 | decode, register read, add |
| control core: register write | 1,605 | decode, register read, ALU |
| vector reduction accumulator | 1,529 | element select, fp32 add |
| cycle / instruction counters | ~1,315 | 64-bit increment |
| everything else | < 1,070 | I-cache, AXI, host registers |

What limits the clock, in order:

1. **The fp32 adder** (`fp32_add` in `accel_fp_pkg.sv`): about 1.5 ns as one
   chain of magnitude compare, swap, alignment shift, add, leading-zero
   count, normalize shift, round. `FP_PIPE=1` only takes the multiplier
   (about 0.2 ns) out of its paths. It sits in two feedback loops, the
   matrix unit's accumulate and the vector reduction.
2. **The accumulator row select in front of it**, which grows with
   `MAT_DIM` and `NUM_ACCS`. At the default size it is on the critical path.
3. **The control core** at about 1.6 ns: it decodes, reads registers and
   computes in one cycle.

Ways to go faster (these are the natural timing projects):

* Split the accumulate adder into two stages (align | add, normalize,
  round). Each accumulator row is updated only once every
  `MAT_DIM / MXU_ROWS` cycles, so a two-cycle adder keeps the throughput
  and the results; only `MXU_ROWS = MAT_DIM` needs an idle cycle per step.
* Read the accumulator row one cycle early into a register, so the row
  select leaves the adder's cycle.
* Use the two-stage adder in the vector unit (one more cycle per
  element-wise operation, two cycles per reduction element), or change the
  reduction to an adder tree, which changes the summation order and so the
  numerics contract.
* Register the control core's operands (one more cycle per scalar
  instruction; `lenet` spends about 75 % of its time in scalar loops).

Same small configuration with flip-flop scratchpads: see
[sram.md](sram.md#synthesis-results).

Earlier single-core design without scratchpads (the numbers for one core
are still representative):

| Configuration | Clock | Area (um^2) | WNS | Compile time |
|---|---|---|---|---|
| `VLEN=64 MAT_DIM=4 MXU_ROWS=4 NUM_TREGS=2 NUM_ACCS=1 HBM_DATA_W=64 ICACHE_LINES=4` | 1.0 ns | 9,441 (MXU 51 %, VPU 31 %) | **-778 ps** (critical path 1.74 ns) | 57 min |
| same | 2.5 ns | 8,229 (MXU 47 %, VPU 32 %), leakage 9.5 uW | +0.01 ps (met, path 2.44 ns) | 16 min |
| default (`VLEN=256 MAT_DIM=16 MXU_ROWS=4 ...`) | 2.5 ns | 56,881 (MXU 72 %, VPU 20 %, I-cache 4.5 %), 23.7 mW, leakage 59 uW | 0.00 ps (met, path 2.44 ns) | 110 min |

**Why the default clock period is 2.5 ns.** It is simply a period the
reference design meets without effort: its floating-point paths need about
1.5 to 1.75 ns when pushed, and an impossible target makes DC slow (the
1 ns run above spent most of its 57 minutes trying). It is a starting
point, not a recommendation. Your design has its own best clock period:
sweep it, and shorten the paths that limit it
([competition.md](competition.md#design-your-clock-and-your-area)).

Iterate on timing with a small configuration (same lane design, much faster
compiles), then confirm with the full one once, e.g. overnight or with
`nohup make synth > synth.out 2>&1 &`. Compile time grows with
`NUM_CORES`: DC optimizes every core instance.

FreePDK45 for comparison (same small configuration, 10 ns): 81,419 um^2,
slack met.

## Tips

* **Sweep the clock period** (e.g. 3.0, 2.5, 2.2, 2.0, 1.8) and score each
  result: the best score is usually not at the shortest period that meets
  timing, because area and power rise steeply near the limit. Keep targets
  reachable: a clock far below the critical path makes DC run for hours.
* **Then sweep the area target** at the period you chose.
* `ASAP7_VT=LVT` or `SLVT` trades leakage for speed. It's a quick way to see
  how much of a timing problem is the library rather than the design.
* Pipelining the floating-point paths is the standard way to shorten the
  critical path (`FP_PIPE` in the reference design). Results must not
  change, so `make regress` still passes. `synth.retime` can then even out
  the stages.
* Change one thing at a time, and give each experiment a `SYNTH_TAG`.
  State the clock period, corner, Vt and settings with every number.
* SRAM macros: see [sram.md](sram.md). Compare `SRAM=macro` with
  `SRAM=flops` to see what the macros save.
