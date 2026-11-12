// matmul/kernel.S -- single-tile matrix multiply on the matrix unit.
//
//   C = bf16( A0 x B0 + A1 x B1 )        (fp32 accumulation in acc1)
//   T = A1                               (tile store round trip)
//
//   a0 = A0, a1 = B0, a2 = A1, a3 = B1   MAT_DIM x MAT_DIM bf16 tiles
//   a4 = C,  a6 = T                      MAT_DIM x MAT_DIM bf16 outputs
//   a5 = row stride in bytes (shared by all operands; multiple of MAT_DIM*2)
#include "accel_isa.h"

ACCEL_KERNEL(matmul_kernel)
  mld    tr0, a0, a5
  mld    tr1, a1, a5
  mld    tr2, a2, a5
  mld    tr3, a3, a5
  mzero  acc1
  mmacc  acc1, tr0, tr1
  mmacc  acc1, tr2, tr3
  msta   acc1, a4, a5
  mst    tr2, a6, a5
  ecall
