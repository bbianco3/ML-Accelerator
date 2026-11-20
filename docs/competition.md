# Settings, limits and score

One file, [`competition.json`](../competition.json), holds the numbers that
simulation, synthesis and scoring share, so they cannot drift apart. It has
three sections:

| Section | Whose | What |
|---|---|---|
| `design` | **yours: tune it** | the clock period and the area target of your accelerator |
| `synth` | **yours: tune it** | how hard and how long Design Compiler works |
| `platform` | fixed for everyone | host link delay, HBM latency, result tolerance |

```sh
make help                 # prints the settings in force
make synth                # synthesize with them; ends with the limits check
make limits               # the check alone: timing met? area within the target?
make score TEST=lenet     # run the test, then score it
```

Every setting can also be given on the command line for one experiment
(`make synth CLK_PERIOD=2.0 SYNTH_RETIME=1 SYNTH_TAG=try1`); put the values
you settle on in the file.

## `design`: your clock and your area

| Key | Default | Make variable | Used by |
|---|---|---|---|
| `clk_period_ns` | 2.5 | `CLK_PERIOD` | **synthesis:** the clock constraint. **simulation:** the real duration of one accelerator cycle |
| `max_area_um2` | 200000 | `MAX_AREA_UM2` | **synthesis:** the area target (`set_max_area`): once timing is met, Design Compiler shrinks the design until it is below this; 0 means "as small as you can". **`make limits`:** the result must not exceed it |

**These two are the most important numbers you choose. Change them.** The
defaults are a starting point that the reference design happens to meet,
not a recommendation.

* **Clock period.** The platform's delays are in nanoseconds: the host CPU
  runs at 2 GHz, the link takes 5 ns, HBM answers after 100 ns. A shorter
  accelerator clock makes your logic faster against all of them, and time
  counts squared in the score. The price: synthesis needs more and larger
  cells to meet it (area, power), may not meet it at all, and delays that
  are fixed in nanoseconds take more of your cycles (at 1.25 ns an HBM read
  is 80 cycles instead of 40). There is an optimum, and it depends on your
  design. Find it:

  ```sh
  for p in 3.0 2.5 2.0 1.6; do make synth CLK_PERIOD=$p; done      # hours each for a large design
  for p in 3.0 2.5 2.0 1.6; do make score TEST=lenet CLK_PERIOD=$p; done
  ```

  When synthesis misses the period, `reports/timing.rpt` shows the path
  that failed. Pipelining that path is usually worth more than relaxing
  the clock ([synthesis.md](synthesis.md#timing-bottlenecks)).
* **Area target.** With a loose target Design Compiler stops shrinking
  early; with a tight one it trades slack for area on every path that has
  slack to spare. Area is a factor of the score, so try a target somewhat
  below what you got last time, and 0.

## `synth`: how Design Compiler works

| Key | Default | Make variable | Effect |
|---|---|---|---|
| `time_limit_min` | 0 (none) | `SYNTH_TIME_LIMIT_MIN` | budget for the run in minutes, see below |
| `extra_passes` | 0 | `SYNTH_EXTRA_PASSES` | up to this many incremental compiles after the first, as long as timing is still violated |
| `retime` | false | `SYNTH_RETIME` | let DC move registers across logic to balance pipeline stages |
| `clock_gating` | false | `SYNTH_CLOCK_GATING` | insert clock gates on registers with an enable, which lowers power |
| `max_fanout` | 0 (off) | `SYNTH_MAX_FANOUT` | build buffer trees on nets with more loads than this |
| `buffer_ports` | false | `SYNTH_BUFFER_PORTS` | buffer feedthroughs and ports that share a net |

What each one is for, and what it costs, is in
[synthesis.md](synthesis.md#synthesis-settings). `SYNTH_TAG=<name>` on the
command line gives a run its own result directory, so you can compare
settings side by side.

## `platform`: the same for everyone

| Key | Value | Meaning |
|---|---|---|
| `link_delay_ns` | 5 | one-way latency between host CPU and accelerator ([host-model.md](host-model.md)) |
| `hbm_rd_latency_ns`, `hbm_wr_latency_ns` | 100, 50 | HBM latency: read request to first data, last write data to response ([simulation.md](simulation.md#hbm-model)) |
| `tolerance_rel`, `tolerance_abs` | 0.02, 0.02 | how far a matrix result may be from the reference model ([numerics.md](numerics.md#tolerance-what-correct-means-for-matrix-and-tensor-results)) |

Do not edit this section, the host CPU model (`sim/csrc/host_model.h`) or
the checks in the tests to improve a result. Changing them for an
experiment ("what if HBM were twice as fast?") is fine, as long as you
report scores with the values above.

## Score

For the region of interest of a test (`roi_begin()` ... `roi_end()`):

```
score = area x energy x time^2          lower is better

time   = duration of the region                                   [ms]
energy = host CPU energy + accelerator power x time               [mJ]
area   = accelerator cell area from synthesis                     [mm^2]
```

* **time** and **host energy** come from the simulation
  ([host-model.md](host-model.md)).
* **accelerator power** and **area** come from the synthesis reports of
  the *same configuration, clock period and `SYNTH_TAG`*
  (`build/synth/<pdk>/<configuration>_<period>ns[_<tag>]/`), so run
  `make synth` with the same settings first.
* The host CPU's area is fixed and not counted.

A score is **valid** when

1. the test passed,
2. synthesis met timing at its clock period,
3. the simulation used that same clock period, and
4. the area is within the run's area target.

`make score` prints `NOT VALID` with the reason and fails otherwise.

Time counts twice, so being faster is worth more than being small, but a
large design pays for its area and for the power it draws while it runs.
Work left on the host CPU costs host energy and usually time; work moved to
the accelerator costs area and accelerator power.

## Levers, roughly by effort

| Lever | Where | Guide |
|---|---|---|
| wait for the interrupt instead of polling; stage reused data in the scratchpad; vector copies | software | [software-optimization.md](software-optimization.md) |
| hardware parameters: vector length, tile size, cores, units, scratchpad size, pipeline depth | `make ... VLEN= MAT_DIM= NUM_CORES= ...` | [parameters.md](parameters.md) |
| clock period, area target, synthesis settings | `competition.json` | this page, [synthesis.md](synthesis.md) |
| memory path: bursts, outstanding requests, DMA | RTL | [project-guide.md](project-guide.md#once-it-works-optimizations) |
| the matrix engine: tiled accumulator, dot-product engines, systolic array | RTL | [matrix-engines.md](matrix-engines.md) |
| the instruction set and the split between host and accelerator | RTL + software | [isa.md](isa.md), [software-optimization.md](software-optimization.md#when-software-is-not-enough) |

## Things to know

* The accelerator power is Design Compiler's estimate with default
  switching activity, not activity from the simulated workload. It mostly
  tracks how much logic you have and how much of it is clocked, which is
  why clock gating shows up in it.
* Area and timing are synthesis estimates with wire-load models. There is
  no placement or routing.
* For reference, the reference design's default configuration (2 cores,
  `FP_PIPE=1`) synthesizes to 124,269 um^2 and 49.9 mW at 2.5 ns and
  scores 65.2 on `lenet` (17.98 ms, 1.62 mJ). Its small configuration in
  [synthesis.md](synthesis.md#reference-results) scores about 20 on the
  same test: slower, but six times smaller. Neither was tuned.
