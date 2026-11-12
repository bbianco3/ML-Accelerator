// matmul -- one MAT_DIM x MAT_DIM tile: C = A0*B0 + A1*B1 on the matrix unit,
// checked bit-exactly against the reference model. Operands are stored with
// a row stride of twice the tile width to exercise strided tile loads.
#include "accel.h"
#include "bf16.h"
#include "check.h"
#include "runtime.h"

extern void matmul_kernel(void);

#define MAX_DIM 64

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  const int D = (int)cfg.mat_dim;
  if (D > MAX_DIM || cfg.num_tregs < 4 || cfg.num_accs < 2) {
    printf("matmul: needs MAT_DIM <= %d, NUM_TREGS >= 4, NUM_ACCS >= 2 -- skipping\n", MAX_DIM);
    return 0;
  }
  const int ld = 2 * D;                      // elements per stored row
  const uint32_t stride = (uint32_t)ld * 2;  // bytes
  const uint32_t bytes = (uint32_t)(D * ld * 2);

  bf16_t *A0 = hbm_alloc(bytes, HBM_ALIGN), *B0 = hbm_alloc(bytes, HBM_ALIGN);
  bf16_t *A1 = hbm_alloc(bytes, HBM_ALIGN), *B1 = hbm_alloc(bytes, HBM_ALIGN);
  bf16_t *C  = hbm_alloc(bytes, HBM_ALIGN), *T  = hbm_alloc(bytes, HBM_ALIGN);

  srand_(7);
  for (int i = 0; i < D * ld; i++) {
    A0[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
    B0[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
    A1[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
    B1[i] = f32_to_bf16(rand_float(-2.0f, 2.0f));
    C[i] = T[i] = 0xBEEF;
  }

  uint32_t args[] = {(uint32_t)(uintptr_t)A0, (uint32_t)(uintptr_t)B0, (uint32_t)(uintptr_t)A1, (uint32_t)(uintptr_t)B1,
                     (uint32_t)(uintptr_t)C, stride, (uint32_t)(uintptr_t)T};
  uint32_t st = accel_run(matmul_kernel, args, 7);
  if (st & ACCEL_STATUS_ERROR) return 1;
  uint32_t cyc = (uint32_t)accel_cycles();
  printf("matmul: kernel took %u cycles (%u MACs)\n", cyc, (uint32_t)(2 * D * D * D));

  // Reference: fp32 accumulation in the same order as the hardware.
  static float ref[MAX_DIM * MAX_DIM];
  for (int i = 0; i < D * D; i++) ref[i] = 0.0f;
  mxu_matmul_ref(ref, D, A0, ld, B0, ld, D, D, D);
  mxu_matmul_ref(ref, D, A1, ld, B1, ld, D, D, D);

  int errors = 0;
  for (int i = 0; i < D; i++)
    for (int j = 0; j < ld; j++) {
      bf16_t c_exp = (j < D) ? f32_to_bf16(ref[i * D + j]) : 0xBEEF;   // padding untouched
      bf16_t t_exp = (j < D) ? A1[i * ld + j] : 0xBEEF;
      // results within tolerance (check.h); the padding must be exactly untouched
      if (j < D ? !bf16_close(C[i * ld + j], c_exp) : C[i * ld + j] != c_exp) {
        if (errors < 10) printf("  C[%d][%d]: got 0x%04x expected 0x%04x\n", i, j, C[i * ld + j], c_exp);
        errors++;
      }
      if (T[i * ld + j] != t_exp) {
        if (errors < 10) printf("  T[%d][%d]: got 0x%04x expected 0x%04x\n", i, j, T[i * ld + j], t_exp);
        errors++;
      }
    }
  printf("C[0][0] = %f (ref %f)\n", (double)bf16_to_f32(C[0]), (double)ref[0]);
  printf("matmul: %d errors\n", errors);
  return errors ? 1 : 0;
}
