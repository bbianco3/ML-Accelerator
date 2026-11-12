// multicore -- several compute cores running one kernel: core ids, the core
// count, barriers (with deliberately unbalanced cores), a parallel vector add,
// launching fewer cores than exist, and stopping every core when one fails.
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

extern void mc_basic(void), mc_abort(void);
extern char pc_mc_abort[];

#define ROUNDS 3

struct mc_params {            // layout must match kernel.S
  uint32_t ids, slots, sums, rounds, x, y, z, per_core;
};
static struct mc_params params HBM_BUF;
static uint32_t ids[32] HBM_BUF;
static uint32_t slots[16] HBM_BUF;
static uint32_t sums[ROUNDS * 16] HBM_BUF;

static int run_basic(const accel_config_t *cfg, uint32_t ncores, bf16_t *x, bf16_t *y, bf16_t *z,
                     uint32_t per_core) {
  int errors = 0;
  memset(ids, 0xFF, sizeof ids);
  memset(sums, 0xFF, sizeof sums);
  memset(z, 0xFF, ncores * per_core * 2);
  params = (struct mc_params){(uint32_t)(uintptr_t)ids, (uint32_t)(uintptr_t)slots, (uint32_t)(uintptr_t)sums, ROUNDS,
                              (uint32_t)(uintptr_t)x,   (uint32_t)(uintptr_t)y,     (uint32_t)(uintptr_t)z,    per_core};
  uint32_t args[] = {(uint32_t)(uintptr_t)&params};
  uint32_t st = accel_run_cores(mc_basic, args, 1, ncores);
  if (st & ACCEL_STATUS_ERROR) return 1;
  uint32_t cyc = (uint32_t)accel_cycles();

  for (uint32_t c = 0; c < ncores; c++) {
    if (ids[2 * c] != c || ids[2 * c + 1] != ncores) {
      printf("  core %u: mhartid=%u ncores=%u\n", c, ids[2 * c], ids[2 * c + 1]);
      errors++;
    }
    for (uint32_t r = 0; r < ROUNDS; r++) {
      uint32_t want = (r + 1) * ncores * (ncores + 1) / 2;
      if (sums[r * 16 + c] != want) {
        printf("  round %u core %u: sum %u, expected %u (barrier broken?)\n", r, c,
               sums[r * 16 + c], want);
        errors++;
      }
    }
  }
  if (ids[2 * ncores] != 0xFFFFFFFFu) {
    printf("  core %u ran although only %u were launched\n", ncores, ncores);
    errors++;
  }
  for (uint32_t i = 0; i < ncores * per_core; i++) {
    bf16_t exp = bf16_add(x[i], y[i]);
    if (z[i] != exp) {
      if (errors < 10) printf("  z[%u]: got 0x%04x expected 0x%04x\n", i, z[i], exp);
      errors++;
    }
  }
  printf("%u of %u cores: ids, %d barrier rounds, vadd of %u elements: %s (%u cycles)\n", ncores,
         cfg->num_cores, ROUNDS, ncores * per_core, errors ? "WRONG" : "ok", cyc);
  return errors;
}

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  int errors = 0;

  const uint32_t per_core = 2 * cfg.vlmax;
  const uint32_t n = cfg.num_cores * per_core;
  bf16_t *x = hbm_alloc(n * 2, HBM_ALIGN);
  bf16_t *y = hbm_alloc(n * 2, HBM_ALIGN);
  bf16_t *z = hbm_alloc(n * 2 + 64, HBM_ALIGN);
  srand_(11);
  for (uint32_t i = 0; i < n; i++) {
    x[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
    y[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
  }

  errors += run_basic(&cfg, 1, x, y, z, per_core);
  // run_basic uses the vector unit: all cores that have one
  if (cfg.num_vpus > 1) errors += run_basic(&cfg, cfg.num_vpus, x, y, z, per_core);

  // Requests beyond NUM_CORES are clamped.
  accel_wr(ACCEL_CORES, 1000);
  if (accel_rd(ACCEL_CORES) != cfg.num_cores) {
    printf("CORES register did not clamp: %u\n", accel_rd(ACCEL_CORES));
    errors++;
  }

  // One failing core stops the others and is the one reported.
  if (cfg.num_cores > 1) {
    accel_launch_cores(mc_abort, 0, 0, cfg.num_cores);
    uint32_t st = accel_wait();
    uint32_t core = accel_rd(ACCEL_ERR_CORE), pc = accel_rd(ACCEL_ERR_PC);
    int ok = (st & ACCEL_STATUS_ERROR) && ACCEL_STATUS_CAUSE(st) == ACCEL_ERR_EBREAK &&
             core == 1 && pc == (uint32_t)(uintptr_t)pc_mc_abort;
    printf("core 1 fails while the others spin / wait: status=0x%08x core=%u pc=0x%08x: %s\n",
           st, core, pc, ok ? "ok" : "WRONG");
    if (!ok) errors++;
  }

  // ... and everything still works afterwards.
  errors += run_basic(&cfg, cfg.num_vpus, x, y, z, per_core);

  printf("multicore: %d errors\n", errors);
  return errors ? 1 : 0;
}
