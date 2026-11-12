// units/kernel.S -- every core does the work its own units allow.
#include "accel_isa.h"

// units_work: runs on every core.
//   a0 = uint32_t out[]      out[hart] = CSR_UNITS of that core
//   a1 = x, a2 = y           bf16 vectors, one VLMAX-element chunk per core
//   a3 = A                   one MAT_DIM x MAT_DIM tile (row stride a4)
//   a4 = row stride in bytes of A and C
//   a5 = C, a6 = bytes per C tile; core h writes tile h
// A core with a VPU computes y = x + x on its chunk; a core with an MXU
// computes C = A x A into its tile. Cores never touch each other's data, so
// no barrier is needed.
ACCEL_KERNEL(units_work)
  csrr  s0, mhartid
  csrr  s1, CSR_UNITS
  slli  t0, s0, 2
  add   t0, a0, t0
  sw    s1, 0(t0)

  // s2 = hart * VLENB, s3 = hart * (bytes per C tile); there is no multiplier
  csrr  t2, CSR_VLENB
  li    s2, 0
  li    s3, 0
  mv    t4, s0
1:
  beqz  t4, 2f
  add   s2, s2, t2
  add   s3, s3, a6
  addi  t4, t4, -1
  j     1b
2:
  andi  t1, s1, 1             // VPU?
  beqz  t1, 3f
  srli  t5, t2, 1             // VLMAX elements
  vsetvl t5, t5
  add   t6, a1, s2
  vle16 v1, 0(t6)
  vfadd.vv v2, v1, v1
  add   t6, a2, s2
  vse16 v2, 0(t6)
3:
  andi  t1, s1, 2             // MXU?
  beqz  t1, 4f
  mld   tr0, a3, a4
  mzero acc0
  mmacc acc0, tr0, tr0
  add   t6, a5, s3
  msta  acc0, t6, a4
4:
  ecall

// A vector / matrix instruction on every core: cores without the unit must
// stop with an illegal-instruction error.
ACCEL_KERNEL(units_vec)
  li    t0, 1
  .globl pc_units_vec
pc_units_vec:
  vsetvl t0, t0
  ecall

ACCEL_KERNEL(units_mat)
  .globl pc_units_mat
pc_units_mat:
  mzero acc0
  ecall
