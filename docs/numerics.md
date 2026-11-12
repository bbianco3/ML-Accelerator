# Numerics contract

Every floating-point result the accelerator produces is defined **bit for
bit** by the rules below. The RTL (`hw/rtl/accel_fp_pkg.sv`) and the C
reference model (`sw/common/bf16.h`) implement exactly these rules, so host
programs can check kernels with `==` on the bit patterns, with no tolerances.
`make unit` cross-checks the two on millions of random and edge-case
operands.

If you change the hardware's arithmetic, change `bf16.h` the same way.
Otherwise every test that compares results will fail, which is the point.

## Formats

| Format | Bits | Layout | Used for |
|---|---|---|---|
| bf16 | 16 | 1 sign, 8 exponent, 7 fraction | all data in memory, vector and tile registers |
| fp32 | 32 | IEEE binary32 | internal arithmetic, matrix accumulators |

bf16 is the top half of an fp32. `bf16 -> fp32` is exact (append 16 zero bits).

## Rules

1. **Compute in fp32, round to bf16 once.** Every vector op computes its
   result in fp32 and rounds it to bf16 with **round-to-nearest, ties to
   even (RNE)**.
2. **Products are exact.** A bf16 x bf16 product has a 16-bit significand,
   which fits in fp32 exactly. The only "rounding" a product sees is
   overflow to infinity or underflow to zero.
3. **DAZ / FTZ.** Subnormal *inputs* are treated as zero of the same sign
   (denormals-are-zero). Subnormal *results*, meaning any result with
   magnitude below 2^-126 before rounding, become zero of the same sign
   (flush-to-zero). There are no subnormals anywhere.
4. **Canonical NaN.** Any NaN result is the quiet NaN `0x7FC0` (bf16) or
   `0x7FC00000` (fp32). NaN payloads and signs are not propagated.
   `inf - inf`, `0 * inf` and any NaN input give NaN.
5. **Signed zeros** follow IEEE: `x + (-x) = +0`, `(-0) + (-0) = -0`,
   products take the XOR of the signs, flushed values keep their sign.
6. **Overflow** goes to infinity of the right sign. There is no saturation.
7. **Data movement is bit-exact.** Loads, stores, `vmv.*`, `mld`/`mst` copy
   bits without DAZ. Only arithmetic and `msta` (fp32 to bf16) change
   values.
8. **No exception flags.** Nothing is signalled; results are just values.

## Operation definitions

Using `f(x)` = bf16 to fp32 with DAZ, `r(y)` = fp32 to bf16 with RNE/FTZ and
canonical NaN, `add32` = correctly rounded fp32 addition with DAZ/FTZ, and
`mul` = exact bf16 x bf16 to fp32 product with FTZ:

| Instruction | Result |
|---|---|
| `vfadd` | `r(add32(f(a), f(b)))` |
| `vfsub` | `r(add32(f(a), -f(b)))` |
| `vfmul` | `r(mul(a, b))` |
| `vfmacc` | `r(add32(mul(a, b), f(d)))`: one fp32 rounding, then one bf16 rounding |
| `vfmax` / `vfmin` | IEEE ordering on DAZ'd values with `-0 < +0`. Either input NaN gives canonical NaN. |
| `vfredsum` | `acc = f(init); for i in 0..vl-1: acc = add32(acc, f(x[i])); result = r(acc)` |
| `vfredmax` | `m = init; for i in 0..vl-1: m = max(m, x[i])` |
| `mmacc` | for k in 0..MAT_DIM-1: `acc[i][j] = add32(acc[i][j], mul(A[i][k], B[k][j]))` |
| `msta` | `r(acc[i][j])` |

The **order** of reductions and of the `mmacc` k-loop is part of the
contract. fp addition is not associative, so a faster adder tree would give
different (not worse, just different) bits. If you build one, update the
reference model and this table.

## Why "fp32 then round to bf16" is exact enough

Rounding twice (exact value to fp32, then to bf16) can in general differ
from rounding once. But for `+ - *` it is known to be harmless when the
intermediate format has at least 2p+2 significand bits, where p is the
target precision (Figueroa, 1995). fp32 has 24 bits and bf16 needs
2·8+2 = 18, so `vfadd`, `vfsub` and `vfmul` are **correctly rounded** bf16
operations. `vfmacc` is a genuine double rounding (fp32 sum, then bf16).
It's defined that way on purpose, because it is cheap and matches
mixed-precision hardware.

## How this compares to common hardware

* Same storage format and rounding as TPUs, Intel AMX-BF16 and NVIDIA
  tensor cores: bf16 inputs, fp32 accumulation.
* Most ML hardware also flushes subnormals.
* Unlike IEEE-754, there are no flags and only one rounding mode.

## Using the reference model

```c
#include "bf16.h"
bf16_t a = f32_to_bf16(1.5f);          // make inputs (RNE)
bf16_t s = bf16_add(a, a);             // exactly what vfadd returns
float  acc = 0.0f;
acc = mxu_mac(acc, a, a);              // one step of mmacc
bf16_t out = f32_to_bf16(acc);         // what msta stores
mxu_matmul_ref(C, ldc, A, lda, B, ldb, M, N, K);  // whole GEMM, hardware order
```

Compile with `-ffp-contract=off` (the default in `sw/sw.mk`). Otherwise GCC
may fuse `a*b + c` into an FMA instruction that rounds differently.

## Tolerance: what "correct" means for matrix and tensor results

The contract above describes the reference design bit for bit, and
element-wise vector operations (`vfadd`, `vfmul`, `vfmax`, ...) are tested
that way: one operation, one rounding, one right answer.

Results that are **sums of many products** (`mmacc`, GEMM, convolutions,
whole networks) are different. A systolic array, an adder tree, a
dot-product engine or wider/narrower accumulators all add in a different
order or precision and get slightly different, equally valid bits. Those
results are therefore checked against the reference model within a
tolerance ([`sw/common/check.h`](../sw/common/check.h)):

```
accepted when   |got - ref| <= tolerance_abs + tolerance_rel * |ref|
```

`tolerance_abs` and `tolerance_rel` (both 0.02) are set in
[`competition.json`](../competition.json) and compiled into every test. NaN
only matches NaN and infinity only the same infinity. For scale: one bf16
rounding is at most 0.4 % of the value, so the tolerance leaves room for a
few roundings and some cancellation, but not for accumulating in bf16 over
long sums, dropping terms, or a wrong activation.

```c
#include "check.h"
if (!bf16_close(C[i], f32_to_bf16(ref[i]))) errors++;
```

The tests `matmul`, `gemm`, `gemm_tiled`, `layouts` and `lenet` use it
(`lenet` also requires every digit to be classified correctly and prints the
largest difference it saw). If you change what an instruction computes beyond
that, e.g. a different rounding in `vfadd`, the numerics contract itself
changes: update RTL, `bf16.h` and this document together.
