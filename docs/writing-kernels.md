# Writing kernels and host programs

A "test" is a directory `sw/tests/<name>/` with:

* `main.c`: the **host program** (RV64G). It prepares data in HBM,
  launches kernels, checks results and returns 0 for pass.
* one or more `*.S` files: the **kernels** (accelerator code, RV32). Every
  `.S` file is accelerator code; host code is C only.
* optionally `plusargs`: default simulator plusargs for this test.

Every `.c` and `.S` file in the directory is built automatically into
`build/sw/<name>/<name>.elf`. There is nothing to register. Because host and
accelerator have different instruction sets, the build has two stages
(`sw/sw.mk`): the kernels are assembled and linked into their own image
(`kernel.elf`, disassembly in `kernel.dis`), which is then embedded at the
start of HBM in the host program. The kernels' `.globl` symbols are visible
to `main.c`; kernels cannot refer to symbols of the host program (pass
addresses as arguments instead). Addresses handed to the accelerator are 32
bits: write `(uint32_t)(uintptr_t)ptr`.

```sh
mkdir sw/tests/my_kernel
$EDITOR sw/tests/my_kernel/main.c sw/tests/my_kernel/kernel.S
make run TEST=my_kernel
```

## A complete example

`kernel.S` scales a vector, `y[i] = alpha * x[i]`:

```asm
#include "accel_isa.h"

// a0 = n, a1 = x, a2 = y, a3 = alpha (bf16 bits)
ACCEL_KERNEL(scale_kernel)
1:
  vsetvl   t0, a0          // t0 = vl = min(n, VLMAX)
  vle16    v1, 0(a1)
  vfmul.vf v2, v1, a3      // v2 = v1 * alpha
  vse16    v2, 0(a2)
  sub      a0, a0, t0
  slli     t1, t0, 1       // 2 bytes per element
  add      a1, a1, t1
  add      a2, a2, t1
  bnez     a0, 1b
  ecall                    // done
```

`main.c`:

```c
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

#define N 300
static bf16_t x[512] HBM_BUF;   // padded to a multiple of VLMAX
static bf16_t y[512] HBM_BUF;
extern void scale_kernel(void);

int main(void) {
  for (int i = 0; i < N; i++) x[i] = f32_to_bf16((float)i * 0.25f);
  bf16_t alpha = f32_to_bf16(3.0f);

  uint32_t args[] = {N, (uint32_t)x, (uint32_t)y, alpha};
  uint32_t st = accel_run(scale_kernel, args, 4);
  if (st & ACCEL_STATUS_ERROR) return 1;
  printf("%u cycles\n", (uint32_t)accel_cycles());

  int errors = 0;
  for (int i = 0; i < N; i++)
    if (y[i] != bf16_mul(x[i], alpha)) errors++;   // bit-exact reference
  printf("%d errors\n", errors);
  return errors != 0;
}
```

## Kernel conventions

| Topic | Rule |
|---|---|
| Entry | `ACCEL_KERNEL(name)` puts the code in HBM (`.accel.text`) and exports `name`. In C, declare `extern void name(void);` and pass `name` to `accel_run`. |
| Arguments | up to 8 words in `a0..a7`. For more, pass a pointer to a struct in HBM and read it with `lw` (see `sw/tests/gemm`). |
| Registers | all 31 `x` registers are yours, including `sp`, `gp`, `tp` and `ra`; there is no ABI or stack. `ra` is set by `jal`/`call` if you use subroutines. |
| Exit | `ecall` = success. `ebreak` = report an error (cause 4), handy as an assert. |
| Register names | `v0..v31`, `tr0..tr7`, `acc0..acc7` are preprocessor aliases. **Don't use them as labels.** Use `.L` local labels or numbers. |
| Constants | bf16 values go in `x` registers as bit patterns: `li t0, BF16_ONE` (0x3F80). Make others on the host with `f32_to_bf16()`. |
| Memory | HBM (shared) and this core's scratchpad at `SPAD_BASE` (private, `csrr CSR_SPADSZ` bytes). Respect the alignment rules (vectors: VLEN/8, tiles: MAT_DIM*2) for both. |
| Cores | every launched core runs the same kernel. `csrr t0, mhartid` / `csrr t1, CSR_NCORES` tell them apart; `barrier` synchronizes them. Launch with `accel_run_cores(k, args, n, cfg.num_cores)`; `accel_run` uses one core. |
| State | vector/tile/accumulator registers keep their values between launches but are not guaranteed to be initialised. `mzero` accumulators before use. |
| Portability | never hard-code VLEN, MAT_DIM, the core count or the scratchpad size. Use `vsetvl`, `csrr CSR_VLENB / CSR_NCORES / CSR_SPADSZ` and pass tile sizes from the host (`accel_get_config()`). |

