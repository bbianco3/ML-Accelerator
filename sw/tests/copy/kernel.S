// copy/kernel.S -- the hcpy / hcpy2d instructions (copy runs of bf16 elements).
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

// copy2d_jobs(a0 = job table, a1 = number of jobs): jobs {dst, src, shape}
ACCEL_KERNEL(copy2d_jobs)
  beqz  a1, 2f
1:
  lw    t0, 0(a0)
  lw    t1, 4(a0)
  lw    t2, 8(a0)
  hcpy2d t0, t1, t2
  addi  a0, a0, 12
  addi  a1, a1, -1
  bnez  a1, 1b
2:
  ecall

// copy2d_one(a0 = dst, a1 = src, a2 = shape): a single hcpy2d (fault test)
ACCEL_KERNEL(copy2d_one)
  .globl pc_copy2d_one
pc_copy2d_one:
  hcpy2d a0, a1, a2
  ecall

// tile_copy(a0 = dst, a1 = src, a2 = stride): mld tr0 from src, mst to dst.
// With stride = one bus beat and src in HBM, the mld is a single read burst.
ACCEL_KERNEL(tile_copy)
  .globl pc_tile_mld
pc_tile_mld:
  mld   tr0, a1, a2
  mst   tr0, a0, a2
  ecall

// copy_one(a0 = dst, a1 = src, a2 = n): a single hcpy (fault and timing tests)
ACCEL_KERNEL(copy_one)
  .globl pc_copy_one
pc_copy_one:
  hcpy  a0, a1, a2
  ecall