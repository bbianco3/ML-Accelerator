# Making the software faster: kernels, driver, host program

The kernels in `sw/tests/` and the driver in `sw/common/accel.h` are written
to be read, not to be fast. They are yours to improve: software changes need
no synthesis run, cost no area, and several of them are worth more than a
hardware change. This page lists where to look, with numbers from the
reference design where they have been measured.

The one rule: a test must still check the same results
([project-guide.md](project-guide.md#what-is-fixed-and-what-is-yours)). You
may rewrite a kernel, split work differently between host and accelerator,
change data layouts and the driver; you may not weaken what `main.c`
verifies.

## Measure before you change anything

| Question | How to answer it |
|---|---|
| How long does the workload take, and what does the host cost? | `roi_begin()` / `roi_end()` around it; the log ends with time, host instructions and host energy ([host-model.md](host-model.md)) |
| What is the score? | `make score TEST=<test>` ([competition.md](competition.md)) |
| How many accelerator cycles and instructions? | `accel_cycles()`, `accel_instret()` on the host; `csrr t0, cycle` in a kernel |
| Which part of a kernel is slow? | read `cycle` before and after each phase and store the differences (the `lenet` kernel does this with its `STAT` macro and prints a breakdown) |
| How much memory traffic? | the `[hbm] stats` line at the end of the log: transactions, beats, bytes |
| What exactly did the accelerator execute? | `SIM_ARGS=+accel_trace`, with `build/sw/<test>/kernel.dis` |

What the reference design shows, as a starting point:

* `lenet`: about 75 % of the time is im2col done with scalar loads and
  stores, about 14 % bias/ReLU/pooling, and only about 4 % is the matrix
  unit.
* `gemm`: about 2 multiply-accumulates per cycle against a peak of 64 per
  core, because every tile row is its own round trip to HBM.

So in both, the arithmetic is not the bottleneck: moving data is.

## Kernels

### Fewer and cheaper memory accesses

A load or store to HBM waits for the whole round trip (100 ns to the first
data, see `platform.hbm_rd_latency_ns`); one to the scratchpad takes a
couple of cycles.

* **Stage what you reuse in the scratchpad.** A tile read more than once
  (the B panel of a tiled GEMM, a layer's weights, an input band of a
  convolution) should come from HBM once. `gemm_tiled` shows the pattern
  and measured 1.37x from this alone.
* **Do epilogues in the scratchpad.** Store the accumulator there, apply
  bias and activation with vector instructions, then write the finished
  tile to HBM once, instead of storing to HBM, reloading and storing again.
* **Use the widest access that fits.** `vle16`/`vse16` move `VLMAX`
  elements for the price of one access; `lhu`/`sh` move one. Copy loops
  (im2col, padding, transposes) written with scalar loads are the largest
  single cost in `lenet`. Where the source run is contiguous, copy it with
  vector loads and stores; where a tile row is what you need, `mld` /
  `mst` between HBM and the scratchpad copies a whole tile.
* **Reuse overlapping data.** Neighbouring convolution windows share
  `K - 1` of their `K` columns. Shifting the previous patch and loading one
  new column is cheaper than rebuilding the patch.
* **Choose the layout for the hardware you have.** Blocked tiles are one
  contiguous block each ([memory-formats.md](memory-formats.md)). That
  pays off as soon as your memory path can fetch more than one row per
  request. Packing happens on the host: do it once, outside the measured
  region if it is model loading, inside if it is per inference.
* **Pad instead of branching.** Buffers padded to a multiple of the vector
  or tile size remove the special case for the last partial chunk.

### Fewer instructions

Scalar instructions are not free on a small control core (two cycles each
in the reference design), and inner loops are mostly address arithmetic.

* **Hoist and strength-reduce.** Compute strides and byte counts once
  before the loop; step pointers by adding instead of recomputing
  `base + i * stride` (there is no multiply instruction).
* **Unroll short loops** whose trip count is known from the configuration.
* **Keep hot loops inside the instruction cache.** In the reference design
  it holds `ICACHE_LINES x HBM_DATA_W / 32` instructions (128 by default),
  direct mapped, and a miss is an HBM round trip. A loop larger than the
  cache, or a loop and a subroutine it calls that land on the same cache
  lines, miss on every iteration: shorten the loop or move the subroutine.
* **Let one instruction do more.** `vfmacc` instead of `vfmul` + `vfadd`;
  `vfmax.vf vd, vs, zero` for ReLU; a `.vf` form with a scalar instead of
  loading a constant vector.

### Using the units well

* **Fill the tiles.** A tile product costs the same whether the tile is
  full or mostly padding. Batch small problems (the `lenet` kernel pushes
  up to `MAT_DIM` images through a fully connected layer in one product)
  and choose tile-aligned dimensions where you control them.
* **Reductions are sequential** in the reference design (one element per
  cycle). For a dot product of long vectors the matrix unit or `vfmacc`
  into a vector of partial sums is faster than `vfmul` + `vfredsum` per
  chunk.
* **Split work across cores without waiting.** Give every core its own
  share by index (`mhartid`, `CSR_NCORES`) and its own output region, so no
  `barrier` is needed until the very end. Balance the shares: the run ends
  when the slowest core does. Remember that all cores share one HBM port,
  so a kernel limited by HBM traffic does not scale with cores until its
  data is in the scratchpads.
* **Not every core has every unit** (`NUM_VPUS`, `NUM_MXUS`). Check
  `CSR_UNITS` and give matrix-only cores matrix work.

## Driver (`sw/common/accel.h`)

The driver is ordinary C over memory-mapped host registers. Each register
access crosses the link to the accelerator and takes about 20 ns
([host-model.md](host-model.md#the-link-between-host-and-accelerator)),
which is 40 host CPU cycles, and the host is busy or stalled for all of it.

* **Sleep instead of polling.** `accel_run()` and `accel_wait()` poll
  `STATUS` in a loop; `accel_wait_irq()` sleeps until the interrupt. On
  `lenet` (reference design, default configuration) the run time is the
  same, but the host executes 38 instructions instead of 3.2 million and
  its energy drops from 0.727 mJ to 0.539 mJ, 26 % less:

  ```sh
  make score TEST=lenet                                   # polling
  make score TEST=lenet SW_CFLAGS="-O2 -g -DLENET_WAIT_IRQ"   # interrupt
  ```

  What remains is the host's idle power and leakage for the duration of
  the run, so after this the way to save host energy is to finish sooner.
* **Launch less often.** A launch is about ten register writes. One kernel
  that loops over all the work beats many small launches; pass a pointer
  to a descriptor block in HBM instead of calling again with new
  arguments.
* **Write only what changed.** If your register block keeps `START_PC`,
  the arguments and `CORES` between launches, a second launch of the same
  kernel needs only the `CTRL` write. That is a driver function you can
  add.
* **Read less afterwards.** `accel_cycles()` and `accel_instret()` are two
  register reads each. Keep them out of the measured region unless you
  need them.
* **Extend the register map if it helps.** A single register that reports
  "done, no error" in one read, or a result written to a register instead
  of to HBM, are legitimate designs. Keep `accel_pkg.sv`, `accel.h` and
  [memory-map.md](memory-map.md) in step.

## Host program

Inside the region of interest the host is a 2 GHz core with a cache model
and an energy bill ([host-model.md](host-model.md)). Whatever the host
computes there competes with doing it on the accelerator.

* **Decide what belongs in the region.** Loading and packing the model's
  weights is a one-time cost; preparing each input is part of inference.
  Be consistent and say what you measured.
* **Move per-inference host work to the accelerator when it is data
  parallel** (normalizing inputs, packing patches, argmax over the
  outputs), and keep it on the host when it is short and branchy. Compare
  both with `make score`; the host draws several times the power of a
  small accelerator while it is busy.
* **Mind the host's caches** (32 KiB L1, 512 KiB L2). Walk arrays in
  order, keep working sets small, and avoid touching HBM buffers from the
  host more than once: an L2 miss costs 50 ns.
* **Avoid slow host instructions in loops:** integer division (20
  cycles), floating-point division and square root (15). Shifts and
  multiplications by reciprocals are much cheaper.
* **Compiler flags** are `SW_CFLAGS` (default `-O2 -g`). `-O3` or
  `-funroll-loops` are worth one experiment.

## When software is not enough

If a profile says a kernel spends most of its time on something the
instruction set makes awkward, change the instruction set
([isa.md](isa.md#adding-an-instruction)). Candidates that came out of the
measurements above:

| Observation | Hardware/ISA idea |
|---|---|
| im2col is scalar copying | a gather or strided vector load; a DMA engine that copies HBM to scratchpad in the background |
| one HBM round trip per tile row | several outstanding requests, or one burst per blocked tile |
| store, reload, activate, store | activation fused into the accumulator store |
| the control core waits during every `mmacc` | non-blocking matrix instructions |
| scalar loop overhead | hardware loops, or a multiply instruction for address arithmetic |

Each of these is in the optimization list of
[project-guide.md](project-guide.md#once-it-works-optimizations).

## Checklist

- [ ] the region of interest covers exactly the workload
- [ ] the kernel has per-phase cycle counters, and you know the top phase
- [ ] nothing reused is fetched from HBM twice
- [ ] copy loops use vector or tile accesses where the data is contiguous
- [ ] the host sleeps while the accelerator works
- [ ] the software still reads its configuration at run time (`vsetvl`,
      `accel_get_config()`, kernel CSRs) and passes in a second
      configuration
- [ ] before/after `make score` for every change you keep
