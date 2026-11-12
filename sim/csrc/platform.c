// platform.c -- simulated platform glue (compiled into simv by VCS).
//
// Owns:
//   * host RAM (HOST_RAM_BASE..) -- only the host ISS can see it
//   * HBM storage (HBM_BASE..)   -- sparse, zero-initialised; accessed by the
//     host ISS directly (zero time) and by the RTL through the AXI HBM model
//     in sim/tb/hbm_model.sv (via hbm_read32 / hbm_write32 below)
//   * the simulation control device (SIMCTRL_*: console, exit, cycle counter,
//     region of interest)
//   * the host ISS (RV64G), its MMIO handshake with the testbench, and the
//     host time/energy accounting inside the region of interest
//     (host_model.c, docs/host-model.md)
//
// All functions with external linkage at the bottom are DPI-C imports used by
// sim/tb/host_bfm.sv and sim/tb/hbm_model.sv.
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "svdpi.h"
#include "vpi_user.h"

#include "host_model.h"
#include "memory_map.h"
#include "rv64_iss.h"

// ============================================================================
// Memories
// ============================================================================
#define HBM_PAGE_SHIFT 16
#define HBM_PAGE_SIZE  (1u << HBM_PAGE_SHIFT)
#define HBM_NPAGES     (HBM_SIZE >> HBM_PAGE_SHIFT)

static uint8_t *host_ram;
static uint8_t *hbm_pages[HBM_NPAGES];

static inline int in_range(uint64_t addr, uint32_t n, uint32_t base, uint32_t size) {
  return addr >= base && addr + n <= (uint64_t)base + size;
}

static uint8_t *hbm_byte(uint32_t addr) {
  uint32_t off = addr - HBM_BASE;
  uint32_t pg = off >> HBM_PAGE_SHIFT;
  if (!hbm_pages[pg]) {
    hbm_pages[pg] = (uint8_t *)calloc(1, HBM_PAGE_SIZE);
    if (!hbm_pages[pg]) {
      vpi_printf("[platform] FATAL: out of memory allocating HBM page\n");
      exit(1);
    }
  }
  return &hbm_pages[pg][off & (HBM_PAGE_SIZE - 1)];
}

// Byte-granular access to host RAM / HBM. Returns 0 on success.
static int mem_access(uint64_t addr, uint8_t *buf, uint32_t n, int write) {
  if (in_range(addr, n, HOST_RAM_BASE, HOST_RAM_SIZE)) {
    uint8_t *p = host_ram + (addr - HOST_RAM_BASE);
    if (write) memcpy(p, buf, n);
    else       memcpy(buf, p, n);
    return 0;
  }
  if (in_range(addr, n, HBM_BASE, HBM_SIZE)) {
    for (uint32_t i = 0; i < n; i++) {
      uint8_t *p = hbm_byte((uint32_t)addr + i);
      if (write) *p = buf[i];
      else       buf[i] = *p;
    }
    return 0;
  }
  return -1;
}

// ============================================================================
// Host CPU + MMIO handshake
// ============================================================================
static rv64_cpu_t cpu;
static int        exited;
static int        exit_code = -1;
static uint64_t   cur_cycle;

// Region of interest (ROI): between roi_begin() and roi_end() the host runs
// in real time (2 GHz core, host_model.c) and its energy is accounted.
// Outside, it runs +host_ipc instructions per accelerator clock, unaccounted.
static int      clk_ps = 2500;      // accelerator clock period (host_config)
static int      in_roi;
static int      roi_count;
static uint64_t roi_start_cycle;
static uint64_t roi_accel_cycles;   // accelerator clocks spent inside ROIs
static int64_t  credit_ps;          // host time not yet used in this clock

static void roi_set(int on) {
  if (on && !in_roi) {
    in_roi = 1;
    roi_count++;
    roi_start_cycle = cur_cycle;
    credit_ps = 0;
  } else if (!on && in_roi) {
    in_roi = 0;
    roi_accel_cycles += cur_cycle - roi_start_cycle;
  }
}

