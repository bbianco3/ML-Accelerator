# SIGARCH ML Accelerator Template

A starting point for designing an ML accelerator in SystemVerilog,
simulating it with a RISC-V host running real C programs, and synthesizing
it with Synopsys Design Compiler in the **ASAP7** predictive 7 nm PDK. It's
set up for UIUC EWS machines (VCS, Verdi, DC) but works anywhere those
tools are installed.

> **The accelerator RTL is not included.** `hw/rtl/accel_top.sv` is an empty
> shell with the top-level ports; designing what goes inside is the
> project. Until then every test fails with a timeout. The documents in
> `docs/` describe the *reference architecture* that the instruction set,
> the software in `sw/` and the measured results come from: use it as a
> specification and a starting point, or change the instruction set,
> kernels and memory formats along with your hardware.

What you get:

* **`hw/`**: the top-level shell (`hw/rtl/accel_top.sv`), the instruction
  and register definitions (`accel_pkg.sv`), bf16/fp32 arithmetic functions
  that match the software reference model (`accel_fp_pkg.sv`), an SRAM macro
  generator and the synthesis flow. The reference architecture it is meant
  to hold:
  * an AXI4-Lite host control port, an AXI4 **HBM** port and an interrupt
  * `NUM_CORES` compute cores (default 2) that run **RISC-V-encoded
    kernels** out of HBM (RV32I + custom vector, matrix and barrier
    instructions), each with:
    * a **bf16 vector unit** with a `VLEN` parameter
    * a **matrix unit** for `MAT_DIM x MAT_DIM` (default 16 x 16) bf16 GEMM
      with fp32 accumulators
    * a private **scratchpad SRAM** (`SPAD_KB`, default 16 KiB) for tiles
  * an **SRAM macro generator** for ASAP7 (`hw/sram/`): the scratchpads'
    area, timing and power show up in synthesis
* **`sim/`**: a VCS testbench with a **2 GHz RV64G host CPU**
  (instruction-set simulator over DPI with a time and energy model), a
  host-to-accelerator link delay, a timed HBM model and pass/fail reporting
* **`sw/`**: host runtime, accelerator driver, kernel assembler macros, a
  bit-exact bf16 reference model, matrix-layout helpers and 14 example tests,
  including inference with a **pretrained LeNet-5** on MNIST digits
* **`competition.json`** + `make score`: shared limits (clock, area, host
  link delay, result tolerance) and the score, area x energy x time^2
* **`docs/`**: architecture, ISA, numerics, simulation behaviour, memory
  formats, parameters, synthesis, design decisions and a 3-week project guide

```
          RV64G host (C)  --AXI4-Lite-->  accel_top                 --AXI4-->  HBM
          main.c: prepare data,           core 0 .. NUM_CORES-1                kernels + data
          launch, check results             control core + VPU (VLEN)
                          <----- irq -----  + MXU (MAT_DIM^2) + scratchpad SRAM
```

## Quick start (on an EWS machine)

```sh
git clone <this repo> && cd sigarch-ml-accelerator-template
source setup_env.sh            # VCS/Verdi/DC + RISC-V GCC
make run TEST=vadd             # build kernel + host program + simulator, run
make regress                   # all tests
```

Expected output ends with:

```
[host] vadd: 0 errors
[tb] *** TEST PASSED ***
PASS: vadd  (log: build/runs/v256_m16_t4_a2_r4_d256_i16_c2_s16/vadd/sim.log)
```

More:

