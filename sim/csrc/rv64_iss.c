// rv64_iss.c -- RV64G instruction-set simulator for the simulated host CPU.
//
// Functional model only: after every retired instruction, c->ev describes what
// it did (class, memory address, branch outcome). sim/csrc/host_model.c turns
// those events into time (2 GHz core) and energy.
//
// Implemented: RV64I, M, A (single hart), F, D, Zicsr, Zifencei, machine-mode
// traps (mtvec direct mode), external interrupt (mip.MEIP), WFI, MRET.
// Not implemented: C (compressed), S/U modes, virtual memory, PMP, misaligned
// traps (misaligned RAM accesses simply work).
//
// Floating point is executed with the host's IEEE arithmetic. Rounding modes
// and exception flags are mapped onto <fenv.h>; RMM is approximated by RNE.
// Build with -frounding-math and without -ffast-math.
#include "rv64_iss.h"

#include <fenv.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#pragma STDC FENV_ACCESS ON

// ---- CSR / bit definitions --------------------------------------------------
#define MSTATUS_MIE   (1ull << 3)
#define MSTATUS_MPIE  (1ull << 7)
#define MSTATUS_MPP   (3ull << 11)
#define MSTATUS_FS    (3ull << 13)
#define MIP_MEIP      (1ull << 11)
#define MISA_VALUE    ((2ull << 62) | (1u << 0) | (1u << 3) | (1u << 5) | (1u << 8) | (1u << 12))

#define CAUSE_FETCH_FAULT   1ull
#define CAUSE_ILLEGAL       2ull
#define CAUSE_BREAKPOINT    3ull
#define CAUSE_LOAD_FAULT    5ull
#define CAUSE_STORE_FAULT   7ull
#define CAUSE_ECALL_M       11ull
#define CAUSE_MEI           ((1ull << 63) | 11ull)

#define FFLAG_NX 0x01u
#define FFLAG_UF 0x02u
#define FFLAG_OF 0x04u
#define FFLAG_DZ 0x08u
#define FFLAG_NV 0x10u

#define F32_CANON 0x7FC00000u
#define F64_CANON 0x7FF8000000000000ull

// ---- field extraction -------------------------------------------------------
#define RD(i)     (((i) >> 7) & 0x1F)
#define RS1(i)    (((i) >> 15) & 0x1F)
#define RS2(i)    (((i) >> 20) & 0x1F)
#define RS3(i)    (((i) >> 27) & 0x1F)
#define FUNCT3(i) (((i) >> 12) & 0x7)
#define FUNCT7(i) (((i) >> 25) & 0x7F)

static inline int64_t imm_i(uint32_t i) { return (int32_t)i >> 20; }
static inline int64_t imm_s(uint32_t i) {
  return ((int32_t)(i & 0xFE000000u) >> 20) | (int32_t)((i >> 7) & 0x1F);
}
static inline int64_t imm_b(uint32_t i) {
  return ((int32_t)(i & 0x80000000u) >> 19) | (int32_t)((i & 0x80u) << 4) |
         (int32_t)((i >> 20) & 0x7E0u) | (int32_t)((i >> 7) & 0x1Eu);
}
static inline int64_t imm_j(uint32_t i) {
  return ((int32_t)(i & 0x80000000u) >> 11) | (int32_t)(i & 0xFF000u) |
         (int32_t)((i >> 9) & 0x800u) | (int32_t)((i >> 20) & 0x7FEu);
}

