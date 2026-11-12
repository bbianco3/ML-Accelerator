// rv64_iss.h -- small RV64G (RV64IMAFD + Zicsr + Zifencei) instruction-set
// simulator used as the *host CPU* in simulation. The ISS is functional
// only; time and energy come from sim/csrc/host_model.c, which consumes the
// per-instruction event record (c->ev). See docs/host-model.md.
#ifndef RV64_ISS_H
#define RV64_ISS_H

#include <stdint.h>

// Result of a bus access performed by the ISS.
typedef enum {
  MEM_OK = 0,       // access completed
  MEM_PENDING,      // access forwarded to the RTL; retry the instruction later
  MEM_FAULT,        // access fault (unmapped / unsupported)
  MEM_EXIT          // store hit the simulation-exit register
} mem_status_t;

// size is 1, 2, 4 or 8 bytes; data is zero-extended.
typedef struct {
  mem_status_t (*load)(void *ctx, uint64_t addr, int size, uint64_t *data);
  mem_status_t (*store)(void *ctx, uint64_t addr, int size, uint64_t data);
  void (*log)(void *ctx, const char *msg);
  void *ctx;
} rv64_bus_t;

typedef enum {
  ISS_OK = 0,       // instruction retired (or trap taken)
  ISS_PENDING,      // waiting for an MMIO access to complete in the RTL
  ISS_EXIT,         // program wrote SIMCTRL_EXIT
  ISS_WFI,          // stalled in WFI, no interrupt pending
  ISS_FATAL         // unhandled exception (no mtvec installed)
} iss_status_t;

// What the last retired instruction did (input of the timing/energy model).
typedef enum {
  EV_ALU = 0,       // integer ALU, LUI/AUIPC, FENCE
  EV_BRANCH,        // conditional branch
  EV_JUMP,          // JAL / JALR
  EV_LOAD,
  EV_STORE,         // stores and AMOs
  EV_MUL,
  EV_DIV,
  EV_FP,            // FP add/sub/compare/convert/move
  EV_FMUL,
  EV_FMA,
  EV_FDIV,          // FP divide / square root
  EV_SYS,           // CSR access, MRET, WFI, ECALL
  EV_TRAP,          // exception or interrupt entry
  EV_NUM_CLASSES
} ev_class_t;

enum { EV_MEM_NONE = 0, EV_MEM_LOAD, EV_MEM_STORE };

typedef struct {
  ev_class_t cls;
  int        mem;        // EV_MEM_*: the instruction accessed memory at addr
  uint64_t   addr;
  uint64_t   pc, target; // this instruction's pc and the next pc
  int        taken;      // EV_BRANCH: branch taken
  int        indirect;   // JALR / MRET
  int        is_ret;     // JALR x0, ra (function return)
} iss_event_t;

typedef struct {
  uint64_t x[32];
  uint64_t f[32];          // FP registers (singles are NaN-boxed)
  uint64_t pc;
  uint32_t fcsr;           // frm[7:5] | fflags[4:0]
  uint64_t mstatus, mie, mip, mtvec, mepc, mcause, mtval, mscratch;
  uint64_t instret;
  uint64_t cycle;          // supplied by the testbench every step
  int      lr_valid;
  uint64_t lr_addr;
  int      trace;          // print every executed instruction
  iss_event_t ev;          // valid after rv64_step() returned ISS_OK
  rv64_bus_t bus;
  char     fatal_msg[256];
} rv64_cpu_t;

void         rv64_init(rv64_cpu_t *c, uint64_t pc, rv64_bus_t bus);
void         rv64_set_meip(rv64_cpu_t *c, int level);
iss_status_t rv64_step(rv64_cpu_t *c);

#endif // RV64_ISS_H
