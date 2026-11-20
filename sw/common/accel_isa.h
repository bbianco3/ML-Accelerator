// accel_isa.h -- assembler support for writing accelerator kernels.
//
// Include this from a *preprocessed* assembly file (extension .S):
//
//     #include "accel_isa.h"
//     ACCEL_KERNEL(my_kernel)          // a0..a7 hold the host's ARG0..ARG7
//         vsetvl   t0, a0
//         vle16    v1, 0(a1)
//         vfadd.vv v2, v1, v1
//         vse16    v2, 0(a2)
//         ecall                        // done
//
// The scalar part of a kernel is plain RV32I and is assembled by the stock
// RISC-V GNU assembler. The accelerator extensions below are GNU-as macros
// that emit the encodings defined in docs/isa.md via `.insn`.
//
// Multi-core kernels: every launched core runs the same code. Use
//     csrr t0, mhartid        // this core's index 0 .. ncores-1
//     csrr t1, CSR_NCORES     // number of cores launched
//     barrier                 // wait for all launched cores
// Scratchpad: each core has a private SRAM at SPAD_BASE (memory_map.h),
// CSR_SPADSZ bytes. Every load/store/vle/vse/mld/mst works on it.
//
// Register names
//   v0..v31      vector registers (VLEN bits, VLEN/16 bf16 elements)
//   tr0..tr31    matrix tile registers (MAT_DIM x MAT_DIM bf16), NUM_TREGS exist
//   acc0..acc31  matrix accumulators  (MAT_DIM x MAT_DIM fp32), NUM_ACCS exist
// These are C-preprocessor aliases for x0..x31 (that is how the register
// number reaches the instruction field), so do not use them as label names.
//
// Keep this file in sync with hw/rtl/accel_pkg.sv.
#ifndef ACCEL_ISA_H
#define ACCEL_ISA_H

#ifndef __ASSEMBLER__
#error "accel_isa.h is for assembly (.S) files only"
#endif

#include "memory_map.h"

// Read-only kernel CSRs beyond the standard cycle/instret/mhartid
#define CSR_VL      0xC20     // current vl
#define CSR_VLENB   0xC22     // VLEN / 8
#define CSR_NCORES  0xFC0     // cores launched in this run
#define CSR_SPADSZ  0xFC1     // scratchpad bytes per core (0 = no scratchpad)
#define CSR_UNITS   0xFC2     // bit 0: this core has a VPU, bit 1: an MXU

// ---------------------------------------------------------------------------
// Register aliases
// ---------------------------------------------------------------------------
#define v0  x0
#define v1  x1
#define v2  x2
#define v3  x3
#define v4  x4
#define v5  x5
#define v6  x6
#define v7  x7
#define v8  x8
#define v9  x9
#define v10 x10
#define v11 x11
#define v12 x12
#define v13 x13
#define v14 x14
#define v15 x15
#define v16 x16
#define v17 x17
#define v18 x18
#define v19 x19
#define v20 x20
#define v21 x21
#define v22 x22
#define v23 x23
#define v24 x24
#define v25 x25
#define v26 x26
#define v27 x27
#define v28 x28
#define v29 x29
#define v30 x30
#define v31 x31

#define tr0 x0
#define tr1 x1
#define tr2 x2
#define tr3 x3
#define tr4 x4
#define tr5 x5
#define tr6 x6
#define tr7 x7

#define acc0 x0
#define acc1 x1
#define acc2 x2
#define acc3 x3
#define acc4 x4
#define acc5 x5
#define acc6 x6
#define acc7 x7

// Define a kernel entry point in HBM.
#define ACCEL_KERNEL(name)        \
  .section .accel.text, "ax";     \
  .balign 4;                      \
  .globl name;                    \
  .type name, @function;          \
  name:

