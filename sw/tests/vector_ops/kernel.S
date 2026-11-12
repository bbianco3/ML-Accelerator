// vector_ops/kernel.S -- executes every vector instruction once.
//
//   a0 = A      input vector (VLMAX elements)
//   a1 = B      input vector
//   a2 = C      "background" vector: copied into the destination before each
//               op, so the host can check that tail elements are undisturbed
//   a3 = out    NUM_BLOCKS output blocks of VLMAX elements each
//   a4 = s      bf16 scalar operand (low 16 bits)
//   a5 = avl    requested vector length for the operations
//   a6 = sout   scalar results (uint32_t[4])
//
// Each output block is stored with vl = VLMAX so the whole register
// (including the tail) is visible to the host.
#include "accel_isa.h"

// Copy C into v10 with vl = VLMAX, then restore the requested vl.
.macro RESET_DST
  vsetvl  t1, zero
  vmv.v.v v10, v9
  vsetvl  t0, a5
.endm

// Store the full v10 into the next output block.
.macro STORE_DST
  vsetvl  t1, zero
  vse16   v10, 0(a3)
  add     a3, a3, t6
  vsetvl  t0, a5
.endm

ACCEL_KERNEL(vector_ops_kernel)
  csrr    t6, 0xC22               // vlenb = VLEN/8 = block size in bytes
  vsetvl  t1, zero
  vle16   v1, 0(a0)               // A
  vle16   v2, 0(a1)               // B
  vle16   v9, 0(a2)               // C
  vsetvl  t0, a5

  RESET_DST; vfadd.vv    v10, v1, v2;  STORE_DST     //  0: A + B
  RESET_DST; vfsub.vv    v10, v1, v2;  STORE_DST     //  1: A - B
  RESET_DST; vfmul.vv    v10, v1, v2;  STORE_DST     //  2: A * B
  RESET_DST; vfmax.vv    v10, v1, v2;  STORE_DST     //  3: max(A, B)
  RESET_DST; vfmin.vv    v10, v1, v2;  STORE_DST     //  4: min(A, B)
  RESET_DST; vfmacc.vv   v10, v2, v1;  STORE_DST     //  5: C + A*B
  RESET_DST; vfadd.vf    v10, v1, a4;  STORE_DST     //  6: A + s
  RESET_DST; vfsub.vf    v10, v1, a4;  STORE_DST     //  7: A - s
  RESET_DST; vfmul.vf    v10, v1, a4;  STORE_DST     //  8: A * s
  RESET_DST; vfmax.vf    v10, v1, a4;  STORE_DST     //  9: max(A, s)
  RESET_DST; vfmin.vf    v10, v1, a4;  STORE_DST     // 10: min(A, s)
  RESET_DST; vfmacc.vf   v10, a4, v1;  STORE_DST     // 11: C + s*A
  RESET_DST; vfredsum.vs v10, v1, v2;  STORE_DST     // 12: [0] = B[0] + sum(A)
  RESET_DST; vfredmax.vs v10, v1, v2;  STORE_DST     // 13: [0] = max(B[0], A...)
  RESET_DST; vfredsum.vf v10, v1, a4;  STORE_DST     // 14: [0] = s + sum(A)
  RESET_DST; vfredmax.vf v10, v1, a4;  STORE_DST     // 15: [0] = max(s, A...)
  RESET_DST; vmv.v.v     v10, v1;      STORE_DST     // 16: A
  RESET_DST; vmv.v.x     v10, a4;      STORE_DST     // 17: s
  RESET_DST; vmv.s.x     v10, a4;      STORE_DST     // 18: [0] = s
  RESET_DST; vfadd.vv    v10, v10, v1; STORE_DST     // 19: C + A (vd aliases vs2)

  vmv.x.s t2, v1                  // A[0]
  sw      t2, 0(a6)
  vmv.x.s t2, v10                 // result of block 19, element 0
  sw      t2, 4(a6)
  csrr    t3, 0xC20               // vl
  sw      t3, 8(a6)
  li      t4, 100000
  vsetvl  t5, t4                  // saturates at VLMAX
  sw      t5, 12(a6)
  ecall
