// layouts/kernel.S -- layout-agnostic tiled GEMM: C = A x B.
//
// a0 points at a parameter block (struct layout_gemm_params in main.c):
//   0  A descriptor   {base, rstep, cstep, stride, xpose}   (mat_tile_desc_t)
//  20  B descriptor
//  40  C descriptor
//  60  mt, 64 nt, 68 kt   (matrix size in tiles)
//
// Tile (i, j) of X lives at X.base + i*X.rstep + j*X.cstep and is moved with
// mld/mst/msta, or their .t forms when X.xpose is set. Because of that, the
// same kernel works for row-major, column-major and blocked matrices, in any
// combination.
#include "accel_isa.h"

// Load a tile, transposing if `flag` is non-zero.
.macro LOAD_TILE treg, addr, stride, flag
  beqz   \flag, 1f
  mld.t  \treg, \addr, \stride
  j      2f
1:
  mld    \treg, \addr, \stride
2:
.endm

// Store an accumulator as bf16, transposing if `flag` is non-zero.
.macro STORE_ACC areg, addr, stride, flag
  beqz   \flag, 1f
  msta.t \areg, \addr, \stride
  j      2f
1:
  msta   \areg, \addr, \stride
2:
.endm

ACCEL_KERNEL(layout_gemm_kernel)
  lw    s0,  0(a0)       // A.base
  lw    s1,  4(a0)       // A.rstep
  lw    s2,  8(a0)       // A.cstep
  lw    s3, 12(a0)       // A.stride
  lw    s4, 16(a0)       // A.xpose
  lw    s5, 20(a0)       // B.base
  lw    s6, 24(a0)       // B.rstep
  lw    s7, 28(a0)       // B.cstep
  lw    s8, 32(a0)       // B.stride
  lw    s9, 36(a0)       // B.xpose
  lw    a1, 40(a0)       // C.base
  lw    a2, 44(a0)       // C.rstep
  lw    a3, 48(a0)       // C.cstep
  lw    a4, 52(a0)       // C.stride
  lw    a5, 56(a0)       // C.xpose
  lw    s10, 60(a0)      // mt
  lw    s11, 64(a0)      // nt
  lw    t6, 68(a0)       // kt

  mv    t0, s10          // i counter
  mv    a6, s0           // A tile (i, 0)
  mv    a7, a1           // C tile (i, 0)
.Li:
  mv    t1, s11          // j counter
  mv    gp, s5           // B tile (0, j)
  mv    tp, a7           // C tile (i, j)
.Lj:
  mzero acc0
  mv    t2, t6           // k counter
  mv    t3, a6           // A tile (i, k)
  mv    t4, gp           // B tile (k, j)
.Lk:
  LOAD_TILE tr0, t3, s3, s4
  LOAD_TILE tr1, t4, s8, s9
  mmacc acc0, tr0, tr1
  add   t3, t3, s2       // A: next tile column
  add   t4, t4, s6       // B: next tile row
  addi  t2, t2, -1
  bnez  t2, .Lk
  STORE_ACC acc0, tp, a4, a5
  add   gp, gp, s7       // B: next tile column
  add   tp, tp, a3       // C: next tile column
  addi  t1, t1, -1
  bnez  t1, .Lj
  add   a6, a6, s1       // A: next tile row
  add   a7, a7, a2       // C: next tile row
  addi  t0, t0, -1
  bnez  t0, .Li
  ecall