```sh
make help                                  # all targets and knobs
make run TEST=gemm SIM_ARGS=+accel_trace   # trace every accelerator instruction
make run TEST=matmul WAVES=1 && make verdi TEST=matmul WAVES=1   # waveforms
make regress VLEN=512 MAT_DIM=8 MXU_ROWS=8 # another hardware configuration
make run TEST=gemm_tiled NUM_CORES=4       # tiled GEMM on 4 cores with scratchpads
make run TEST=units NUM_CORES=4 NUM_VPUS=1 # 4 matrix units, 1 vector unit
make regress FP_PIPE=2                     # deeper pipelining in the VPU/MXU datapaths
make run TEST=lenet                        # pretrained LeNet-5 on 16 MNIST digits (~1 min)
make regress SIM_SRAM=macro                # simulate the SRAM macro structure DC sees
make unit                                  # FP unit: RTL vs C reference
make lint                                  # VCS lint of the RTL
make synth                                 # DC, ASAP7, 400 MHz (fetches the PDK, generates SRAMs)
make synth CLK_PERIOD=2.0 VLEN=128         # other clock / config (period in ns)
make synth SRAM=flops                      # scratchpads from flip-flops, to compare
make synth PDK=freepdk45 CLK_PERIOD=10     # FreePDK45 instead
```

`setup_env.sh` loads `Synopsys_x86-64/2024` and uses the RISC-V toolchain
in `/class/ece411/riscv`. Elsewhere, set `SYNOPSYS_MODULE` and `RISCV_ROOT`
before sourcing it (see the top of the script). The ASAP7 cell libraries are
downloaded from GitHub and compiled with Library Compiler into `pdk/asap7/`
the first time you synthesize (see [docs/synthesis.md](docs/synthesis.md)). It also takes
the ancient `make` 3.80 that the Synopsys module puts on `PATH` back off it.

### Working from your own laptop

`run_on_ews.sh` rsyncs the repo to EWS, runs a make target there and copies
logs, waveforms and reports back into `ews_run_artifacts/`:

```sh
EWS_HOST=<netid>@linux.ews.illinois.edu ./run_on_ews.sh run TEST=matmul WAVES=1
```

(Set up SSH keys first: `ssh-keygen` and then `ssh-copy-id <netid>@linux.ews.illinois.edu`.)

## Repository layout

```
hw/rtl/            accelerator RTL (filelist.f = compile order)
hw/sram/           SRAM macro generator (sram_gen.py) and `make sram` script
hw/synth/          Design Compiler script + make fragment
hw/synth/pdk/      per-PDK settings (asap7.tcl, freepdk45.tcl) + ASAP7 fetch/compile script
pdk/               downloaded PDK files + generated SRAM macros (git-ignored)
sim/tb/            testbench: tb_top, host_bfm (AXI4-Lite master), hbm_model (AXI4 slave)
sim/csrc/          RV64G ISS, host time/energy model, platform memory, ELF loader, DPI glue
sim/unit/fp/       FP unit test (RTL functions vs C reference)
sw/common/         crt0, linker script, runtime, accel.h (driver), accel_isa.h (kernel
                   macros), bf16.h (reference numerics), mat_layout.h, memory_map.h
sw/tests/<name>/   one test each: main.c (host) + kernel.S (accelerator) [+ plusargs]
docs/              documentation (start at docs/README.md)
build/             everything generated (git-ignored)
```

## Writing your own kernel

```sh
mkdir sw/tests/my_test        # add main.c and kernel.S (see docs/writing-kernels.md)
make run TEST=my_test
```

A kernel is plain RISC-V assembly plus accelerator instructions:

```asm
#include "accel_isa.h"
ACCEL_KERNEL(vadd_kernel)       // a0 = n, a1 = x, a2 = y, a3 = z
1:  vsetvl    t0, a0
    vle16     v1, 0(a1)
    vle16     v2, 0(a2)
    vfadd.vv  v3, v1, v2
    vse16     v3, 0(a3)
    sub a0, a0, t0; slli t1, t0, 1; add a1, a1, t1; add a2, a2, t1; add a3, a3, t1
    bnez      a0, 1b
    ecall
```

## Status

All 14 system tests and the FP unit test pass for configurations from
`VLEN=64, MAT_DIM=4, HBM_DATA_W=32` up to `VLEN=2048, MAT_DIM=64,
HBM_DATA_W=1024`, with 1 to 8 cores, scratchpads from none to 64 KiB
(behavioral and SRAM-macro models), and with and without random HBM
back-pressure. The reference
microarchitecture is intentionally simple and slow. See
[docs/architecture.md](docs/architecture.md#where-to-go-from-here) and
[docs/project-guide.md](docs/project-guide.md) for what to improve.
