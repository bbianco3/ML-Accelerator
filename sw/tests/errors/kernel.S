// errors/kernel.S -- kernels that deliberately fault, one per error cause.
// Each faulting instruction has a global label so the host can check ERR_PC.
#include "accel_isa.h"

ACCEL_KERNEL(k_ebreak)
  nop
  .globl pc_ebreak
pc_ebreak:
  ebreak

ACCEL_KERNEL(k_misaligned_vle)
  addi  a0, a0, 2
  .globl pc_misaligned_vle
pc_misaligned_vle:
  vle16 v1, 0(a0)           // a0 is not VLEN/8 aligned
  ecall

ACCEL_KERNEL(k_misaligned_lw)
  .globl pc_misaligned_lw
pc_misaligned_lw:
  lw    t0, 2(a0)
  ecall

ACCEL_KERNEL(k_misaligned_mld)
  li    t1, 64
  .globl pc_misaligned_mld
pc_misaligned_mld:
  mld   tr0, a0, a1         // a1 (stride) is not a multiple of MAT_DIM*2
  ecall

ACCEL_KERNEL(k_illegal)
  .globl pc_illegal
pc_illegal:
  .insn r 0x33, 0, 1, a0, a1, a2   // = mul a0, a1, a2: no M extension on the accelerator (and not in KERNEL_MARCH, hence .insn)
  ecall

ACCEL_KERNEL(k_bus)
  li    t0, 0x00000100      // outside the HBM window -> DECERR
  .globl pc_bus
pc_bus:
  lw    t1, 0(t0)
  ecall

ACCEL_KERNEL(k_bad_reg)
  .globl pc_bad_reg
pc_bad_reg:
  mmacc acc7, tr0, tr1      // acc7 >= NUM_ACCS
  ecall

// Runs fine: proves the accelerator recovers after errors.
ACCEL_KERNEL(k_ok)
  li    t0, 42
  sw    t0, 0(a0)
  ecall
