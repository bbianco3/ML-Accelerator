// scalar_ops/kernel.S -- exercises the accelerator control core's RV32I subset.
//
//   a0 = out    uint32_t results[] (HBM)
//   a1 = x, a2 = y   operands
//   a3 = in     byte pattern buffer (HBM), in[i] = (uint8_t)(0x80 + 7*i)
//   a7 = passthrough value (checks that ARG7 reaches a7)
#include "accel_isa.h"

ACCEL_KERNEL(scalar_ops_kernel)
  add   t0, a1, a2;      sw t0, 0(a0)
  sub   t0, a1, a2;      sw t0, 4(a0)
  and   t0, a1, a2;      sw t0, 8(a0)
  or    t0, a1, a2;      sw t0, 12(a0)
  xor   t0, a1, a2;      sw t0, 16(a0)
  sll   t0, a1, a2;      sw t0, 20(a0)
  srl   t0, a1, a2;      sw t0, 24(a0)
  sra   t0, a1, a2;      sw t0, 28(a0)
  slt   t0, a1, a2;      sw t0, 32(a0)
  sltu  t0, a1, a2;      sw t0, 36(a0)
  addi  t0, a1, -7;      sw t0, 40(a0)
  xori  t0, a1, 0x5a5;   sw t0, 44(a0)
  ori   t0, a1, -16;     sw t0, 48(a0)
  andi  t0, a1, 0x0f0;   sw t0, 52(a0)
  slti  t0, a1, -3;      sw t0, 56(a0)
  sltiu t0, a1, 5;       sw t0, 60(a0)
  slli  t0, a1, 7;       sw t0, 64(a0)
  srli  t0, a1, 5;       sw t0, 68(a0)
  srai  t0, a1, 3;       sw t0, 72(a0)
  lui   t0, 0xABCDE;     sw t0, 76(a0)
  .globl scalar_auipc_label
scalar_auipc_label:
  auipc t0, 0;           sw t0, 80(a0)

  // loads (sign / zero extension, sub-word lanes, second beat)
  lb    t0, 3(a3);       sw t0, 84(a0)
  lbu   t0, 3(a3);       sw t0, 88(a0)
  lh    t0, 6(a3);       sw t0, 92(a0)
  lhu   t0, 6(a3);       sw t0, 96(a0)
  lw    t0, 8(a3);       sw t0, 100(a0)
  lw    t0, 36(a3);      sw t0, 104(a0)

  // sub-word stores into one word
  li    t0, 0x11223344
  sw    t0, 108(a0)
  sb    a1, 108(a0)
  sh    a2, 110(a0)

  // branches -> bitmask
  li    t1, 0
  beq   a1, a1, 1f
  j     2f
1: ori  t1, t1, 1
2: bne  a1, a2, 1f
  j     2f
1: ori  t1, t1, 2
2: blt  a1, a2, 1f
  j     2f
1: ori  t1, t1, 4
2: bge  a1, a2, 1f
  j     2f
1: ori  t1, t1, 8
2: bltu a1, a2, 1f
  j     2f
1: ori  t1, t1, 16
2: bgeu a1, a2, 1f
  j     2f
1: ori  t1, t1, 32
2: sw   t1, 112(a0)

  // backward-branch loop: 10 + 9 + ... + 1
  li    t2, 10
  li    t3, 0
3: add  t3, t3, t2
  addi  t2, t2, -1
  bnez  t2, 3b
  sw    t3, 116(a0)

  // jal / jalr
  jal   ra, add100
  sw    a5, 120(a0)

  // read-only CSRs
  csrr  t0, 0xC22;       sw t0, 124(a0)     // vlenb
  csrr  t0, 0xC00;       sw t0, 128(a0)     // cycle
  csrr  t0, 0xC02;       sw t0, 132(a0)     // instret

  // writes to x0 are discarded
  addi  x0, x0, 5
  sw    x0, 136(a0)
  sw    a7, 140(a0)
  ecall

add100:
  addi  a5, a1, 100
  ret
