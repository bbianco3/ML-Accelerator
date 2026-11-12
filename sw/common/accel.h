// accel.h -- host-side driver for the accelerator.
//
// Register map: docs/memory-map.md (mirrors CSR_* in hw/rtl/accel_pkg.sv).
//
// Typical use:
//     extern void my_kernel(void);              // defined in kernel.S
//     static bf16_t x[N] HBM_BUF;               // buffer in HBM
//     uint32_t args[] = { N, (uint32_t)x };     // become a0, a1 in the kernel
//     uint32_t st = accel_run(my_kernel, args, 2);
//     if (st & ACCEL_STATUS_ERROR) ... ;
#ifndef ACCEL_H
#define ACCEL_H

#include <stdint.h>

#include "memory_map.h"
#include "runtime.h"

// ---- register offsets -------------------------------------------------------
#define ACCEL_ID         0x000u
#define ACCEL_CTRL       0x004u
#define ACCEL_STATUS     0x008u
#define ACCEL_IRQ_EN     0x00Cu
#define ACCEL_START_PC   0x010u
#define ACCEL_ERR_PC     0x014u
#define ACCEL_ERR_INSN   0x018u
#define ACCEL_CYCLES_LO  0x020u
#define ACCEL_CYCLES_HI  0x024u
#define ACCEL_INSTRET_LO 0x028u
#define ACCEL_INSTRET_HI 0x02Cu
#define ACCEL_CORES      0x030u   // RW: number of cores the next START launches
#define ACCEL_ERR_CORE   0x034u   // RO: core that reported ERR_PC / ERR_INSN
#define ACCEL_CFG0       0x040u
#define ACCEL_CFG1       0x044u
#define ACCEL_CFG2       0x048u
#define ACCEL_CFG3       0x04Cu
#define ACCEL_ARG(n)     (0x080u + 4u * (n))
#define ACCEL_NUM_ARGS   8

#define ACCEL_ID_VALUE   0xACCE0200u

#define ACCEL_CTRL_START    (1u << 0)
#define ACCEL_STATUS_BUSY   (1u << 0)
#define ACCEL_STATUS_DONE   (1u << 1)
#define ACCEL_STATUS_ERROR  (1u << 2)
#define ACCEL_STATUS_CAUSE(s) (((s) >> 8) & 0xFFu)

// error causes (STATUS[15:8])
#define ACCEL_ERR_NONE       0
#define ACCEL_ERR_ILLEGAL    1
#define ACCEL_ERR_MISALIGNED 2
#define ACCEL_ERR_BUS        3
#define ACCEL_ERR_EBREAK     4
#define ACCEL_ERR_BAD_REG    5

// ---- placing data in HBM ----------------------------------------------------
// Vector loads/stores must be aligned to VLEN/8 bytes and matrix rows to
// MAT_DIM*2 bytes. HBM_ALIGN covers every legal configuration up to
// VLEN = 4096 and MAT_DIM = 256; hbm_alloc() lets you choose per buffer.
#define HBM_ALIGN 512
// Zero-initialised buffer in HBM (no space in the ELF file).
#define HBM_BUF  __attribute__((section(".hbm.bss"), aligned(HBM_ALIGN)))
// Initialised data in HBM (loaded by the simulator's ELF loader).
#define HBM_DATA __attribute__((section(".hbm.data"), aligned(HBM_ALIGN)))

// ---- raw register access ----------------------------------------------------
static inline uint32_t accel_rd(uint32_t off) {
  return *(volatile uint32_t *)(uintptr_t)(ACCEL_CSR_BASE + off);
}
static inline void accel_wr(uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(uintptr_t)(ACCEL_CSR_BASE + off) = v;
}

// ---- configuration discovery ------------------------------------------------
typedef struct {
  uint32_t vlen;          // bits per vector register
  uint32_t vlmax;         // bf16 elements per vector register
  uint32_t mat_dim;       // matrix tile is mat_dim x mat_dim
  uint32_t num_tregs;
  uint32_t num_accs;
  uint32_t mxu_rows;
  uint32_t hbm_data_w;
  uint32_t icache_lines;
  uint32_t num_cores;     // compute cores (each: control core + scratchpad + units)
  uint32_t num_vpus;      // cores 0 .. num_vpus-1 have a vector unit
  uint32_t num_mxus;      // cores 0 .. num_mxus-1 have a matrix unit
  uint32_t num_full_cores; // cores 0 .. num_full_cores-1 have both
  uint32_t spad_bytes;    // scratchpad bytes per core, at SPAD_BASE (0 = none)
} accel_config_t;

static inline accel_config_t accel_get_config(void) {
  accel_config_t c;
  uint32_t c1 = accel_rd(ACCEL_CFG1), c2 = accel_rd(ACCEL_CFG2), c3 = accel_rd(ACCEL_CFG3);
  c.vlen         = accel_rd(ACCEL_CFG0);
  c.vlmax        = c.vlen / 16;
  c.mat_dim      = c1 & 0xFF;
  c.num_tregs    = (c1 >> 8) & 0xFF;
  c.num_accs     = (c1 >> 16) & 0xFF;
  c.mxu_rows     = (c1 >> 24) & 0xFF;
  c.hbm_data_w   = c2 & 0xFFFF;
  c.icache_lines = c2 >> 16;
  c.num_cores    = c3 & 0xFF;
  c.num_vpus     = (c3 >> 8) & 0xF;
  c.num_mxus     = (c3 >> 12) & 0xF;
  c.num_full_cores = c.num_vpus < c.num_mxus ? c.num_vpus : c.num_mxus;
  c.spad_bytes   = (c3 >> 16) * 1024u;
  return c;
}

