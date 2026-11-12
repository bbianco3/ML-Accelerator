// spad/kernel.S -- the per-core scratchpad (SPAD_BASE, memory_map.h).
//
// The scratchpad is ordinary memory for every load/store instruction: only
// the address decides whether HBM or the scratchpad is used.
#include "accel_isa.h"

// spad_basic(a0 = struct spad_params *p)    (layout: main.c)
ACCEL_KERNEL(spad_basic)
  lw    a1, 0(a0)            // out[]  (HBM, uint32 results)
  lw    a2, 4(a0)            // vector source (HBM, 2 x VLMAX bf16)
  lw    a3, 8(a0)            // vector destination (HBM, 2 x VLMAX bf16)
  lw    a4, 12(a0)           // matrix source (HBM, MAT_DIM x MAT_DIM, row-major)
  lw    a5, 16(a0)           // matrix destination (HBM)
  lw    a6, 20(a0)           // row bytes (MAT_DIM*2)
  lw    s0, 24(a0)           // scratchpad offset for the vectors
  lw    s1, 28(a0)           // scratchpad offset for the matrix (0 = skip)
  li    s2, SPAD_BASE

  // ---- configuration CSR ----
  csrr  t0, CSR_SPADSZ
  sw    t0, 0(a1)

  // ---- scalar accesses of every width ----
  li    t1, 0x12345678
  sw    t1, 0(s2)
  sw    zero, 4(s2)
  sw    zero, 8(s2)
  li    t1, 0xAB
  sb    t1, 5(s2)            // byte 5
  li    t1, 0xCDEF
  sh    t1, 10(s2)           // halfword at 10
  lw    t2, 0(s2);  sw t2, 4(a1)
  lw    t2, 4(s2);  sw t2, 8(a1)
  lb    t2, 5(s2);  sw t2, 12(a1)     // sign-extended
  lhu   t2, 10(s2); sw t2, 16(a1)
  lw    t2, 8(s2);  sw t2, 20(a1)

  // ---- vectors: HBM -> scratchpad -> HBM, plus a partial (vl < VLMAX) store ----
  add   s3, s2, s0           // vector area in the scratchpad
  csrr  t6, CSR_VLENB
  vsetvl t0, zero            // vl = VLMAX
  vle16 v1, 0(a2)
  vse16 v1, 0(s3)
  add   t1, a2, t6
  vle16 v2, 0(t1)
  add   t1, s3, t6
  vse16 v2, 0(t1)
  vle16 v3, 0(s3)            // read both back from the scratchpad
  vse16 v3, 0(a3)
  li    t0, 3
  vsetvl t0, t0              // vl = min(3, VLMAX)
  li    t2, BF16_ONE
  vmv.v.x v4, t2
  add   t1, s3, t6
  vse16 v4, 0(t1)            // overwrite the first vl elements only
  vsetvl t0, zero
  vle16 v5, 0(t1)
  add   t1, a3, t6
  vse16 v5, 0(t1)

  // ---- matrix: store a tile row-major, read it back transposed ----
  beqz  s1, 1f
  add   s4, s2, s1
  mld   tr0, a4, a6          // from HBM
  mst   tr0, s4, a6          // to the scratchpad
  mld.t tr1, s4, a6          // transposed load from the scratchpad
  mst   tr1, a5, a6          // to HBM: the transpose
1:
  ecall

// spad_timing(a0 = out, a1 = HBM tile, a2 = row bytes, a3 = scratchpad offset)
// out[0] = cycles for 4 tile loads from HBM, out[1] = same from the scratchpad
ACCEL_KERNEL(spad_timing)
  li    t0, SPAD_BASE
  add   a3, a3, t0
  csrr  t1, cycle
  mld   tr0, a1, a2
  mld   tr0, a1, a2
  mld   tr0, a1, a2
  mld   tr0, a1, a2
  csrr  t2, cycle
  mld   tr0, a3, a2
  mld   tr0, a3, a2
  mld   tr0, a3, a2
  mld   tr0, a3, a2
  csrr  t3, cycle
  sub   t4, t2, t1
  sw    t4, 0(a0)
  sub   t4, t3, t2
  sw    t4, 4(a0)
  ecall

// spad_sweep(a0 = out[32], a1 = scratchpad size): split the scratchpad into
// 16 regions, write a different word at the start and at the end of each,
// then read all 32 back -- catches address/bank decoding mistakes anywhere.
ACCEL_KERNEL(spad_sweep)
  li    t0, SPAD_BASE
  srli  t1, a1, 4            // region size
  li    t2, 0                // i
  li    t3, 16
  li    a2, 0xA0000000
  li    a3, 0xB0000000
  mv    t4, t0
1:
  add   t5, a2, t2
  sw    t5, 0(t4)
  add   t5, a3, t2
  add   t6, t4, t1
  sw    t5, -4(t6)
  add   t4, t4, t1
  addi  t2, t2, 1
  bne   t2, t3, 1b
  li    t2, 0
  mv    t4, t0
  mv    a4, a0
2:
  lw    t5, 0(t4)
  sw    t5, 0(a4)
  add   t6, t4, t1
  lw    t5, -4(t6)
  sw    t5, 4(a4)
  add   t4, t4, t1
  addi  a4, a4, 8
  addi  t2, t2, 1
  bne   t2, t3, 2b
  ecall

// spad_oob(a0 = scratchpad size): load just past the end -> bus error
ACCEL_KERNEL(spad_oob)
  li    t0, SPAD_BASE
  add   t0, t0, a0
  .globl pc_spad_oob
pc_spad_oob:
  lw    t1, 0(t0)
  ecall
