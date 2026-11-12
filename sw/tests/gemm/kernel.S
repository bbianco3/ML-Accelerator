// gemm/kernel.S -- tiled GEMM with an optional ReLU epilogue:
//
//     C[M][N] = relu( A[M][K] x B[K][N] )      (bf16 in/out, fp32 accumulate)
//
// M, N, K are multiples of MAT_DIM. The kernel walks output tiles (i, j),
// accumulates over k tiles in acc0, stores the bf16 tile, and finally runs
// the ReLU over the whole of C with the vector unit.
//
// Shows how to pass many arguments: a0 points at a parameter block in HBM
// that the kernel reads with scalar loads (struct gemm_params in main.c).
#include "accel_isa.h"

ACCEL_KERNEL(gemm_kernel)
  lw    s0,  0(a0)        // A
  lw    s1,  4(a0)        // B
  lw    s2,  8(a0)        // C
  lw    s3, 12(a0)        // number of row tiles    (M / MAT_DIM)
  lw    s4, 16(a0)        // number of column tiles (N / MAT_DIM)
  lw    s5, 20(a0)        // number of k tiles      (K / MAT_DIM)
  lw    s6, 24(a0)        // lda  (bytes per row of A)
  lw    s7, 28(a0)        // ldb
  lw    s8, 32(a0)        // ldc
  lw    s9, 36(a0)        // MAT_DIM * lda : step to the next row tile of A
  lw    s10, 40(a0)       // MAT_DIM * ldb : step to the next row tile of B
  lw    s11, 44(a0)       // MAT_DIM * ldc : step to the next row tile of C
  lw    t6, 48(a0)        // MAT_DIM * 2   : step to the next column tile

  mv    t0, s3            // i counter
  mv    a1, s0            // &A[i tile][0]
  mv    a2, s2            // &C[i tile][0]
.Li:
  mv    t1, s4            // j counter
  mv    a3, s1            // &B[0][j tile]
  mv    a4, a2            // &C[i tile][j tile]
.Lj:
  mzero acc0
  mv    t2, s5            // k counter
  mv    a5, a1            // &A[i tile][k tile]
  mv    a6, a3            // &B[k tile][j tile]
.Lk:
  mld   tr0, a5, s6
  mld   tr1, a6, s7
  mmacc acc0, tr0, tr1
  add   a5, a5, t6
  add   a6, a6, s10
  addi  t2, t2, -1
  bnez  t2, .Lk
  msta  acc0, a4, s8
  add   a3, a3, t6
  add   a4, a4, t6
  addi  t1, t1, -1
  bnez  t1, .Lj
  add   a1, a1, s9
  add   a2, a2, s11
  addi  t0, t0, -1
  bnez  t0, .Li

  // ---- ReLU epilogue over the M*N contiguous outputs ----
  lw    t0, 52(a0)        // number of elements
  lw    t1, 56(a0)        // relu enable
  beqz  t1, .Ldone
  mv    a1, s2
.Lr:
  vsetvl   t2, t0
  vle16    v1, 0(a1)
  vfmax.vf v1, v1, zero   // max(x, +0.0)
  vse16    v1, 0(a1)
  sub      t0, t0, t2
  slli     t3, t2, 1
  add      a1, a1, t3
  bnez     t0, .Lr
.Ldone:
  ecall