static inline void accel_print_config(const accel_config_t *c) {
  printf("accel: VLEN=%u (VLMAX=%u) MAT_DIM=%u TREGS=%u ACCS=%u MXU_ROWS=%u HBM_DATA_W=%u ICACHE=%u"
         " CORES=%u (VPUs=%u MXUs=%u) SPAD=%u KiB\n",
         c->vlen, c->vlmax, c->mat_dim, c->num_tregs, c->num_accs, c->mxu_rows,
         c->hbm_data_w, c->icache_lines, c->num_cores, c->num_vpus, c->num_mxus, c->spad_bytes / 1024u);
}

// ---- launching kernels ------------------------------------------------------
typedef void (*accel_kernel_t)(void);

// Start a kernel on cores 0 .. ncores-1 (clamped to 1 .. num_cores). Every
// core runs the same code with the same a0..a7 = args[0..nargs-1]; a kernel
// tells cores apart with `csrr t0, mhartid` and `csrr t1, CSR_NCORES`.
static inline void accel_launch_cores(accel_kernel_t entry, const uint32_t *args, int nargs,
                                      uint32_t ncores) {
  for (int i = 0; i < nargs && i < ACCEL_NUM_ARGS; i++) accel_wr(ACCEL_ARG(i), args[i]);
  accel_wr(ACCEL_START_PC, (uint32_t)(uintptr_t)entry);
  accel_wr(ACCEL_CORES, ncores);
  accel_wr(ACCEL_CTRL, ACCEL_CTRL_START);
}

// Start a kernel on core 0 only. args[0..nargs-1] are copied to a0..a(nargs-1).
static inline void accel_launch(accel_kernel_t entry, const uint32_t *args, int nargs) {
  accel_launch_cores(entry, args, nargs, 1);
}

// Busy-wait (polling STATUS over AXI4-Lite) until the kernel finishes.
// Returns the final STATUS value.
static inline uint32_t accel_wait(void) {
  uint32_t s;
  do {
    s = accel_rd(ACCEL_STATUS);
  } while ((s & ACCEL_STATUS_BUSY) || !(s & (ACCEL_STATUS_DONE | ACCEL_STATUS_ERROR)));
  return s;
}

// Sleep in WFI until the accelerator raises its interrupt. Interrupts stay
// globally disabled (mstatus.MIE = 0), so no trap handler is needed: WFI
// simply resumes when mip.MEIP is set. Returns the final STATUS value.
static inline uint32_t accel_wait_irq(void) {
  accel_wr(ACCEL_IRQ_EN, 1);
  __asm__ volatile("csrs mie, %0" ::"r"(1u << 11));   // mie.MEIE
  uint32_t s;
  for (;;) {
    s = accel_rd(ACCEL_STATUS);
    if (!(s & ACCEL_STATUS_BUSY) && (s & (ACCEL_STATUS_DONE | ACCEL_STATUS_ERROR))) break;
    __asm__ volatile("wfi");
  }
  __asm__ volatile("csrc mie, %0" ::"r"(1u << 11));
  accel_wr(ACCEL_IRQ_EN, 0);
  return s;
}

static inline uint64_t accel_cycles(void) {
  uint32_t lo = accel_rd(ACCEL_CYCLES_LO);
  uint32_t hi = accel_rd(ACCEL_CYCLES_HI);
  return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t accel_instret(void) {
  uint32_t lo = accel_rd(ACCEL_INSTRET_LO);
  uint32_t hi = accel_rd(ACCEL_INSTRET_HI);
  return ((uint64_t)hi << 32) | lo;
}

static inline const char *accel_cause_str(uint32_t cause) {
  switch (cause) {
    case ACCEL_ERR_NONE:       return "none";
    case ACCEL_ERR_ILLEGAL:    return "illegal instruction";
    case ACCEL_ERR_MISALIGNED: return "misaligned access";
    case ACCEL_ERR_BUS:        return "bus error";
    case ACCEL_ERR_EBREAK:     return "ebreak";
    case ACCEL_ERR_BAD_REG:    return "bad tile/accumulator index";
    default:                   return "unknown";
  }
}

// Print why a kernel failed (call when STATUS.ERROR is set).
static inline void accel_report_error(uint32_t status) {
  uint32_t cause = ACCEL_STATUS_CAUSE(status);
  printf("accel: kernel FAILED on core %u: cause=%u (%s) pc=0x%08x insn=0x%08x\n",
         accel_rd(ACCEL_ERR_CORE), cause, accel_cause_str(cause), accel_rd(ACCEL_ERR_PC),
         accel_rd(ACCEL_ERR_INSN));
}

// Launch, wait (polling), report errors. Returns the final STATUS value.
static inline uint32_t accel_run(accel_kernel_t entry, const uint32_t *args, int nargs) {
  accel_launch(entry, args, nargs);
  uint32_t s = accel_wait();
  if (s & ACCEL_STATUS_ERROR) accel_report_error(s);
  return s;
}

// Same on cores 0 .. ncores-1.
static inline uint32_t accel_run_cores(accel_kernel_t entry, const uint32_t *args, int nargs,
                                       uint32_t ncores) {
  accel_launch_cores(entry, args, nargs, ncores);
  uint32_t s = accel_wait();
  if (s & ACCEL_STATUS_ERROR) accel_report_error(s);
  return s;
}

#endif // ACCEL_H