static void roi_report(void) {
  roi_set(0);
  if (!roi_count) return;
  const hm_stats_t *h = hm_stats();
  double roi_ps      = (double)roi_accel_cycles * clk_ps;
  double host_cycles = roi_ps / HM_CYCLE_PS;
  double idle_cycles = host_cycles > (double)h->busy_cycles ? host_cycles - (double)h->busy_cycles : 0.0;
  double dyn_nj  = h->dyn_pj * 1e-3;
  double idle_nj = idle_cycles * HM_E_IDLE_CYCLE * 1e-3;
  double leak_nj = HM_P_LEAK_MW * roi_ps * 1e-6;
  double tot_nj  = dyn_nj + idle_nj + leak_nj;
  vpi_printf("[platform] ---- region of interest (%d region%s) ----\n", roi_count, roi_count == 1 ? "" : "s");
  vpi_printf("[platform]   time         : %.1f ns = %llu accelerator cycles x %d ps\n", roi_ps * 1e-3,
             (unsigned long long)roi_accel_cycles, clk_ps);
  vpi_printf("[platform]   host CPU     : %llu instructions in %llu cycles at %.1f GHz (CPI %.2f), busy %.1f %% of the time\n",
             (unsigned long long)h->instr, (unsigned long long)h->busy_cycles, 1000.0 / HM_CYCLE_PS,
             h->instr ? (double)h->busy_cycles / (double)h->instr : 0.0,
             host_cycles > 0 ? 100.0 * (double)h->busy_cycles / host_cycles : 0.0);
  vpi_printf("[platform]   host events  : %llu L1D misses, %llu L2 misses, %llu branch mispredicts, %llu device register accesses\n",
             (unsigned long long)h->l1_miss, (unsigned long long)h->l2_miss,
             (unsigned long long)h->mispredict, (unsigned long long)h->device);
  vpi_printf("[platform]   host energy  : %.1f nJ = %.1f active + %.1f idle + %.1f leakage (average %.1f mW)\n",
             tot_nj, dyn_nj, idle_nj, leak_nj, roi_ps > 0 ? tot_nj / roi_ps * 1e6 : 0.0);
  vpi_printf("[platform]   accelerator energy = its power from 'make synth' x time (see docs/host-model.md)\n");
  vpi_printf("ROI_STATS time_ns=%.1f accel_cycles=%llu host_instr=%llu host_cycles=%llu host_energy_nj=%.1f\n",
             roi_ps * 1e-3, (unsigned long long)roi_accel_cycles, (unsigned long long)h->instr,
             (unsigned long long)h->busy_cycles, tot_nj);
}

enum { MMIO_IDLE, MMIO_WAIT, MMIO_DONE };
static int      mmio_state = MMIO_IDLE;
static uint32_t mmio_addr, mmio_wdata, mmio_rdata;
static int      mmio_write, mmio_err;

static char con_buf[1024];
static int  con_len;

static void con_flush(void) {
  if (con_len) {
    con_buf[con_len] = 0;
    vpi_printf("[host] %s\n", con_buf);
    con_len = 0;
  }
}

static void con_putc(char ch) {
  if (ch == '\n' || con_len == (int)sizeof con_buf - 1) {
    if (ch != '\n') con_buf[con_len++] = ch;
    con_flush();
  } else if (ch != '\r') {
    con_buf[con_len++] = ch;
  }
}

// Forward an access to the accelerator CSR window to the RTL.
static mem_status_t mmio(uint32_t addr, int size, int write, uint32_t wdata, uint64_t *rdata) {
  if (size != 4 || (addr & 3)) return MEM_FAULT;   // AXI4-Lite is 32-bit only
  if (mmio_state == MMIO_DONE && mmio_addr == addr && mmio_write == write) {
    mmio_state = MMIO_IDLE;
    if (rdata) *rdata = mmio_rdata;
    return mmio_err ? MEM_FAULT : MEM_OK;
  }
  mmio_state = MMIO_WAIT;
  mmio_addr  = addr;
  mmio_write = write;
  mmio_wdata = wdata;
  return MEM_PENDING;
}

static mem_status_t bus_load(void *ctx, uint64_t addr, int size, uint64_t *data) {
  (void)ctx;
  uint8_t b[8] = {0};
  if (mem_access(addr, b, (uint32_t)size, 0) == 0) {
    uint64_t v = 0;
    for (int i = size - 1; i >= 0; i--) v = (v << 8) | b[i];
    *data = v;
    return MEM_OK;
  }
  if (in_range(addr, (uint32_t)size, ACCEL_CSR_BASE, ACCEL_CSR_SIZE))
    return mmio((uint32_t)addr, size, 0, 0, data);
  if (in_range(addr, (uint32_t)size, SIMCTRL_BASE, SIMCTRL_SIZE)) {
    if (addr == SIMCTRL_CYCLE_LO)      *data = (uint32_t)cur_cycle;
    else if (addr == SIMCTRL_CYCLE_HI) *data = (uint32_t)(cur_cycle >> 32);
    else if (addr == SIMCTRL_ROI)      *data = (uint32_t)in_roi;
    else                               *data = 0;
    return MEM_OK;
  }
  return MEM_FAULT;
}

