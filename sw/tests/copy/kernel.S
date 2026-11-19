// copy/kernel.S -- the hcpy instruction (copy a run of bf16 elements).
#include "accel_isa.h"

// copy_jobs(a0 = job table, a1 = number of jobs)
// Each job is three words {dst, src, n}: hcpy dst <- src, n halfwords.
ACCEL_KERNEL(copy_jobs)
  beqz  a1, 2f
1:
  lw    t0, 0(a0)            // dst
  lw    t1, 4(a0)            // src
  lw    t2, 8(a0)            // n
  hcpy  t0, t1, t2
  addi  a0, a0, 12
  addi  a1, a1, -1
  bnez  a1, 1b
2:
  ecall

// copy_one(a0 = dst, a1 = src, a2 = n): a single hcpy (fault and timing tests)
ACCEL_KERNEL(copy_one)
  .globl pc_copy_one
pc_copy_one:
  hcpy  a0, a1, a2
  ecall