# Host CPU model: time, energy and the link to the accelerator

The host CPU is a **fixed** part of the platform: a 2 GHz RV64G core whose
area and clock you cannot change. What you can change is how much work it
does. Moving work from the CPU to the accelerator (or back) changes both run
time and energy, and this model is what makes that visible.

```
  host CPU (2 GHz, RV64G)  <---- link: LINK_DELAY_NS each way ---->  accelerator (CLK_PERIOD)
  time + energy from                registers (AXI4-Lite), irq       time from RTL simulation,
  sim/csrc/host_model.c                                              power from `make synth`
          |                                                                   |
          +------------------------- HBM (shared memory) ---------------------+
```

## Region of interest

Only the code between `roi_begin()` and `roi_end()` (`sw/common/runtime.h`)
is measured:

```c
prepare_inputs();            // free: not part of the workload
roi_begin();
uint32_t st = accel_run_cores(my_kernel, args, 1, cfg.num_cores);
roi_end();
check_against_reference();   // free
```

| | Outside the region | Inside the region |
|---|---|---|
| Host speed | `+host_ipc` instructions per accelerator clock (default 1), for fast simulation of setup and checking | real time: a 2 GHz core, each instruction costs cycles |
| Host energy | not counted | counted |
| Link delay | applies | applies |

Everything the host does inside the region counts, including waiting. A
program may open the region several times; the report adds them up.

At the end of the simulation the log contains (this is `make run TEST=host`):

```
[platform] ---- region of interest (1 region) ----
[platform]   time         : 256397.5 ns = 102559 accelerator cycles x 2500 ps
[platform]   host CPU     : 42370 instructions in 512794 cycles at 2.0 GHz (CPI 12.10), busy 100.0 % of the time
[platform]   host events  : 4353 L1D misses, 4097 L2 misses, 5 branch mispredicts, 20 device register accesses
[platform]   host energy  : 44480.5 nJ = 39352.6 active + 0.0 idle + 5127.9 leakage (average 173.5 mW)
ROI_STATS time_ns=256397.5 accel_cycles=102559 host_instr=42370 host_cycles=512794 host_energy_nj=44480.5
```

`ROI_STATS` is one machine-readable line for scripts.

## Time

The testbench has one clock, the accelerator's. Its period is `CLK_PERIOD`
(the same make variable `make synth` uses; its default is `clk_period_ns`
in `competition.json`, 2.5 ns), so an accelerator
that synthesizes at a shorter period also gets more done per nanosecond in
simulation: `make run TEST=lenet CLK_PERIOD=2.0`. (Waveform time still shows
one unit per cycle.) **Only use a `CLK_PERIOD` your design meets in
`make synth`.**

Inside the region, every accelerator clock gives the host `CLK_PERIOD` of
time, which it spends on instructions at 0.5 ns per core cycle:

| Instruction | Core cycles |
|---|---|
| integer ALU, branch, jump, store | 1 |
| load (L1 hit) | 2 |
| integer multiply / divide | 3 / 20 |
| FP add, compare, convert / multiply / fused multiply-add / divide, sqrt | 3 / 4 / 5 / 15 |
| CSR access / trap entry | 3 / 8 |
| + L1D miss (32 KiB, 8-way, 64-byte lines) | +12 |
| + L2 miss (512 KiB, 8-way), served by memory | +100 (50 ns) |
| + branch mispredict (4096-entry 2-bit predictor, 512-entry indirect-target buffer, returns always predicted) | +8 |

Host RAM and HBM cost the same from the host: both are memory behind the
caches. Instruction fetch is assumed to hit. `wfi` and waiting for an
accelerator register access take as long as they take; the core is idle
meanwhile.

## The link between host and accelerator

Host and accelerator are separate devices. Every access to an accelerator
register, and the interrupt line, crosses a link with a one-way latency of
`link_delay_ns` in `competition.json` (5 ns; make variable `LINK_DELAY_NS`,
plusarg `+link_delay_ns`). That is what an accelerator on the same chip as
its processor sees: a bus bridge and a clock-domain crossing between the
2 GHz core and the accelerator clock, about two accelerator cycles.

* a register write or read takes `2 x LINK_DELAY_NS` plus the AXI4-Lite
  handshake before the host continues,
* the host sees `irq` rise `LINK_DELAY_NS` after the accelerator raises it.

A register access therefore takes about 20 ns (2 x 5 ns plus 3-4 cycles of
handshake), i.e. some 40 host cycles: launching a kernel costs a few hundred
host cycles, and polling `STATUS` in a loop keeps the CPU busy where
`accel_wait_irq()` lets it sleep. Data does not cross the link: it goes
through HBM. Try `LINK_DELAY_NS=100` to see what an off-chip accelerator
would feel like.

## Energy

```
host energy = busy cycles x 50 pJ                    clock tree, pipeline, fetch
            + sum of per-instruction energies        10 pJ (ALU) ... 200 pJ (FP divide)
            + L1D misses x 200 pJ + L2 misses x 3 nJ + mispredicts x 100 pJ
            + idle cycles x 5 pJ                     in wfi or waiting for the accelerator
            + 20 mW x time                           leakage
```

A busy host therefore burns roughly 150-200 mW and an idle one about 30 mW.
The total for a run is

```
energy = host energy (from the log) + accelerator power (from `make synth`) x time
```

with the accelerator power taken from `build/synth/.../reports/power.rpt` of
the same configuration. `make score TEST=<t>` does this sum and computes the
competition score, see [competition.md](competition.md).

**How much to trust it.** The structure is the usual one (gem5 counts
events, McPAT turns counts into energy), but the constants in
`sim/csrc/host_model.h` are round order-of-magnitude numbers for a 7 nm-class
application core. They are *not* the output of a McPAT run, and the timing
model is a simple in-order one. Use the model to compare designs under the
same rules, not to predict a real chip. To recalibrate: run McPAT (or read a
core's datasheet) for the core you have in mind, divide each component's
dynamic power by its activity to get energy per event, and replace the
`HM_E_*` and `HM_P_LEAK_MW` constants; the code needs no other change.

## Files

| File | Role |
|---|---|
| `sim/csrc/rv64_iss.c` | functional RV64G simulator; reports what each instruction did |
| `sim/csrc/host_model.h`, `host_model.c` | all timing/energy constants, cache and branch-predictor model |
| `sim/csrc/platform.c` | region of interest, time budget per clock, the report |
| `sim/tb/host_bfm.sv` | link delay, AXI4-Lite master |
| `sw/tests/host` | self-test of the RV64G host and of the timed region |