// Element encoding (bf16.h). funct3 of the arithmetic and matrix
// instructions carries it: custom-0 {vf, enc[1:0]}, custom-2 {enc[1:0], .t}.
#ifndef ACCEL_NUMFMT
#define ACCEL_NUMFMT 0
#endif
#define F3_VV (0 + ACCEL_NUMFMT)
#define F3_VF (4 + ACCEL_NUMFMT)
#define F3_M  (2 * ACCEL_NUMFMT)
#define F3_MT (1 + 2 * ACCEL_NUMFMT)

// Handy bf16 constants for vmv.v.x / .vf operands (load with `li`).
#if ACCEL_NUMFMT == 1
#define BF16_ZERO     0x0000
#define BF16_ONE      0x3C00
#define BF16_NEG_ONE  0xBC00
#define BF16_HALF     0x3800
#define BF16_INF      0x7C00
#define BF16_NEG_INF  0xFC00
#elif ACCEL_NUMFMT == 2
#define BF16_ZERO     0x0000
#define BF16_ONE      0x0038
#define BF16_NEG_ONE  0x00B8
#define BF16_HALF     0x0030
#define BF16_INF      0x007E      // no infinity: +-448, the largest values
#define BF16_NEG_INF  0x00FE
#else
#define BF16_ZERO     0x0000
#define BF16_ONE      0x3F80
#define BF16_NEG_ONE  0xBF80
#define BF16_HALF     0x3F00
#define BF16_INF      0x7F80
#define BF16_NEG_INF  0xFF80
#endif

// ---------------------------------------------------------------------------
// custom-1 (0x2B): vector configuration and memory
// ---------------------------------------------------------------------------
// rd = vl = min(rs1, VLMAX); rs1 = zero means "VLMAX"
.macro vsetvl rd, rs1
  .insn i 0x2B, 0, \rd, \rs1, 0
.endm
// vd[i] = mem16[imm + rs1 + 2*i], i < vl. Address must be VLEN/8 aligned.
.macro vle16 vd, mem
  .insn i 0x2B, 1, \vd, \mem
.endm
// mem16[imm + rs1 + 2*i] = vs3[i], i < vl. Address must be VLEN/8 aligned.
.macro vse16 vs3, mem
  .insn s 0x2B, 2, \vs3, \mem
.endm

// ---------------------------------------------------------------------------
// custom-0 (0x0B): bf16 vector arithmetic.   .vv: op1 = vs1   .vf: op1 = x[rs1][15:0]
// ---------------------------------------------------------------------------
.macro vfadd.vv vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x00, \vd, \vs1, \vs2
.endm
.macro vfadd.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x00, \vd, \rs1, \vs2
.endm
.macro vfsub.vv vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x01, \vd, \vs1, \vs2
.endm
.macro vfsub.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x01, \vd, \rs1, \vs2
.endm
.macro vfmul.vv vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x02, \vd, \vs1, \vs2
.endm
.macro vfmul.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x02, \vd, \rs1, \vs2
.endm
.macro vfmax.vv vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x03, \vd, \vs1, \vs2
.endm
.macro vfmax.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x03, \vd, \rs1, \vs2
.endm
.macro vfmin.vv vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x04, \vd, \vs1, \vs2
.endm
.macro vfmin.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x04, \vd, \rs1, \vs2
.endm
// vd = vd + vs1 * vs2        (operand order as in RVV)
.macro vfmacc.vv vd, vs1, vs2
  .insn r 0x0B, F3_VV, 0x05, \vd, \vs1, \vs2
.endm
// vd = vd + x[rs1] * vs2
.macro vfmacc.vf vd, rs1, vs2
  .insn r 0x0B, F3_VF, 0x05, \vd, \rs1, \vs2
.endm
// vd[0] = vs1[0] + sum(vs2[0..vl-1])   (sequential fp32, rounded once)
.macro vfredsum.vs vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x08, \vd, \vs1, \vs2
.endm
// vd[0] = x[rs1] + sum(vs2[0..vl-1])
.macro vfredsum.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x08, \vd, \rs1, \vs2
.endm
// vd[0] = max(vs1[0], vs2[0..vl-1])
.macro vfredmax.vs vd, vs2, vs1
  .insn r 0x0B, F3_VV, 0x09, \vd, \vs1, \vs2