## Host program conventions

* There is no libc. Use [`runtime.h`](../sw/common/runtime.h): `printf`
  (`%d %u %x %s %c %f %p`, widths), `memcpy/memset/memcmp`, `rand_u32`,
  `rand_float`, `hbm_alloc`, `sim_cycles`, `exit`.
* Put anything the accelerator reads or writes in HBM: `HBM_BUF` (zeroed),
  `HBM_DATA` (initialised) or `hbm_alloc()`. Host RAM is invisible to the
  accelerator.
* Check results with the reference model in
  [`bf16.h`](../sw/common/bf16.h) using exact equality, as described in
  [numerics.md](numerics.md).
* Big software reference computations are slow at the default 1 host
  instruction per cycle. Add `+host_ipc=16` to the test's `plusargs` file.
* Put `roi_begin()` / `roi_end()` around the part you want measured. Inside,
  the host is a timed 2 GHz core and its energy is counted
  ([host-model.md](host-model.md)); polling `STATUS` there keeps the CPU
  busy, `accel_wait_irq()` lets it sleep.
* Matrices: use [`mat_layout.h`](../sw/common/mat_layout.h) and see
  [memory-formats.md](memory-formats.md).

## Patterns

**Element-wise (any length):** the strip-mining loop above.

**Dot product / reduction:**

```asm
  vmv.v.x     v0, zero         // v0[0] = +0.0 (the running sum)
1:vsetvl      t0, a0
  vle16       v1, 0(a1)
  vle16       v2, 0(a2)
  vfmul.vv    v3, v1, v2
  vfredsum.vs v0, v3, v0       // v0[0] += sum(v3[0..vl-1])
  ...loop...
  vmv.x.s     t1, v0           // result bits in t1
```

This rounds to bf16 once per chunk. For full fp32 accumulation, use the
matrix unit.

**Matrix multiply:** for each output tile, `mzero`, then for each k tile
`mld` A and B tiles and `mmacc`, and finally `msta`. See `sw/tests/gemm`
(row-major) and `sw/tests/layouts` (any format). Epilogues such as bias or
activation run on the vector unit over the stored output.

**Splitting work over cores:** give each core every `ncores`-th work item
(output tile, row block, vector chunk):

```asm
  csrr  s0, mhartid
  csrr  s1, CSR_NCORES
  mv    a5, s0                 // j = my first column tile
1:bge   a5, s6, 2f             // s6 = number of column tiles
  ...compute column tile j...
  add   a5, a5, s1             // j += ncores
  j     1b
2:ecall
```

Items must not overlap in what they write. If a later phase needs every
core's results, write them to HBM, then `barrier`.

**Reusing data through the scratchpad:** copy what is read more than once
from HBM into the scratchpad once, then reuse it from there (2 cycles per
tile row instead of ~45):

```asm
  li    a2, SPAD_BASE
  mld   tr1, t1, s9            // tile from HBM (row stride ldb)
  mst   tr1, a2, s11           // to the scratchpad, contiguous (stride MAT_DIM*2)
  ...
  mld   tr1, a2, s11           // later, many times: from the scratchpad
```

`sw/tests/gemm_tiled` keeps a whole column panel of B in each core's
scratchpad, does the ReLU epilogue there, and compares the speed against
plain HBM. See [sram.md](sram.md#using-the-scratchpad-well).

## Debugging

1. Read the failure: `accel_run` prints the error cause, PC and instruction.
   Find the PC in `build/sw/<test>/<test>.dis`.
2. `SIM_ARGS=+accel_trace` prints every instruction the accelerator
   executes, with its core and cycle (`grep core1` to follow one core).
3. Print from the host: dump buffers after the kernel. Add `ebreak` in the
   kernel to stop at a point of interest and inspect HBM from the host.
4. `WAVES=1` and `make verdi` for cycle-level debugging of the RTL.
5. Is it the kernel or the hardware? Write the same computation in plain C
   on the host first. If the reference and hardware disagree on simple
   inputs, write a tiny directed test.
