// gemm -- tiled C = relu(A x B) using the matrix unit for the products and
// the vector unit for the activation. Problem size is a multiple of the
// hardware tile size (MAT_DIM), read from the accelerator at runtime.
// Also demonstrates interrupt-driven completion (accel_wait_irq).
#include "accel.h"
#include "bf16.h"
#include "check.h"
#include "runtime.h"

extern void gemm_kernel(void);

// Problem size in tiles.
#define MT 2
#define NT 2
#define KT 3

struct gemm_params {          // layout must match kernel.S
  uint32_t A, B, C;
  uint32_t mt, nt, kt;
  uint32_t lda, ldb, ldc;     // bytes per row
  uint32_t a_rowtile, b_rowtile, c_rowtile;
  uint32_t tile_bytes;        // MAT_DIM * 2
  uint32_t n_elems, relu;
};

static struct gemm_params params HBM_BUF;

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  const int D = (int)cfg.mat_dim;
  const int M = MT * D, N = NT * D, K = KT * D;

  bf16_t *A = hbm_alloc((uint32_t)(M * K * 2), HBM_ALIGN);
  bf16_t *B = hbm_alloc((uint32_t)(K * N * 2), HBM_ALIGN);
  bf16_t *C = hbm_alloc((uint32_t)(M * N * 2) + cfg.vlen / 8, HBM_ALIGN);  // + room for the last vector load

  srand_(2024);
  for (int i = 0; i < M * K; i++) A[i] = f32_to_bf16(rand_float(-1.0f, 1.0f));
  for (int i = 0; i < K * N; i++) B[i] = f32_to_bf16(rand_float(-1.0f, 1.0f));

  params = (struct gemm_params){
    .A = (uint32_t)(uintptr_t)A, .B = (uint32_t)(uintptr_t)B, .C = (uint32_t)(uintptr_t)C,
    .mt = MT, .nt = NT, .kt = KT,
    .lda = (uint32_t)K * 2, .ldb = (uint32_t)N * 2, .ldc = (uint32_t)N * 2,
    .a_rowtile = (uint32_t)(D * K * 2), .b_rowtile = (uint32_t)(D * N * 2),
    .c_rowtile = (uint32_t)(D * N * 2), .tile_bytes = (uint32_t)D * 2,
    .n_elems = (uint32_t)(M * N), .relu = 1,
  };

  uint32_t args[] = {(uint32_t)(uintptr_t)&params};
  accel_launch(gemm_kernel, args, 1);
  uint32_t st = accel_wait_irq();
  if (st & ACCEL_STATUS_ERROR) {
    accel_report_error(st);
    return 1;
  }
  uint32_t cyc = (uint32_t)accel_cycles();
  uint32_t macs = (uint32_t)(M * N * K);
  printf("gemm %dx%dx%d: %u cycles, %u MACs, %u.%02u MACs/cycle\n", M, N, K, cyc, macs,
         macs / cyc, (macs % cyc) * 100 / cyc);

  // Reference
  float *ref = hbm_alloc((uint32_t)(M * N * 4), HBM_ALIGN);   // any memory works for the host
  for (int i = 0; i < M * N; i++) ref[i] = 0.0f;
  mxu_matmul_ref(ref, N, A, K, B, N, M, N, K);

  int errors = 0;
  for (int i = 0; i < M * N; i++) {
    bf16_t exp = bf16_max(f32_to_bf16(ref[i]), 0x0000);
    if (!bf16_close(C[i], exp)) {
      if (errors < 10) printf("  C[%d][%d]: got 0x%04x expected 0x%04x\n", i / N, i % N, C[i], exp);
      errors++;
    }
  }
  printf("gemm: %d errors\n", errors);
  return errors ? 1 : 0;
}