.endm
.macro vfredmax.vf vd, vs2, rs1
  .insn r 0x0B, F3_VF, 0x09, \vd, \rs1, \vs2
.endm
// vd[i] = vs1[i]           (i < vl)
.macro vmv.v.v vd, vs1
  .insn r 0x0B, F3_VV, 0x10, \vd, \vs1, x0
.endm
// vd[i] = x[rs1][15:0]     (i < vl)
.macro vmv.v.x vd, rs1
  .insn r 0x0B, F3_VF, 0x10, \vd, \rs1, x0
.endm
// x[rd] = zero_extend(vs2[0])
.macro vmv.x.s rd, vs2
  .insn r 0x0B, F3_VV, 0x11, \rd, x0, \vs2
.endm
// vd[0] = x[rs1][15:0]     (if vl > 0)
.macro vmv.s.x vd, rs1
  .insn r 0x0B, F3_VF, 0x12, \vd, \rs1, x0
.endm

// ---------------------------------------------------------------------------
// custom-2 (0x5B): matrix unit. Base address and row stride (in bytes) must
// both be multiples of MAT_DIM*2.
// ---------------------------------------------------------------------------
// tile[td] row r <- mem[base + r*stride], r = 0..MAT_DIM-1
.macro mld td, base, stride
  .insn r 0x5B, F3_M, 0x00, \td, \base, \stride
.endm
// tile[ts] row r -> mem[base + r*stride]
.macro mst ts, base, stride
  .insn r 0x5B, F3_M, 0x01, \ts, \base, \stride
.endm
// bf16(acc[as]) row r -> mem[base + r*stride]
.macro msta as, base, stride
  .insn r 0x5B, F3_M, 0x02, \as, \base, \stride
.endm
// Transposed (".t") forms: memory row r <-> register COLUMN r, i.e. the
// matrix is stored column-major in memory. Same alignment rules.
.macro mld.t td, base, stride
  .insn r 0x5B, F3_MT, 0x00, \td, \base, \stride
.endm
.macro mst.t ts, base, stride
  .insn r 0x5B, F3_MT, 0x01, \ts, \base, \stride
.endm
.macro msta.t as, base, stride
  .insn r 0x5B, F3_MT, 0x02, \as, \base, \stride
.endm
// acc[ad] = 0
.macro mzero ad
  .insn r 0x5B, F3_M, 0x03, \ad, x0, x0
.endm
// acc[ad] += tile[ta] x tile[tb]
.macro mmacc ad, ta, tb
  .insn r 0x5B, F3_M, 0x04, \ad, \ta, \tb
.endm

// ---------------------------------------------------------------------------
// custom-3 (0x7B): multi-core control
// ---------------------------------------------------------------------------
// Wait until every launched core is at a barrier or has finished. All
// memory operations before it are complete (the core is in-order and blocking).
.macro barrier
  .insn i 0x7B, 0, x0, x0, 0
.endm

// hcpy rdst, rsrc, rn: copy x[rn] bf16 elements (halfwords) from address
// x[rsrc] to address x[rdst]. Any 2-byte-aligned addresses, HBM or
// scratchpad. rdst is READ, not written. The regions must not overlap.
.macro hcpy rdst, rsrc, rn
  .insn r 0x7B, 1, 0x00, \rdst, \rsrc, \rn
.endm

// hcpy2d rdst, rsrc, rshape: x[rshape] = {stride[31:16], rows[15:8], run[7:0]}.
// Copies `rows` runs of `run` elements; run r starts at x[rsrc] + r*stride
// (bytes, even), and the runs are written back to back from x[rdst]. One
// im2col patch row in one instruction. rdst is READ, not written.
.macro hcpy2d rdst, rsrc, rshape
  .insn r 0x7B, 2, 0x00, \rdst, \rsrc, \rshape
.endm

#endif // ACCEL_ISA_H