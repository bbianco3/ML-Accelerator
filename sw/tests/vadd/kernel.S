// vadd/kernel.S -- z[i] = x[i] + y[i] for i < n  (bf16)
//
// Arguments (set by the host through ARG0..ARG3):
//   a0 = n          number of elements
//   a1 = x          input  (HBM, VLEN/8-byte aligned)
//   a2 = y          input  (HBM, VLEN/8-byte aligned)
//   a3 = z          output (HBM, VLEN/8-byte aligned)
//
// Classic RISC-V V-style strip-mining: each iteration asks vsetvl how many
// elements fit in a vector register (vl <= VLMAX) and advances by that much,
// so the same kernel works for every VLEN.
#include "accel_isa.h"

ACCEL_KERNEL(vadd_kernel)
1:
  vsetvl    t0, a0          // t0 = vl = min(n, VLMAX)
  vle16     v1, 0(a1)
  vle16     v2, 0(a2)
  vfadd.vv  v3, v1, v2
  vse16     v3, 0(a3)
  sub       a0, a0, t0      // n -= vl
  slli      t1, t0, 1       // bytes = 2 * vl
  add       a1, a1, t1
  add       a2, a2, t1
  add       a3, a3, t1
  bnez      a0, 1b
  ecall                     // done
