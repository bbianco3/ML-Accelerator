# Competition rules and score

One file, [`competition.json`](../competition.json), holds the numbers every
team shares. Simulation, synthesis and scoring all read it (through
`tools/competition.py` and the top-level `Makefile`), so they cannot drift
apart. Teams do not edit it.

| Key | Value | Used by |
|---|---|---|
| `clk_period_ns` | 2.5 | synthesis: the clock constraint (`CLK_PERIOD`). Simulation: the real duration of one accelerator cycle, which sets how much the 2 GHz host gets done per cycle |
| `max_area_um2` | 200000 | `make limits` / `make score`: the synthesized cell area (logic + SRAM macros) must not exceed it |
| `link_delay_ns` | 5 | simulation: one-way latency between host CPU and accelerator ([host-model.md](host-model.md)) |
| `tolerance_rel`, `tolerance_abs` | 0.02, 0.02 | software: how far a matrix/tensor result may be from the reference ([numerics.md](numerics.md#tolerance-what-correct-means-for-matrix-and-tensor-results)) |

```sh
make help                 # prints the rules in force
make synth                # ends with the limits check
make limits               # the check alone: timing met? area under the limit?
make score TEST=lenet     # run the test, then score it
```

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
* **accelerator power** and **area** come from the synthesis reports of the
  *same hardware configuration* (`build/synth/<pdk>/<config>_<period>ns/`),
  so run `make synth` with the same parameters first.
* The host CPU's area is fixed and not counted.

A score is **valid** only if the test passed, synthesis met timing at
`clk_period_ns`, and the area is within `max_area_um2`. `make score` prints
`NOT VALID` and fails otherwise.

Time counts twice, so being faster is worth more than being small, but a
large design pays for its area and for the power it draws while it runs.
Work left on the host CPU costs host energy and usually time; work moved to
the accelerator costs area and accelerator power.

## Things to know

* The accelerator power is Design Compiler's estimate with default switching
  activity, not activity from the simulated workload. It mostly tracks how
  much logic you have and how much of it is clocked.
* `CLK_PERIOD=...` and `LINK_DELAY_NS=...` on the make command line still
  work for experiments, but a score is only valid at the values in
  `competition.json`.
* For reference, the template's default configuration (2 cores,
  `FP_PIPE=1`) synthesizes to 124,269 um^2 and 49.9 mW at 2.5 ns, 62 % of
  `max_area_um2`, and scores 65.2 on `lenet` (17.98 ms, 1.62 mJ). The small
  configuration in [synthesis.md](synthesis.md#reference-results) scores
  about 20 on the same test: it is slower but six times smaller.
