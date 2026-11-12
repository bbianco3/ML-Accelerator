// multicore/kernel.S -- several cores running one kernel (SPMD).
#include "accel_isa.h"

// mc_basic(a0 = struct mc_params *p)    (layout: main.c)
//   1. ids[2*id] = id, ids[2*id+1] = ncores
//   2. `rounds` times: write slot[id] after a core-dependent delay, barrier,
//      sum every core's slot into sums[round*16 + id], barrier.
//      Without working barriers the sums come out wrong.
//   3. z = x + y, each core doing its own chunk of `per_core` elements.
ACCEL_KERNEL(mc_basic)
  csrr  s0, mhartid
  csrr  s1, CSR_NCORES
  lw    a1, 0(a0)            // ids
  lw    a2, 4(a0)            // slots
  lw    a3, 8(a0)            // sums
  lw    a4, 12(a0)           // rounds

  slli  t0, s0, 3
  add   t0, a1, t0
  sw    s0, 0(t0)
  sw    s1, 4(t0)

  li    s2, 0                // round
.Lround:
  // delay: (id + 1) * (round + 1) * 50 loop iterations
  addi  t0, s0, 1
  addi  t1, s2, 1
  li    t2, 0
.Lmul:                       // t2 = t0 * t1 (no M extension on the accelerator)
  add   t2, t2, t0
  addi  t1, t1, -1
  bnez  t1, .Lmul
  li    t1, 50
  li    t3, 0
.Lmul2:
  add   t3, t3, t2
  addi  t1, t1, -1
  bnez  t1, .Lmul2
.Ldelay:
  addi  t3, t3, -1
  bnez  t3, .Ldelay

  // slot[id] = (round + 1) * (id + 1)
  addi  t0, s0, 1
  addi  t1, s2, 1
  li    t2, 0
.Lmul3:
  add   t2, t2, t0
  addi  t1, t1, -1
  bnez  t1, .Lmul3
  slli  t0, s0, 2
  add   t0, a2, t0
  sw    t2, 0(t0)

  barrier

  // sums[round*16 + id] = sum of slot[0 .. ncores-1]
  li    t0, 0
  li    t1, 0
  mv    t2, a2
.Lsum:
  lw    t3, 0(t2)
  add   t0, t0, t3
  addi  t2, t2, 4
  addi  t1, t1, 1
  bne   t1, s1, .Lsum
  slli  t1, s2, 6            // round * 64 bytes
  slli  t2, s0, 2
  add   t1, t1, t2
  add   t1, a3, t1
  sw    t0, 0(t1)

  barrier                    // nobody rewrites a slot before everyone has read it

  addi  s2, s2, 1
  bne   s2, a4, .Lround

  // ---- z = x + y on this core's chunk ----
  lw    a5, 16(a0)           // x
  lw    a6, 20(a0)           // y
  lw    a7, 24(a0)           // z
  lw    t4, 28(a0)           // per_core elements (multiple of VLMAX)
  slli  t0, t4, 1            // chunk bytes
  li    t1, 0                // offset = id * chunk bytes
  mv    t2, s0
  beqz  t2, 2f
1:
  add   t1, t1, t0
  addi  t2, t2, -1
  bnez  t2, 1b
2:
  add   a5, a5, t1
  add   a6, a6, t1
  add   a7, a7, t1
.Lvadd:
  vsetvl   t2, t4
  vle16    v1, 0(a5)
  vle16    v2, 0(a6)
  vfadd.vv v3, v1, v2
  vse16    v3, 0(a7)
  slli     t3, t2, 1
  add      a5, a5, t3
  add      a6, a6, t3
  add      a7, a7, t3
  sub      t4, t4, t2
  bnez     t4, .Lvadd
  ecall

// mc_abort: core 1 fails after a delay while core 0 spins forever and the
// other cores wait at a barrier. The run must still end, reporting core 1.
ACCEL_KERNEL(mc_abort)
  csrr  t0, mhartid
  li    t1, 1
  beq   t0, t1, .Lfail
  beqz  t0, .Lspin
  barrier                    // cores 2.. wait here until the abort
  ecall
.Lspin:
  j     .Lspin
.Lfail:
  li    t2, 300
1:
  addi  t2, t2, -1
  bnez  t2, 1b
  .globl pc_mc_abort
pc_mc_abort:
  ebreak
