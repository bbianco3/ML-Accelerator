// layouts -- the same GEMM (C = A x B) with A, B and C each stored
// row-major, column-major or blocked: all 27 combinations must give
// bit-identical results. Exercises mld.t / msta.t and sw/common/mat_layout.h.
#include "accel.h"
#include "bf16.h"
#include "check.h"
#include "mat_layout.h"
#include "runtime.h"

extern void layout_gemm_kernel(void);

#define MT 2
#define NT 2
#define KT 2
#define MAX_DIM 32

struct layout_gemm_params {     // layout must match kernel.S
  mat_tile_desc_t a, b, c;
  uint32_t mt, nt, kt;
};
static struct layout_gemm_params params HBM_BUF;

static bf16_t A_src[MT * MAX_DIM * KT * MAX_DIM];
static bf16_t B_src[KT * MAX_DIM * NT * MAX_DIM];
static float  ref[MT * MAX_DIM * NT * MAX_DIM];

int main(void) {
  accel_config_t cfg = accel_get_config();
  const uint32_t T = cfg.mat_dim;
  if (T > MAX_DIM) {
    printf("layouts: MAT_DIM > %d not supported by this test -- skipping\n", MAX_DIM);
    return 0;
  }
  const uint32_t M = MT * T, N = NT * T, K = KT * T;

  srand_(99);
  for (uint32_t i = 0; i < M * K; i++) A_src[i] = f32_to_bf16(rand_float(-1.0f, 1.0f));
  for (uint32_t i = 0; i < K * N; i++) B_src[i] = f32_to_bf16(rand_float(-1.0f, 1.0f));
  for (uint32_t i = 0; i < M * N; i++) ref[i] = 0.0f;
  mxu_matmul_ref(ref, (int)N, A_src, (int)K, B_src, (int)N, (int)M, (int)N, (int)K);

  // One copy of every operand in every layout (ROW/COL major padded by one tile).
  mat_t A[3], B[3], C[3];
  for (int l = 0; l < 3; l++) {
    A[l] = mat_alloc(M, K, (mat_layout_t)l, T, T);
    B[l] = mat_alloc(K, N, (mat_layout_t)l, T, T);
    C[l] = mat_alloc(M, N, (mat_layout_t)l, T, T);
    mat_from_rowmajor(&A[l], A_src, K);
    mat_from_rowmajor(&B[l], B_src, N);
  }

  int errors = 0;
  for (int la = 0; la < 3; la++)
    for (int lb = 0; lb < 3; lb++)
      for (int lc = 0; lc < 3; lc++) {
        mat_fill(&C[lc], 0xDEAD);
        params.a  = mat_tile_desc(&A[la]);
        params.b  = mat_tile_desc(&B[lb]);
        params.c  = mat_tile_desc(&C[lc]);
        params.mt = MT; params.nt = NT; params.kt = KT;

        uint32_t args[] = {(uint32_t)(uintptr_t)&params};
        uint32_t st = accel_run(layout_gemm_kernel, args, 1);
        if (st & ACCEL_STATUS_ERROR) return 1;

        int bad = 0;
        for (uint32_t r = 0; r < M; r++)
          for (uint32_t c = 0; c < N; c++) {
            bf16_t got = mat_get(&C[lc], r, c), exp = f32_to_bf16(ref[r * N + c]);
            if (!bf16_close(got, exp)) {
              if (bad < 3) printf("    C[%u][%u]: got 0x%04x expected 0x%04x\n", r, c, got, exp);
              bad++;
            }
          }
        printf("A %-9s B %-9s C %-9s : %6u cycles  %s\n", mat_layout_name((mat_layout_t)la),
               mat_layout_name((mat_layout_t)lb), mat_layout_name((mat_layout_t)lc),
               (uint32_t)accel_cycles(), bad ? "MISMATCH" : "ok");
        errors += bad;
      }

  printf("layouts: %d errors\n", errors);
  return errors ? 1 : 0;
}
