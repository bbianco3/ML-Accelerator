// units -- cores with different units (NUM_VPUS / NUM_MXUS).
//
// Cores 0 .. NUM_VPUS-1 have a vector unit and cores 0 .. NUM_MXUS-1 a matrix
// unit; every core has its own control core and scratchpad. Units of
// different cores do not depend on each other, so they all work at once.
//   1. Every core reports CSR_UNITS and does the work its units allow:
//      y = x + x on a VPU, C = A x A on an MXU, in one launch.
//   2. A vector (matrix) instruction on a core without a VPU (MXU) stops the
//      run with an illegal-instruction error naming that core.
// Try: make run TEST=units NUM_CORES=4 NUM_VPUS=1 NUM_MXUS=4
#include "accel.h"
#include "bf16.h"
#include "check.h"
#include "runtime.h"

extern void units_work(void), units_vec(void), units_mat(void);
extern const char pc_units_vec[], pc_units_mat[];

#define MAX_CORES 16
#define MAX_DIM 64
static uint32_t out[MAX_CORES] HBM_BUF;

// Launch `k` on all cores; cores >= first_without must fault with ILLEGAL at pc.
static int expect_illegal(const char *what, accel_kernel_t k, const char *pc, uint32_t ncores,
                          uint32_t first_without) {
  accel_launch_cores(k, 0, 0, ncores);
  uint32_t st = accel_wait();
  uint32_t core = accel_rd(ACCEL_ERR_CORE), epc = accel_rd(ACCEL_ERR_PC);
  int ok;
  if (first_without >= ncores)       // every core has the unit: must simply finish
    ok = !(st & ACCEL_STATUS_ERROR);
  else
    ok = (st & ACCEL_STATUS_ERROR) && ACCEL_STATUS_CAUSE(st) == ACCEL_ERR_ILLEGAL &&
         core >= first_without && core < ncores && epc == (uint32_t)(uintptr_t)pc;
  printf("%s instruction on all %u cores (%u have the unit): status=0x%08x core=%u : %s\n", what,
         ncores, first_without < ncores ? first_without : ncores, st, core, ok ? "ok" : "WRONG");
  return ok ? 0 : 1;
}

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  const uint32_t NC = cfg.num_cores, VL = cfg.vlmax, D = cfg.mat_dim;
  int errors = 0;
  if (NC > MAX_CORES || D > MAX_DIM) return 1;

  bf16_t *x = hbm_alloc(NC * VL * 2, HBM_ALIGN), *y = hbm_alloc(NC * VL * 2, HBM_ALIGN);
  const uint32_t stride = D * 2, tile_bytes = D * D * 2;
  bf16_t *A = hbm_alloc(tile_bytes, HBM_ALIGN), *C = hbm_alloc(NC * tile_bytes, HBM_ALIGN);
  srand_(5);
  for (uint32_t i = 0; i < NC * VL; i++) {
    x[i] = f32_to_bf16(rand_float(-4.0f, 4.0f));
    y[i] = 0xBEEF;
  }
  for (uint32_t i = 0; i < D * D; i++) A[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
  for (uint32_t i = 0; i < NC * D * D; i++) C[i] = 0xBEEF;
  memset(out, 0xFF, sizeof out);

  // ---- 1. one launch, every unit busy ----
  uint32_t args[] = {(uint32_t)(uintptr_t)out, (uint32_t)(uintptr_t)x, (uint32_t)(uintptr_t)y,
                     (uint32_t)(uintptr_t)A,   stride,                 (uint32_t)(uintptr_t)C,
                     tile_bytes};
  uint32_t st = accel_run_cores(units_work, args, 7, NC);
  if (st & ACCEL_STATUS_ERROR) return 1;
  printf("%u VPU(s) and %u MXU(s) on %u cores worked in parallel: %u cycles\n", cfg.num_vpus,
         cfg.num_mxus, NC, (uint32_t)accel_cycles());

  static float ref[MAX_DIM * MAX_DIM];
  for (uint32_t i = 0; i < D * D; i++) ref[i] = 0.0f;
  mxu_matmul_ref(ref, (int)D, A, (int)D, A, (int)D, (int)D, (int)D, (int)D);

  for (uint32_t c = 0; c < NC; c++) {
    uint32_t has_vpu = c < cfg.num_vpus, has_mxu = c < cfg.num_mxus;
    int bad = 0;
    if (out[c] != (has_vpu | (has_mxu << 1))) bad++;
    for (uint32_t i = 0; i < VL; i++) {            // element-wise: exact; no VPU: untouched
      bf16_t got = y[c * VL + i], exp = has_vpu ? bf16_add(x[c * VL + i], x[c * VL + i]) : 0xBEEF;
      if (got != exp) bad++;
    }
    for (uint32_t i = 0; i < D * D; i++) {         // matrix: within tolerance; no MXU: untouched
      bf16_t got = C[c * D * D + i];
      if (has_mxu ? !bf16_close(got, f32_to_bf16(ref[i])) : got != 0xBEEF) bad++;
    }
    printf("  core %u: CSR_UNITS=%u (%s%s%s): %s\n", c, out[c], has_vpu ? "VPU" : "",
           has_vpu && has_mxu ? "+" : "", has_mxu ? "MXU" : (has_vpu ? "" : "scalar only"),
           bad ? "WRONG" : "ok");
    errors += bad;
  }

  // ---- 2. instructions for a unit the core does not have ----
  errors += expect_illegal("vector", units_vec, pc_units_vec, NC, cfg.num_vpus);
  errors += expect_illegal("matrix", units_mat, pc_units_mat, NC, cfg.num_mxus);

  // ... and the accelerator still works afterwards
  st = accel_run_cores(units_work, args, 7, NC);
  if (st & ACCEL_STATUS_ERROR) errors++;

  printf("units: %d errors\n", errors);
  return errors ? 1 : 0;
}