static mem_status_t bus_store(void *ctx, uint64_t addr, int size, uint64_t data) {
  (void)ctx;
  uint8_t b[8];
  for (int i = 0; i < 8; i++) b[i] = (uint8_t)(data >> (8 * i));
  if (mem_access(addr, b, (uint32_t)size, 1) == 0) return MEM_OK;
  if (in_range(addr, (uint32_t)size, ACCEL_CSR_BASE, ACCEL_CSR_SIZE))
    return mmio((uint32_t)addr, size, 1, (uint32_t)data, NULL);
  if (in_range(addr, (uint32_t)size, SIMCTRL_BASE, SIMCTRL_SIZE)) {
    if (addr == SIMCTRL_PUTCHAR) { con_putc((char)data); return MEM_OK; }
    if (addr == SIMCTRL_ROI)     { roi_set((data & 1) != 0); return MEM_OK; }
    if (addr == SIMCTRL_EXIT) {
      con_flush();
      exited = 1;
      exit_code = (int)data;
      roi_report();
      return MEM_EXIT;
    }
    return MEM_OK;
  }
  return MEM_FAULT;
}

static void bus_log(void *ctx, const char *msg) {
  (void)ctx;
  vpi_printf("%s\n", msg);
}

// ============================================================================
// ELF loader (ELF64, little-endian, RISC-V)
// ============================================================================
typedef struct {
  uint8_t  e_ident[16];
  uint16_t e_type, e_machine;
  uint32_t e_version;
  uint64_t e_entry, e_phoff, e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx;
} elf64_ehdr_t;

typedef struct {
  uint32_t p_type, p_flags;
  uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
} elf64_phdr_t;

static int load_elf(const char *path, uint64_t *entry) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    vpi_printf("[platform] ERROR: cannot open ELF '%s'\n", path);
    return -1;
  }
  elf64_ehdr_t eh;
  if (fread(&eh, sizeof eh, 1, f) != 1 || memcmp(eh.e_ident, "\x7f" "ELF", 4) != 0 ||
      eh.e_ident[4] != 2 /*ELFCLASS64*/ || eh.e_machine != 243 /*EM_RISCV*/) {
    vpi_printf("[platform] ERROR: '%s' is not an RV64 ELF file\n", path);
    fclose(f);
    return -1;
  }
  for (int i = 0; i < eh.e_phnum; i++) {
    elf64_phdr_t ph;
    fseek(f, (long)(eh.e_phoff + (uint64_t)i * eh.e_phentsize), SEEK_SET);
    if (fread(&ph, sizeof ph, 1, f) != 1) break;
    if (ph.p_type != 1 /*PT_LOAD*/ || ph.p_memsz == 0) continue;
    uint8_t *buf = (uint8_t *)calloc(1, ph.p_memsz);
    fseek(f, (long)ph.p_offset, SEEK_SET);
    if (ph.p_filesz && fread(buf, 1, ph.p_filesz, f) != ph.p_filesz) {
      vpi_printf("[platform] ERROR: short read in '%s'\n", path);
      free(buf);
      fclose(f);
      return -1;
    }
    if (mem_access(ph.p_paddr, buf, ph.p_memsz, 1) != 0) {
      vpi_printf("[platform] ERROR: segment 0x%08llx+0x%llx is outside host RAM / HBM\n",
                 (unsigned long long)ph.p_paddr, (unsigned long long)ph.p_memsz);
      free(buf);
      fclose(f);
      return -1;
    }
    vpi_printf("[platform] loaded segment 0x%08llx-0x%08llx (%s)\n", (unsigned long long)ph.p_paddr,
               (unsigned long long)(ph.p_paddr + ph.p_memsz - 1),
               in_range(ph.p_paddr, 1, HBM_BASE, HBM_SIZE) ? "HBM" : "host RAM");
    free(buf);
  }
  fclose(f);
  *entry = eh.e_entry;
  return 0;
}

