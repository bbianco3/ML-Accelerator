// vector_ops -- checks every vector instruction against the bf16 reference
// model, for several vector lengths and with special values (NaN, inf,
// subnormals, signed zeros) mixed into the inputs.
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

#define NUM_BLOCKS 20

extern void vector_ops_kernel(void);

static bf16_t rand_bf16(void) {
  static const bf16_t special[] = {0x0000, 0x8000, 0x7F80, 0xFF80, 0x7FC0, 0xFFC1,
                                   0x0001, 0x8042, 0x7F7F, 0xFF7F, 0x0080, 0x3F80};
  uint32_t r = rand_u32();
  switch (r % 10) {
    case 0:  return special[(r >> 8) % (sizeof special / sizeof special[0])];
    case 1:  return (bf16_t)(r >> 16);                       // any bit pattern
    default: return f32_to_bf16(rand_float(-8.0f, 8.0f));
  }
}

// Expected value of element i of output block k.
static bf16_t expect(int k, int i, int vl, const bf16_t *A, const bf16_t *B,
                     const bf16_t *C, bf16_t s) {
  if (k >= 12 && k <= 15) {                 // reductions: only element 0
    if (i != 0 || vl == 0) return C[i];
    switch (k) {
      case 12: return bf16_redsum(B[0], A, vl);
      case 13: return bf16_redmax(B[0], A, vl);
      case 14: return bf16_redsum(s, A, vl);
      default: return bf16_redmax(s, A, vl);
    }
  }
  if (k == 18) return (i == 0 && vl > 0) ? s : C[i];
  if (i >= vl) return C[i];                 // tail undisturbed
  switch (k) {
    case 0:  return bf16_add(A[i], B[i]);
    case 1:  return bf16_sub(A[i], B[i]);
    case 2:  return bf16_mul(A[i], B[i]);
    case 3:  return bf16_max(A[i], B[i]);
    case 4:  return bf16_min(A[i], B[i]);
    case 5:  return bf16_macc(C[i], A[i], B[i]);
    case 6:  return bf16_add(A[i], s);
    case 7:  return bf16_sub(A[i], s);
    case 8:  return bf16_mul(A[i], s);
    case 9:  return bf16_max(A[i], s);
    case 10: return bf16_min(A[i], s);
    case 11: return bf16_macc(C[i], A[i], s);
    case 16: return A[i];
    case 17: return s;
    case 19: return bf16_add(C[i], A[i]);
    default: return 0;
  }
}

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  const int vlmax = (int)cfg.vlmax;
  const uint32_t vbytes = cfg.vlen / 8;

  bf16_t *A    = hbm_alloc(vbytes, vbytes);
  bf16_t *B    = hbm_alloc(vbytes, vbytes);
  bf16_t *C    = hbm_alloc(vbytes, vbytes);
  bf16_t *out  = hbm_alloc(vbytes * NUM_BLOCKS, vbytes);
  uint32_t *so = hbm_alloc(16, 16);

  const int vls[] = {vlmax, vlmax - 1, vlmax / 2 + 1, 1, 0};
  int errors = 0;
  srand_(42);

  for (unsigned t = 0; t < sizeof vls / sizeof vls[0]; t++) {
    int vl = vls[t];
    for (int i = 0; i < vlmax; i++) {
      A[i] = rand_bf16();
      B[i] = rand_bf16();
      C[i] = rand_bf16();
    }
    bf16_t s = (t == 3) ? 0x0000 : rand_bf16();   // t==3: vfmax.vf with +0 = ReLU
    memset(out, 0xEE, vbytes * NUM_BLOCKS);

    uint32_t args[] = {(uint32_t)(uintptr_t)A, (uint32_t)(uintptr_t)B, (uint32_t)(uintptr_t)C, (uint32_t)(uintptr_t)out,
                       s, (uint32_t)vl, (uint32_t)(uintptr_t)so};
    uint32_t st = accel_run(vector_ops_kernel, args, 7);
    if (st & ACCEL_STATUS_ERROR) return 1;
    printf("vl=%d: %u cycles\n", vl, (uint32_t)accel_cycles());

    for (int k = 0; k < NUM_BLOCKS; k++)
      for (int i = 0; i < vlmax; i++) {
        bf16_t got = out[k * vlmax + i], exp = expect(k, i, vl, A, B, C, s);
        if (got != exp) {
          if (errors < 20)
            printf("  vl=%d block %d elem %d: got 0x%04x expected 0x%04x (A=0x%04x B=0x%04x C=0x%04x s=0x%04x)\n",
                   vl, k, i, got, exp, A[i], B[i], C[i], s);
          errors++;
        }
      }

    uint32_t exp_s[4] = {A[0], expect(19, 0, vl, A, B, C, s), (uint32_t)vl, (uint32_t)vlmax};
    for (int i = 0; i < 4; i++)
      if (so[i] != exp_s[i]) {
        printf("  vl=%d scalar result %d: got 0x%x expected 0x%x\n", vl, i, so[i], exp_s[i]);
        errors++;
      }
  }

  printf("vector_ops: %d errors\n", errors);
  return errors ? 1 : 0;
}
