// gemm_tiled -- a GEMM larger than the matrix unit, C = relu(A x B), broken
// into MAT_DIM x MAT_DIM tiles, run three ways:
//   1. one core, B read from HBM for every tile product
//   2. one core, each B column panel copied into the scratchpad once
//   3. every core (column tiles split between cores), with the scratchpad
// All three must match the reference (within the tolerance of check.h); the
// cycle counts show what each step buys.
#include "accel.h"
#include "bf16.h"
#include "check.h"
#include "runtime.h"

extern void gemm_tiled(void);

struct gemm_params {          // layout must match kernel.S
  uint32_t A, B, C;
  uint32_t mt, nt, kt;
  uint32_t lda, ldb, ldc;
  uint32_t row_bytes, tile_bytes, tile_elems;
  uint32_t b_rowtile, c_rowtile;
  uint32_t use_spad;
  uint32_t a_rowtile;
};
static struct gemm_params params HBM_BUF;

static int check(const bf16_t *C, const bf16_t *exp, int n) {
  int errors = 0;
  for (int i = 0; i < n; i++)
    if (!bf16_close(C[i], exp[i])) {
      if (errors < 10) printf("  C[%d]: got 0x%04x expected 0x%04x\n", i, C[i], exp[i]);
      errors++;
    }
  return errors;
}

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  const int D = (int)cfg.mat_dim;
  const uint32_t tile_bytes = (uint32_t)(D * D * 2), vbytes = cfg.vlen / 8;
  if (cfg.spad_bytes < tile_bytes || cfg.spad_bytes < vbytes) {
    printf("SKIP: needs a scratchpad of at least one tile (SPAD_KB=%u)\n", cfg.spad_bytes / 1024);
    return 0;
  }

  // 64 x 64 x 64 for MAT_DIM <= 32 (more tiles than cores), 2 x 2 x 2 tiles above.
  int t = 64 / D;
  if (t < 2) t = 2;
  if (t > 8) t = 8;
  const int MT = t, NT = t, KT = t;
  const int M = MT * D, N = NT * D, K = KT * D;
  const int spad_fits = (uint32_t)(KT + 1) * tile_bytes <= cfg.spad_bytes;

  bf16_t *A = hbm_alloc((uint32_t)(M * K * 2), HBM_ALIGN);
  bf16_t *B = hbm_alloc((uint32_t)(K * N * 2), HBM_ALIGN);
  bf16_t *C = hbm_alloc((uint32_t)(M * N * 2), HBM_ALIGN);
  bf16_t *E = hbm_alloc((uint32_t)(M * N * 2), HBM_ALIGN);
  float *ref = hbm_alloc((uint32_t)(M * N * 4), HBM_ALIGN);
  srand_(99);
  for (int i = 0; i < M * K; i++) A[i] = f32_to_bf16(rand_float(-1.0f, 1.0f));
  for (int i = 0; i < K * N; i++) B[i] = f32_to_bf16(rand_float(-1.0f, 1.0f));
  for (int i = 0; i < M * N; i++) ref[i] = 0.0f;
  mxu_matmul_ref(ref, N, A, K, B, N, M, N, K);
  for (int i = 0; i < M * N; i++) E[i] = bf16_max(f32_to_bf16(ref[i]), 0x0000);

  printf("C[%dx%d] = relu(A[%dx%d] x B[%dx%d]) in %dx%d tiles; B panel (%u B) %s the %u B scratchpad\n",
         M, N, M, K, K, N, D, D, (uint32_t)KT * tile_bytes, spad_fits ? "fits in" : "does NOT fit in",
         cfg.spad_bytes);

  struct { const char *name; uint32_t cores, spad; } runs[] = {
    {"1 core,  B from HBM       ", 1, 0},
    {"1 core,  B in scratchpad  ", 1, 1},
    {"all cores, B in scratchpad", cfg.num_full_cores, 1},   // cores with VPU + MXU
  };
  const uint32_t macs = (uint32_t)(M * N * K);
  uint32_t base = 0;
  int errors = 0;
  for (int r = 0; r < 3; r++) {
    if (runs[r].spad && !spad_fits) runs[r].spad = 0;
    params = (struct gemm_params){
      .A = (uint32_t)(uintptr_t)A, .B = (uint32_t)(uintptr_t)B, .C = (uint32_t)(uintptr_t)C,
      .mt = MT, .nt = NT, .kt = KT,
      .lda = (uint32_t)K * 2, .ldb = (uint32_t)N * 2, .ldc = (uint32_t)N * 2,
      .row_bytes = (uint32_t)D * 2, .tile_bytes = tile_bytes, .tile_elems = (uint32_t)(D * D),
      .b_rowtile = (uint32_t)(D * N * 2), .c_rowtile = (uint32_t)(D * N * 2),
      .use_spad = runs[r].spad, .a_rowtile = (uint32_t)(D * K * 2),
    };
    memset(C, 0xFF, (size_t)(M * N * 2));
    uint32_t args[] = {(uint32_t)(uintptr_t)&params};
    uint32_t st = accel_run_cores(gemm_tiled, args, 1, runs[r].cores);
    if (st & ACCEL_STATUS_ERROR) return 1;
    uint32_t cyc = (uint32_t)accel_cycles();
    if (r == 0) base = cyc;
    int e = check(C, E, M * N);
    errors += e;
    printf("%s (%u core%s, spad=%u): %8u cycles, %u.%02u MACs/cycle, %u.%02ux vs run 1 : %s\n",
           runs[r].name, runs[r].cores, runs[r].cores > 1 ? "s" : "", runs[r].spad, cyc, macs / cyc,
           (macs % cyc) * 100 / cyc, base / cyc, (base % cyc) * 100 / cyc, e ? "WRONG" : "ok");
  }

  printf("gemm_tiled: %d errors\n", errors);
  return errors ? 1 : 0;
}