// ============================================================================
// DPI-C interface: host CPU (used by sim/tb/host_bfm.sv)
// ============================================================================
int host_init(const char *elf_path, int trace) {
  host_ram = (uint8_t *)calloc(1, HOST_RAM_SIZE);
  uint64_t entry = 0;
  if (load_elf(elf_path, &entry) != 0) return -1;
  rv64_bus_t bus = {bus_load, bus_store, bus_log, NULL};
  rv64_init(&cpu, entry, bus);
  cpu.trace = trace;
  hm_reset();
  vpi_printf("[platform] host CPU (RV64G ISS, %.1f GHz inside the region of interest) reset, entry = 0x%08llx\n",
             1000.0 / HM_CYCLE_PS, (unsigned long long)entry);
  return 0;
}

// Accelerator clock period, so that host time and accelerator time line up.
void host_config(int accel_clk_ps) {
  if (accel_clk_ps > 0) clk_ps = accel_clk_ps;
}

static int is_device_addr(uint64_t addr) {
  return !in_range(addr, 1, HOST_RAM_BASE, HOST_RAM_SIZE) && !in_range(addr, 1, HBM_BASE, HBM_SIZE);
}

// Advance the host by one accelerator clock.
//   outside the ROI: run up to max_instr instructions (no time accounting)
//   inside the ROI : run instructions until one accelerator clock period of
//                    host time (clk_ps) is used up
// Returns 0 = ran, 1 = MMIO request pending, 2 = program exited,
//         3 = waiting in WFI, 4 = fatal error.
int host_step(int max_instr, int irq, long long cycle) {
  if (exited) return 2;
  cur_cycle  = (uint64_t)cycle;
  cpu.cycle  = (uint64_t)cycle;
  rv64_set_meip(&cpu, irq);
  if (mmio_state == MMIO_WAIT) return 1;
  if (in_roi) {
    credit_ps += clk_ps;
    if (credit_ps > clk_ps) credit_ps = clk_ps;      // idle time cannot be saved up
  }
  for (int i = 0; in_roi ? credit_ps > 0 : i < max_instr; i++) {
    int timed = in_roi;
    switch (rv64_step(&cpu)) {
      case ISS_OK:
        if (timed)
          credit_ps -= (int64_t)hm_account(&cpu.ev, cpu.ev.mem != EV_MEM_NONE && is_device_addr(cpu.ev.addr)) * HM_CYCLE_PS;
        if (timed != in_roi) return 0;               // roi_begin()/roi_end(): switch mode next clock
        continue;
      case ISS_PENDING: credit_ps = 0; return 1;
      case ISS_EXIT:    return 2;
      case ISS_WFI:     credit_ps = 0; return 3;
      case ISS_FATAL:
        con_flush();
        vpi_printf("[platform] HOST FATAL: %s\n", cpu.fatal_msg);
        exited = 1;
        exit_code = 255;
        roi_report();
        return 4;
    }
  }
  return 0;
}

void host_mmio_req(int *addr, int *wdata, int *is_write) {
  *addr     = (int)mmio_addr;
  *wdata    = (int)mmio_wdata;
  *is_write = mmio_write;
}

void host_mmio_resp(int rdata, int err) {
  mmio_rdata = (uint32_t)rdata;
  mmio_err   = err;
  mmio_state = MMIO_DONE;
}

int host_exit_code(void) { return exit_code; }

long long host_instret(void) { return (long long)cpu.instret; }

// ============================================================================
// DPI-C interface: HBM backing store (used by sim/tb/hbm_model.sv)
// ============================================================================
int hbm_addr_ok(int addr, int bytes) {
  return in_range((uint32_t)addr, (uint32_t)bytes, HBM_BASE, HBM_SIZE);
}

int hbm_read32(int addr) {
  uint8_t b[4];
  if (mem_access((uint32_t)addr, b, 4, 0) != 0) return 0;
  return (int)((uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24));
}

void hbm_write32(int addr, int data, int strb) {
  for (int i = 0; i < 4; i++) {
    if (strb & (1 << i)) {
      uint8_t v = (uint8_t)((uint32_t)data >> (8 * i));
      mem_access((uint32_t)addr + (uint32_t)i, &v, 1, 1);
    }
  }
}