// ---- helpers ----------------------------------------------------------------
#define SEXT32(v) ((uint64_t)(int64_t)(int32_t)(uint32_t)(v))
static void logf_(rv64_cpu_t *c, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#include <stdarg.h>
static void logf_(rv64_cpu_t *c, const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  if (c->bus.log) c->bus.log(c->bus.ctx, buf);
  else fputs(buf, stdout);
}

static inline void wr_x(rv64_cpu_t *c, int rd, uint64_t v) {
  if (rd) c->x[rd] = v;
}

// Take a synchronous exception or interrupt.
static iss_status_t trap(rv64_cpu_t *c, uint64_t cause, uint64_t tval) {
  c->lr_valid = 0;
  if (c->mtvec == 0) {
    snprintf(c->fatal_msg, sizeof c->fatal_msg,
             "unhandled exception: mcause=%llu mtval=0x%llx pc=0x%llx (no mtvec installed)",
             (unsigned long long)(cause & 0xFF), (unsigned long long)tval, (unsigned long long)c->pc);
    return ISS_FATAL;
  }
  c->mepc   = c->pc;
  c->mcause = cause;
  c->mtval  = tval;
  uint64_t mie = (c->mstatus & MSTATUS_MIE) ? MSTATUS_MPIE : 0;
  c->mstatus = (c->mstatus & ~(MSTATUS_MIE | MSTATUS_MPIE)) | mie | MSTATUS_MPP;
  c->pc = c->mtvec & ~3ull;
  c->ev.cls = EV_TRAP;
  return ISS_OK;
}

// ---- FP register access -------------------------------------------------------
static inline uint32_t f_get32(rv64_cpu_t *c, int r) {
  uint64_t v = c->f[r];
  return ((v >> 32) == 0xFFFFFFFFu) ? (uint32_t)v : F32_CANON;  // NaN-boxing
}
static inline void f_set32(rv64_cpu_t *c, int r, uint32_t v) {
  c->f[r] = 0xFFFFFFFF00000000ull | v;
}
static inline float f_gets(rv64_cpu_t *c, int r) {
  uint32_t u = f_get32(c, r);
  float f;
  memcpy(&f, &u, 4);
  return f;
}
static inline void f_sets(rv64_cpu_t *c, int r, float f) {
  uint32_t u;
  if (isnan(f)) u = F32_CANON;
  else memcpy(&u, &f, 4);
  f_set32(c, r, u);
}
static inline double f_getd(rv64_cpu_t *c, int r) {
  double d;
  memcpy(&d, &c->f[r], 8);
  return d;
}
static inline void f_setd(rv64_cpu_t *c, int r, double d) {
  uint64_t u;
  if (isnan(d)) u = F64_CANON;
  else memcpy(&u, &d, 8);
  c->f[r] = u;
}

static inline int f32_issnan(uint32_t u) {
  return ((u & 0x7F800000u) == 0x7F800000u) && (u & 0x7FFFFFu) && !(u & 0x400000u);
}
static inline int f64_issnan(uint64_t u) {
  return ((u & 0x7FF0000000000000ull) == 0x7FF0000000000000ull) &&
         (u & 0xFFFFFFFFFFFFFull) && !(u & 0x8000000000000ull);
}

// Set host rounding mode from an instruction's rm field. Returns 0 if illegal.
static int fp_begin(rv64_cpu_t *c, uint32_t rm) {
  if (rm == 7) rm = (c->fcsr >> 5) & 7;
  int mode;
  switch (rm) {
    case 0: mode = FE_TONEAREST;  break;
    case 1: mode = FE_TOWARDZERO; break;
    case 2: mode = FE_DOWNWARD;   break;
    case 3: mode = FE_UPWARD;     break;
    case 4: mode = FE_TONEAREST;  break;   // RMM approximated
    default: return 0;
  }
  fesetround(mode);
  feclearexcept(FE_ALL_EXCEPT);
  return 1;
}

static void fp_end(rv64_cpu_t *c, uint32_t extra) {
  int e = fetestexcept(FE_ALL_EXCEPT);
  uint32_t fl = extra;
  if (e & FE_INVALID)   fl |= FFLAG_NV;
  if (e & FE_DIVBYZERO) fl |= FFLAG_DZ;
  if (e & FE_OVERFLOW)  fl |= FFLAG_OF;
  if (e & FE_UNDERFLOW) fl |= FFLAG_UF;
  if (e & FE_INEXACT)   fl |= FFLAG_NX;
  c->fcsr |= fl;
  fesetround(FE_TONEAREST);
}

// float/double -> integer with RISC-V saturation semantics.
// kind: 0 = int32, 1 = uint32, 2 = int64, 3 = uint64. Result is XLEN-extended.
static uint64_t cvt_to_int(double v, int kind, uint32_t *fl) {
  static const uint64_t nan_or_pos[4] = {0x7FFFFFFFull, 0xFFFFFFFFFFFFFFFFull,
                                         0x7FFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull};
  if (isnan(v)) { *fl |= FFLAG_NV; return nan_or_pos[kind]; }
  double r = nearbyint(v);
  switch (kind) {
    case 0:
      if (r > 2147483647.0)  { *fl |= FFLAG_NV; return 0x7FFFFFFFull; }
      if (r < -2147483648.0) { *fl |= FFLAG_NV; return SEXT32(0x80000000u); }
      if (r != v) *fl |= FFLAG_NX;
      return SEXT32((int32_t)r);
    case 1:
      if (r > 4294967295.0) { *fl |= FFLAG_NV; return 0xFFFFFFFFFFFFFFFFull; }
      if (r < 0.0)          { *fl |= FFLAG_NV; return 0; }
      if (r != v) *fl |= FFLAG_NX;
      return SEXT32((uint32_t)r);
    case 2:
      if (r >= 9223372036854775808.0) { *fl |= FFLAG_NV; return 0x7FFFFFFFFFFFFFFFull; }
      if (r < -9223372036854775808.0) { *fl |= FFLAG_NV; return 0x8000000000000000ull; }
      if (r != v) *fl |= FFLAG_NX;
      return (uint64_t)(int64_t)r;
    default:
      if (r >= 18446744073709551616.0) { *fl |= FFLAG_NV; return 0xFFFFFFFFFFFFFFFFull; }
      if (r < 0.0)                     { *fl |= FFLAG_NV; return 0; }
      if (r != v) *fl |= FFLAG_NX;
      return (uint64_t)r;
  }
}

static uint32_t fclass32(uint32_t u) {
  uint32_t s = u >> 31, e = (u >> 23) & 0xFF, m = u & 0x7FFFFF;
  if (e == 0xFF) {
    if (m == 0) return s ? (1u << 0) : (1u << 7);
    return (m & 0x400000u) ? (1u << 9) : (1u << 8);
  }
  if (e == 0) {
    if (m == 0) return s ? (1u << 3) : (1u << 4);
    return s ? (1u << 2) : (1u << 5);
  }
  return s ? (1u << 1) : (1u << 6);
}

static uint32_t fclass64(uint64_t u) {
  uint32_t s = (uint32_t)(u >> 63), e = (uint32_t)((u >> 52) & 0x7FF);
  uint64_t m = u & 0xFFFFFFFFFFFFFull;
  if (e == 0x7FF) {
    if (m == 0) return s ? (1u << 0) : (1u << 7);
    return (m & 0x8000000000000ull) ? (1u << 9) : (1u << 8);
  }
  if (e == 0) {
    if (m == 0) return s ? (1u << 3) : (1u << 4);
    return s ? (1u << 2) : (1u << 5);
  }
  return s ? (1u << 1) : (1u << 6);
}

// RISC-V fmin/fmax: NaN loses unless both are NaN; -0 < +0.
static double fminmax(double a, double b, int is_max, int a_snan, int b_snan, uint32_t *fl) {
  if (a_snan || b_snan) *fl |= FFLAG_NV;
  if (isnan(a) && isnan(b)) return NAN;
  if (isnan(a)) return b;
  if (isnan(b)) return a;
  if (a == b) {  // handles +0 / -0
    int an = signbit(a) != 0;
    if (is_max) return an ? b : a;
    return an ? a : b;
  }
  return is_max ? (a > b ? a : b) : (a < b ? a : b);
}

// ---- CSRs ---------------------------------------------------------------------
static int csr_read(rv64_cpu_t *c, uint32_t csr, uint64_t *v) {
  switch (csr) {
    case 0x001: *v = c->fcsr & 0x1F; return 1;
    case 0x002: *v = (c->fcsr >> 5) & 7; return 1;
    case 0x003: *v = c->fcsr & 0xFF; return 1;
    case 0x300: *v = c->mstatus; return 1;
    case 0x301: *v = MISA_VALUE; return 1;
    case 0x304: *v = c->mie; return 1;
    case 0x305: *v = c->mtvec; return 1;
    case 0x340: *v = c->mscratch; return 1;
    case 0x341: *v = c->mepc; return 1;
    case 0x342: *v = c->mcause; return 1;
    case 0x343: *v = c->mtval; return 1;
    case 0x344: *v = c->mip; return 1;
    case 0xB00: case 0xC00: case 0xC01: *v = c->cycle; return 1;
    case 0xB02: case 0xC02: *v = c->instret; return 1;
    case 0xF11: case 0xF12: case 0xF13: case 0xF14: *v = 0; return 1;
    default: return 0;
  }
}

static int csr_write(rv64_cpu_t *c, uint32_t csr, uint64_t v) {
  switch (csr) {
    case 0x001: c->fcsr = (c->fcsr & ~0x1Fu) | (uint32_t)(v & 0x1F); return 1;
    case 0x002: c->fcsr = (c->fcsr & 0x1F) | (uint32_t)((v & 7) << 5); return 1;
    case 0x003: c->fcsr = (uint32_t)(v & 0xFF); return 1;
    case 0x300: c->mstatus = v & (MSTATUS_MIE | MSTATUS_MPIE | MSTATUS_MPP | MSTATUS_FS); return 1;
    case 0x301: return 1;                       // misa is read-only here
    case 0x304: c->mie = v & MIP_MEIP; return 1;
    case 0x305: c->mtvec = v & ~3ull; return 1;   // direct mode only
    case 0x340: c->mscratch = v; return 1;
    case 0x341: c->mepc = v & ~3ull; return 1;
    case 0x342: c->mcause = v; return 1;
    case 0x343: c->mtval = v; return 1;
    case 0x344: return 1;                       // MEIP is driven by the platform
    case 0xB00: case 0xB02: return 1;                       // ignore counter writes
    default: return 0;
  }
}

// ---- public API -----------------------------------------------------------------
void rv64_init(rv64_cpu_t *c, uint64_t pc, rv64_bus_t bus) {
  memset(c, 0, sizeof *c);
  c->pc = pc;
  c->bus = bus;
  c->mstatus = MSTATUS_MPP;
}

void rv64_set_meip(rv64_cpu_t *c, int level) {
  if (level) c->mip |= MIP_MEIP;
  else       c->mip &= ~MIP_MEIP;
}

#define ILLEGAL() return trap(c, CAUSE_ILLEGAL, insn)

// Bus helpers that turn platform results into ISS control flow.
#define LOAD(ad_, size, dst)                                                   \
  do {                                                                          \
    mem_status_t _r = c->bus.load(c->bus.ctx, (ad_), (size), (dst));           \
    if (_r == MEM_PENDING) return ISS_PENDING;                                  \
    if (_r != MEM_OK) return trap(c, CAUSE_LOAD_FAULT, (ad_));                 \
    c->ev.mem = EV_MEM_LOAD; c->ev.addr = (ad_);                               \
  } while (0)

#define STORE(ad_, size, val)                                                  \
  do {                                                                          \
    mem_status_t _r = c->bus.store(c->bus.ctx, (ad_), (size), (val));          \
    if (_r == MEM_PENDING) return ISS_PENDING;                                  \
    if (_r == MEM_EXIT) { c->pc = npc; c->instret++; return ISS_EXIT; }        \
    if (_r != MEM_OK) return trap(c, CAUSE_STORE_FAULT, (ad_));                \
    c->ev.mem = EV_MEM_STORE; c->ev.addr = (ad_);                              \
  } while (0)

static inline uint64_t mulhu64(uint64_t a, uint64_t b) {
  return (uint64_t)(((unsigned __int128)a * b) >> 64);
}
static inline uint64_t mulh64(int64_t a, int64_t b) {
  return (uint64_t)(((__int128)a * b) >> 64);
}
static inline uint64_t mulhsu64(int64_t a, uint64_t b) {
  return (uint64_t)(((__int128)a * (__int128)b) >> 64);
}

iss_status_t rv64_step(rv64_cpu_t *c) {
  memset(&c->ev, 0, sizeof c->ev);
  c->ev.pc = c->pc;

  // ---- interrupts ----
  if ((c->mstatus & MSTATUS_MIE) && (c->mie & c->mip & MIP_MEIP))
    return trap(c, CAUSE_MEI, 0);

  // ---- fetch ----
  uint32_t insn;
  {
    uint64_t w = 0;
    mem_status_t r = c->bus.load(c->bus.ctx, c->pc, 4, &w);
    if (r != MEM_OK) return trap(c, CAUSE_FETCH_FAULT, c->pc);
    insn = (uint32_t)w;
  }
  if (c->trace) logf_(c, "[host] pc=%016llx insn=%08x", (unsigned long long)c->pc, insn);

  const uint64_t pc  = c->pc;
  uint64_t       npc = pc + 4;
  const int rd = RD(insn), rs1 = RS1(insn), rs2 = RS2(insn);
  const uint64_t a = c->x[rs1], b = c->x[rs2];
  const uint32_t f3 = FUNCT3(insn), f7 = FUNCT7(insn);

  switch (insn & 0x7F) {
    // ======================= RV64I =======================
    case 0x37: wr_x(c, rd, SEXT32(insn & 0xFFFFF000u)); break;          // LUI
    case 0x17: wr_x(c, rd, pc + SEXT32(insn & 0xFFFFF000u)); break;     // AUIPC
    case 0x6F:                                                          // JAL
      wr_x(c, rd, npc); npc = pc + imm_j(insn);
      c->ev.cls = EV_JUMP;
      break;
    case 0x67:                                                          // JALR
      if (f3 != 0) ILLEGAL();
      { uint64_t t = (a + imm_i(insn)) & ~1ull; wr_x(c, rd, npc); npc = t; }
      c->ev.cls = EV_JUMP;
      c->ev.indirect = 1;
      c->ev.is_ret = (rd == 0 && rs1 == 1);
      break;
    case 0x63: {                                                        // BRANCH
      int taken;
      switch (f3) {
        case 0: taken = a == b; break;
        case 1: taken = a != b; break;
        case 4: taken = (int64_t)a < (int64_t)b; break;
        case 5: taken = (int64_t)a >= (int64_t)b; break;
        case 6: taken = a < b; break;
        case 7: taken = a >= b; break;
        default: ILLEGAL();
      }
      if (taken) npc = pc + imm_b(insn);
      c->ev.cls = EV_BRANCH;
      c->ev.taken = taken;
      break;
    }
    case 0x03: {                                                        // LOAD
      uint64_t addr = a + imm_i(insn), v = 0;
      switch (f3) {
        case 0: LOAD(addr, 1, &v); v = (uint64_t)(int64_t)(int8_t)v;  break;
        case 1: LOAD(addr, 2, &v); v = (uint64_t)(int64_t)(int16_t)v; break;
        case 2: LOAD(addr, 4, &v); v = SEXT32(v); break;
        case 3: LOAD(addr, 8, &v); break;
        case 4: LOAD(addr, 1, &v); v &= 0xFF;   break;
        case 5: LOAD(addr, 2, &v); v &= 0xFFFF; break;
        case 6: LOAD(addr, 4, &v); v &= 0xFFFFFFFFull; break;
        default: ILLEGAL();
      }
      wr_x(c, rd, v);
      c->ev.cls = EV_LOAD;
      break;
    }
    case 0x23: {                                                        // STORE
      uint64_t addr = a + imm_s(insn);
      switch (f3) {
        case 0: STORE(addr, 1, b & 0xFF);   break;
        case 1: STORE(addr, 2, b & 0xFFFF); break;
        case 2: STORE(addr, 4, b & 0xFFFFFFFFull); break;
        case 3: STORE(addr, 8, b);          break;
        default: ILLEGAL();
      }
      c->ev.cls = EV_STORE;
      break;
    }
    case 0x13: {                                                        // OP-IMM
      int64_t im = imm_i(insn);
      uint32_t sh = (insn >> 20) & 0x3F, f6 = insn >> 26;
      uint64_t v;
      switch (f3) {
        case 0: v = a + (uint64_t)im; break;
        case 1: if (f6) ILLEGAL(); v = a << sh; break;
        case 2: v = (int64_t)a < im; break;
        case 3: v = a < (uint64_t)im; break;
        case 4: v = a ^ (uint64_t)im; break;
        case 5:
          if (f6 == 0x10) v = (uint64_t)((int64_t)a >> sh);
          else if (f6 == 0) v = a >> sh;
          else ILLEGAL();
          break;
        case 6: v = a | (uint64_t)im; break;
        default: v = a & (uint64_t)im; break;
      }
      wr_x(c, rd, v);
      break;
    }
    case 0x1B: {                                                        // OP-IMM-32
      uint32_t sh = rs2, aw = (uint32_t)a, v;
      switch (f3) {
        case 0: v = aw + (uint32_t)imm_i(insn); break;                  // ADDIW
        case 1: if (f7) ILLEGAL(); v = aw << sh; break;                 // SLLIW
        case 5:
          if (f7 == 0x20) v = (uint32_t)((int32_t)aw >> sh);            // SRAIW
          else if (f7 == 0) v = aw >> sh;                               // SRLIW
          else ILLEGAL();
          break;
        default: ILLEGAL();
      }
      wr_x(c, rd, SEXT32(v));
      break;
    }
    case 0x33: {                                                        // OP
      uint64_t v;
      if (f7 == 0x01) {                                                 // M extension
        const uint64_t int_min = 0x8000000000000000ull;
        switch (f3) {
          case 0: v = a * b; break;
          case 1: v = mulh64((int64_t)a, (int64_t)b); break;
          case 2: v = mulhsu64((int64_t)a, b); break;
          case 3: v = mulhu64(a, b); break;
          case 4:
            if (b == 0) v = ~0ull;
            else if (a == int_min && b == ~0ull) v = a;
            else v = (uint64_t)((int64_t)a / (int64_t)b);
            break;
          case 5: v = b ? a / b : ~0ull; break;
          case 6:
            if (b == 0) v = a;
            else if (a == int_min && b == ~0ull) v = 0;
            else v = (uint64_t)((int64_t)a % (int64_t)b);
            break;
          default: v = b ? a % b : a; break;
        }
        c->ev.cls = (f3 < 4) ? EV_MUL : EV_DIV;
      } else if (f7 == 0x00 || f7 == 0x20) {
        if (f7 == 0x20 && f3 != 0 && f3 != 5) ILLEGAL();
        switch (f3) {
          case 0: v = f7 ? a - b : a + b; break;
          case 1: v = a << (b & 0x3F); break;
          case 2: v = (int64_t)a < (int64_t)b; break;
          case 3: v = a < b; break;
          case 4: v = a ^ b; break;
          case 5: v = f7 ? (uint64_t)((int64_t)a >> (b & 0x3F)) : a >> (b & 0x3F); break;
          case 6: v = a | b; break;
          default: v = a & b; break;
        }
      } else {
        ILLEGAL();
      }
      wr_x(c, rd, v);
      break;
    }
    case 0x3B: {                                                        // OP-32
      uint32_t aw = (uint32_t)a, bw = (uint32_t)b, v;
      if (f7 == 0x01) {                                                 // M extension
        switch (f3) {
          case 0: v = aw * bw; break;                                   // MULW
          case 4:                                                       // DIVW
            if (bw == 0) v = 0xFFFFFFFFu;
            else if (aw == 0x80000000u && bw == 0xFFFFFFFFu) v = aw;
            else v = (uint32_t)((int32_t)aw / (int32_t)bw);
            break;
          case 5: v = bw ? aw / bw : 0xFFFFFFFFu; break;                // DIVUW
          case 6:                                                       // REMW
            if (bw == 0) v = aw;
            else if (aw == 0x80000000u && bw == 0xFFFFFFFFu) v = 0;
            else v = (uint32_t)((int32_t)aw % (int32_t)bw);
            break;
          case 7: v = bw ? aw % bw : aw; break;                         // REMUW
          default: ILLEGAL();
        }
        c->ev.cls = (f3 == 0) ? EV_MUL : EV_DIV;
      } else if (f7 == 0x00 || f7 == 0x20) {
        switch (f3) {
          case 0: v = f7 ? aw - bw : aw + bw; break;                    // ADDW / SUBW
          case 1: if (f7) ILLEGAL(); v = aw << (bw & 0x1F); break;      // SLLW
          case 5: v = f7 ? (uint32_t)((int32_t)aw >> (bw & 0x1F)) : aw >> (bw & 0x1F); break;
          default: ILLEGAL();
        }
      } else {
        ILLEGAL();
      }
      wr_x(c, rd, SEXT32(v));
      break;
    }
    case 0x0F: break;                                                   // FENCE / FENCE.I

    case 0x73: {                                                        // SYSTEM
      c->ev.cls = EV_SYS;
      if (f3 == 0) {
        if (insn == 0x00000073u) return trap(c, CAUSE_ECALL_M, 0);
        if (insn == 0x00100073u) return trap(c, CAUSE_BREAKPOINT, pc);
        if (insn == 0x30200073u) {                                      // MRET
          npc = c->mepc;
          uint64_t mpie = (c->mstatus & MSTATUS_MPIE) ? MSTATUS_MIE : 0;
          c->mstatus = (c->mstatus & ~MSTATUS_MIE) | mpie | MSTATUS_MPIE;
          c->ev.indirect = 1;
          break;
        }
        if (insn == 0x10500073u) {                                      // WFI
          if (!(c->mip & c->mie)) return ISS_WFI;
          break;
        }
        ILLEGAL();
      }
      if (f3 == 4) ILLEGAL();
      uint32_t csr = insn >> 20;
      uint64_t old = 0;
      uint64_t src = (f3 & 4) ? (uint64_t)rs1 : a;
      int do_write = ((f3 & 3) == 1) || rs1 != 0;
      if (!csr_read(c, csr, &old)) ILLEGAL();
      if (do_write) {
        uint64_t nv;
        switch (f3 & 3) {
          case 1: nv = src; break;
          case 2: nv = old | src; break;
          default: nv = old & ~src; break;
        }
        if (!csr_write(c, csr, nv)) ILLEGAL();
      }
      wr_x(c, rd, old);
      break;
    }

    // ======================= A extension =======================
    case 0x2F: {
      if (f3 != 2 && f3 != 3) ILLEGAL();
      const int sz = (f3 == 3) ? 8 : 4;
      uint32_t op = insn >> 27;
      uint64_t v = 0;
      c->ev.cls = EV_STORE;
      if (op == 0x02) {                                                 // LR
        LOAD(a, sz, &v);
        if (sz == 4) v = SEXT32(v);
        c->lr_valid = 1;
        c->lr_addr = a;
        wr_x(c, rd, v);
        c->ev.cls = EV_LOAD;
        break;
      }
      if (op == 0x03) {                                                 // SC
        if (c->lr_valid && c->lr_addr == a) {
          STORE(a, sz, sz == 4 ? (b & 0xFFFFFFFFull) : b);
          wr_x(c, rd, 0);
        } else {
          wr_x(c, rd, 1);
        }
        c->lr_valid = 0;
        break;
      }
      LOAD(a, sz, &v);
      uint64_t x = v, y = b, r;
      if (sz == 4) { x = SEXT32(v); y = SEXT32(b); }
      switch (op) {
        case 0x01: r = y; break;                                        // AMOSWAP
        case 0x00: r = x + y; break;                                    // AMOADD
        case 0x04: r = x ^ y; break;                                    // AMOXOR
        case 0x0C: r = x & y; break;                                    // AMOAND
        case 0x08: r = x | y; break;                                    // AMOOR
        case 0x10: r = (int64_t)x < (int64_t)y ? x : y; break;          // AMOMIN
        case 0x14: r = (int64_t)x > (int64_t)y ? x : y; break;          // AMOMAX
        case 0x18: r = (sz == 4 ? ((uint32_t)x < (uint32_t)y) : (x < y)) ? x : y; break;  // AMOMINU
        case 0x1C: r = (sz == 4 ? ((uint32_t)x > (uint32_t)y) : (x > y)) ? x : y; break;  // AMOMAXU
        default: ILLEGAL();
      }
      STORE(a, sz, sz == 4 ? (r & 0xFFFFFFFFull) : r);
      wr_x(c, rd, x);
      break;
    }

    // ======================= F / D loads & stores =======================
    case 0x07: {
      uint64_t addr = a + imm_i(insn), v = 0;
      if (f3 == 2)      { LOAD(addr, 4, &v); f_set32(c, rd, (uint32_t)v); }
      else if (f3 == 3) { LOAD(addr, 8, &v); c->f[rd] = v; }
      else ILLEGAL();
      c->ev.cls = EV_LOAD;
      break;
    }
    case 0x27: {
      uint64_t addr = a + imm_s(insn);
      if (f3 == 2)      { STORE(addr, 4, c->f[rs2] & 0xFFFFFFFFull); }
      else if (f3 == 3) { STORE(addr, 8, c->f[rs2]); }
      else ILLEGAL();
      c->ev.cls = EV_STORE;
      break;
    }

    // ======================= fused multiply-add =======================
    case 0x43: case 0x47: case 0x4B: case 0x4F: {
      uint32_t fmt = (insn >> 25) & 3, op = (insn >> 2) & 3;
      c->ev.cls = EV_FMA;
      if (!fp_begin(c, f3)) ILLEGAL();
      int rs3 = RS3(insn);
      if (fmt == 0) {
        float x = f_gets(c, rs1), y = f_gets(c, rs2), z = f_gets(c, rs3), r;
        switch (op) {
          case 0: r = fmaf(x, y, z); break;       // FMADD
          case 1: r = fmaf(x, y, -z); break;      // FMSUB
          case 2: r = fmaf(-x, y, z); break;      // FNMSUB
          default: r = fmaf(-x, y, -z); break;    // FNMADD
        }
        fp_end(c, 0);
        f_sets(c, rd, r);
      } else if (fmt == 1) {
        double x = f_getd(c, rs1), y = f_getd(c, rs2), z = f_getd(c, rs3), r;
        switch (op) {
          case 0: r = fma(x, y, z); break;
          case 1: r = fma(x, y, -z); break;
          case 2: r = fma(-x, y, z); break;
          default: r = fma(-x, y, -z); break;
        }
        fp_end(c, 0);
        f_setd(c, rd, r);
      } else {
        fesetround(FE_TONEAREST);
        ILLEGAL();
      }
      break;
    }

    // ======================= OP-FP =======================
    case 0x53: {
      uint32_t fmt = f7 & 3, op = f7 >> 2;
      int is_d = (fmt == 1);
      if (fmt > 1) ILLEGAL();
      uint32_t fl = 0;
      c->ev.cls = (op == 0x02) ? EV_FMUL : (op == 0x03 || op == 0x0B) ? EV_FDIV : EV_FP;
      switch (op) {
        case 0x00: case 0x01: case 0x02: case 0x03: case 0x0B: {   // ADD SUB MUL DIV SQRT
          if (!fp_begin(c, f3)) ILLEGAL();
          if (is_d) {
            double x = f_getd(c, rs1), y = f_getd(c, rs2), r;
            switch (op) {
              case 0: r = x + y; break;
              case 1: r = x - y; break;
              case 2: r = x * y; break;
              case 3: r = x / y; break;
              default: r = sqrt(x); break;
            }
            fp_end(c, 0);
            f_setd(c, rd, r);
          } else {
            float x = f_gets(c, rs1), y = f_gets(c, rs2), r;
            switch (op) {
              case 0: r = x + y; break;
              case 1: r = x - y; break;
              case 2: r = x * y; break;
              case 3: r = x / y; break;
              default: r = sqrtf(x); break;
            }
            fp_end(c, 0);
            f_sets(c, rd, r);
          }
          break;
        }
        case 0x04: {                                                    // FSGNJ[N|X]
          if (is_d) {
            uint64_t x = c->f[rs1], y = c->f[rs2], s;
            switch (f3) {
              case 0: s = y; break;
              case 1: s = ~y; break;
              case 2: s = x ^ y; break;
              default: ILLEGAL();
            }
            c->f[rd] = (x & ~(1ull << 63)) | (s & (1ull << 63));
          } else {
            uint32_t x = f_get32(c, rs1), y = f_get32(c, rs2), s;
            switch (f3) {
              case 0: s = y; break;
              case 1: s = ~y; break;
              case 2: s = x ^ y; break;
              default: ILLEGAL();
            }
            f_set32(c, rd, (x & 0x7FFFFFFFu) | (s & 0x80000000u));
          }
          break;
        }
        case 0x05: {                                                    // FMIN / FMAX
          if (f3 > 1) ILLEGAL();
          if (is_d) {
            double r = fminmax(f_getd(c, rs1), f_getd(c, rs2), f3,
                               f64_issnan(c->f[rs1]), f64_issnan(c->f[rs2]), &fl);
            f_setd(c, rd, r);
          } else {
            double r = fminmax(f_gets(c, rs1), f_gets(c, rs2), f3,
                               f32_issnan(f_get32(c, rs1)), f32_issnan(f_get32(c, rs2)), &fl);
            f_sets(c, rd, (float)r);
          }
          c->fcsr |= fl;
          break;
        }
        case 0x08: {                                                    // FCVT.S.D / FCVT.D.S
          if (!fp_begin(c, f3)) ILLEGAL();
          if (is_d && rs2 == 0) {        // FCVT.D.S
            double r = (double)f_gets(c, rs1);
            fp_end(c, f32_issnan(f_get32(c, rs1)) ? FFLAG_NV : 0);
            f_setd(c, rd, r);
          } else if (!is_d && rs2 == 1) { // FCVT.S.D
            float r = (float)f_getd(c, rs1);
            fp_end(c, 0);
            f_sets(c, rd, r);
          } else {
            fesetround(FE_TONEAREST);
            ILLEGAL();
          }
          break;
        }
        case 0x14: {                                                    // FEQ FLT FLE
          double x, y;
          int nan_x, nan_y, snan;
          if (is_d) {
            x = f_getd(c, rs1); y = f_getd(c, rs2);
            snan = f64_issnan(c->f[rs1]) || f64_issnan(c->f[rs2]);
          } else {
            x = f_gets(c, rs1); y = f_gets(c, rs2);
            snan = f32_issnan(f_get32(c, rs1)) || f32_issnan(f_get32(c, rs2));
          }
          nan_x = isnan(x); nan_y = isnan(y);
          uint64_t r;
          switch (f3) {
            case 2: r = (!nan_x && !nan_y && x == y); if (snan) fl |= FFLAG_NV; break;
            case 1: r = (!nan_x && !nan_y && x < y);  if (nan_x || nan_y) fl |= FFLAG_NV; break;
            case 0: r = (!nan_x && !nan_y && x <= y); if (nan_x || nan_y) fl |= FFLAG_NV; break;
            default: ILLEGAL();
          }
          c->fcsr |= fl;
          wr_x(c, rd, r);
          break;
        }
        case 0x18: {                                                    // FCVT.{W,WU,L,LU}.S/D
          if (rs2 > 3) ILLEGAL();
          if (!fp_begin(c, f3)) ILLEGAL();
          double v = is_d ? f_getd(c, rs1) : (double)f_gets(c, rs1);
          uint64_t r = cvt_to_int(v, rs2, &fl);
          fesetround(FE_TONEAREST);
          c->fcsr |= fl;
          wr_x(c, rd, r);
          break;
        }
        case 0x1A: {                                                    // FCVT.S/D.{W,WU,L,LU}
          if (rs2 > 3) ILLEGAL();
          if (!fp_begin(c, f3)) ILLEGAL();
          if (is_d) {
            double r;
            switch (rs2) {
              case 0: r = (double)(int32_t)a; break;
              case 1: r = (double)(uint32_t)a; break;
              case 2: r = (double)(int64_t)a; break;
              default: r = (double)a; break;
            }
            fp_end(c, 0);
            f_setd(c, rd, r);
          } else {
            float r;
            switch (rs2) {
              case 0: r = (float)(int32_t)a; break;
              case 1: r = (float)(uint32_t)a; break;
              case 2: r = (float)(int64_t)a; break;
              default: r = (float)a; break;
            }
            fp_end(c, 0);
            f_sets(c, rd, r);
          }
          break;
        }
        case 0x1C: {                                                    // FMV.X.W / FMV.X.D / FCLASS
          if (rs2 != 0) ILLEGAL();
          if (f3 == 0) wr_x(c, rd, is_d ? c->f[rs1] : SEXT32(c->f[rs1]));
          else if (f3 == 1) wr_x(c, rd, is_d ? fclass64(c->f[rs1]) : fclass32(f_get32(c, rs1)));
          else ILLEGAL();
          break;
        }
        case 0x1E: {                                                    // FMV.W.X / FMV.D.X
          if (rs2 != 0 || f3 != 0) ILLEGAL();
          if (is_d) c->f[rd] = a;
          else      f_set32(c, rd, (uint32_t)a);
          break;
        }
        default: ILLEGAL();
      }
      break;
    }

    default: ILLEGAL();
  }

  c->ev.target = npc;
  c->pc = npc;
  c->instret++;
  return ISS_OK;
}
