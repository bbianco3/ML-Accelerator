// gemm_tiled/kernel.S -- C = relu(A x B) split into MAT_DIM x MAT_DIM tiles,
// spread over all launched cores, with the scratchpad as a tile buffer.
//
//   * Core c computes output column tiles j = c, c + ncores, c + 2*ncores, ...
//   * For each j it first copies the whole column panel B[:, j] (KT tiles)
//     from HBM into its scratchpad, stored "blocked" (each tile contiguous).
//     Every row tile i of C then reads B from the scratchpad (1 row/cycle)
//     instead of HBM (~40+ cycles/row): B is fetched from HBM once, not MT
//     times. (use_spad = 0 skips this and reads B from HBM, for comparison.)
//   * The output tile goes through the scratchpad too: msta (fp32 -> bf16),
//     ReLU with the vector unit, then one mst to C in HBM.
//
// Scratchpad layout: [C tile][B tile 0][B tile 1]...[B tile KT-1]
#include "accel_isa.h"

// gemm_tiled(a0 = struct gemm_params *p)    (layout: main.c)
ACCEL_KERNEL(gemm_tiled)
  csrr  s0, mhartid
  csrr  s1, CSR_NCORES
  lw    s2, 0(a0)          // A
  lw    s3, 4(a0)          // B
  lw    s4, 8(a0)          // C
  lw    s5, 12(a0)         // MT: row tiles
  lw    s6, 16(a0)         // NT: column tiles
  lw    s7, 20(a0)         // KT: k tiles
  lw    s8, 24(a0)         // lda (bytes per row)
  lw    s9, 28(a0)         // ldb
  lw    s10, 32(a0)        // ldc
  lw    s11, 36(a0)        // row bytes = MAT_DIM*2 = step to the next column tile
  li    a1, SPAD_BASE      // C tile buffer
  lw    t0, 40(a0)         // tile bytes
  add   a2, a1, t0         // B panel buffer

  // a3 = byte offset of column tile j = id * row_bytes, a4 = ncores * row_bytes
  li    a3, 0
  mv    t0, s0
  beqz  t0, 2f
1:
  add   a3, a3, s11
  addi  t0, t0, -1
  bnez  t0, 1b
2:
  li    a4, 0
  mv    t0, s1
3:
  add   a4, a4, s11
  addi  t0, t0, -1
  bnez  t0, 3b

  mv    a5, s0             // j
.Lj:
  bge   a5, s6, .Ldone
  lw    t0, 56(a0)         // use_spad
  beqz  t0, .Lno_stage

  // ---- stage B[:, j] into the scratchpad, one tile after another ----
  add   t1, s3, a3         // &B[0][j tile]
  mv    t2, a2
  mv    t3, s7
  lw    t4, 48(a0)         // b_rowtile = MAT_DIM * ldb
  lw    t5, 40(a0)         // tile bytes
.Lstage:
  mld   tr1, t1, s9        // from HBM, stride ldb
  mst   tr1, t2, s11       // to the scratchpad, contiguous
  add   t1, t1, t4
  add   t2, t2, t5
  addi  t3, t3, -1
  bnez  t3, .Lstage
  mv    a6, a2             // B tiles come from the scratchpad
  mv    a7, s11            //   rows are MAT_DIM*2 apart
  lw    gp, 40(a0)         //   tiles are tile_bytes apart
  j     .Lgo
.Lno_stage:
  add   a6, s3, a3         // B tiles come straight from HBM
  mv    a7, s9
  lw    gp, 48(a0)
.Lgo:
  mv    tp, s5             // i counter
  add   t5, s4, a3         // &C[i tile][j tile]
  mv    t4, s2             // &A[i tile][0]
.Li:
  mzero acc0
  mv    t0, t4             // &A[i tile][k tile]
  mv    t1, a6             // B tile k
  mv    t2, s7
.Lk:
  mld   tr0, t0, s8
  mld   tr1, t1, a7
  mmacc acc0, tr0, tr1
  add   t0, t0, s11
  add   t1, t1, gp
  addi  t2, t2, -1
  bnez  t2, .Lk

  // ---- epilogue in the scratchpad: C tile = relu(bf16(acc0)) ----
  msta  acc0, a1, s11
  lw    t2, 44(a0)         // MAT_DIM * MAT_DIM elements
  mv    t3, a1
.Lrelu:
  vsetvl   t0, t2
  vle16    v1, 0(t3)
  vfmax.vf v1, v1, zero    // max(x, +0.0)
  vse16    v1, 0(t3)
  slli     t1, t0, 1
  add      t3, t3, t1
  sub      t2, t2, t0
  bnez     t2, .Lrelu
  mld   tr0, a1, s11
  mst   tr0, t5, s10       // to C in HBM

  lw    t0, 52(a0)         // c_rowtile
  add   t5, t5, t0
  lw    t0, 60(a0)         // a_rowtile
  add   t4, t4, t0
  addi  tp, tp, -1
  bnez  tp, .Li

  add   a5, a5, s1         // next column tile for this core
  add   a3, a3, a4
  j     .Lj
.Ldone:
  ecall
