// errors -- error reporting: every STATUS.ERR_CAUSE, ERR_PC, ERR_INSN, the
// write-1-to-clear STATUS bits, the interrupt path and recovery afterwards.
#include "accel.h"
#include "runtime.h"

extern void k_ebreak(void), k_misaligned_vle(void), k_misaligned_lw(void),
    k_misaligned_mld(void), k_illegal(void), k_bus(void), k_bad_reg(void), k_ok(void);
extern char pc_ebreak[], pc_misaligned_vle[], pc_misaligned_lw[], pc_misaligned_mld[],
    pc_illegal[], pc_bus[], pc_bad_reg[];

static uint32_t buf[64] HBM_BUF;

struct err_case {
  const char *name;
  accel_kernel_t k;
  const char *pc;
  uint32_t cause;
};

int main(void) {
  const struct err_case cases[] = {
    {"ebreak",         k_ebreak,         pc_ebreak,         ACCEL_ERR_EBREAK},
    {"misaligned vle", k_misaligned_vle, pc_misaligned_vle, ACCEL_ERR_MISALIGNED},
    {"misaligned lw",  k_misaligned_lw,  pc_misaligned_lw,  ACCEL_ERR_MISALIGNED},
    {"misaligned mld", k_misaligned_mld, pc_misaligned_mld, ACCEL_ERR_MISALIGNED},
    {"illegal",        k_illegal,        pc_illegal,        ACCEL_ERR_ILLEGAL},
    {"bus error",      k_bus,            pc_bus,            ACCEL_ERR_BUS},
    {"bad register",   k_bad_reg,        pc_bad_reg,        ACCEL_ERR_BAD_REG},
  };
  int errors = 0;

  for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    const struct err_case *c = &cases[i];
    uint32_t args[] = {(uint32_t)(uintptr_t)buf, 6};
    accel_launch(c->k, args, 2);
    uint32_t st = (i & 1) ? accel_wait_irq() : accel_wait();   // alternate both wait styles
    uint32_t pc = accel_rd(ACCEL_ERR_PC), insn = accel_rd(ACCEL_ERR_INSN);
    uint32_t want_insn = *(const uint32_t *)c->pc;
    int ok = (st & ACCEL_STATUS_ERROR) && ACCEL_STATUS_CAUSE(st) == c->cause &&
             pc == (uint32_t)(uintptr_t)c->pc;
    // ERR_INSN is reported for everything except ebreak/fetch faults
    if (c->cause != ACCEL_ERR_EBREAK && insn != want_insn) ok = 0;
    printf("%-15s status=0x%08x cause=%u (%s) pc=0x%08x insn=0x%08x : %s\n", c->name, st,
           ACCEL_STATUS_CAUSE(st), accel_cause_str(ACCEL_STATUS_CAUSE(st)), pc, insn,
           ok ? "ok" : "WRONG");
    if (!ok) errors++;
  }

  // STATUS bits are write-1-to-clear.
  accel_wr(ACCEL_STATUS, ACCEL_STATUS_DONE | ACCEL_STATUS_ERROR);
  uint32_t st = accel_rd(ACCEL_STATUS);
  if (st != 0) {
    printf("STATUS after W1C = 0x%08x (expected 0)\n", st);
    errors++;
  }

  // And a normal kernel still works afterwards.
  buf[0] = 0;
  uint32_t args[] = {(uint32_t)(uintptr_t)buf};
  st = accel_run(k_ok, args, 1);
  if ((st & ACCEL_STATUS_ERROR) || buf[0] != 42) {
    printf("recovery kernel failed: status=0x%08x buf[0]=%u\n", st, buf[0]);
    errors++;
  }

  printf("errors: %d problems\n", errors);
  return errors ? 1 : 0;
}
