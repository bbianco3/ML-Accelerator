// vadd -- the "hello world" of kernels: element-wise bf16 vector add.
// Start here when learning how a host program drives the accelerator.
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

#define N      1000
#define N_PAD  1024            // pad to a multiple of VLMAX for any VLEN <= 16384

// Buffers in HBM (shared with the accelerator).
static bf16_t x[N_PAD] HBM_BUF;
static bf16_t y[N_PAD] HBM_BUF;
static bf16_t z[N_PAD] HBM_BUF;

extern void vadd_kernel(void);   // kernel.S

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);

  // 1. Prepare inputs directly in HBM.
  srand_(1);
  for (int i = 0; i < N; i++) {
    x[i] = f32_to_bf16(rand_float(-10.0f, 10.0f));
    y[i] = f32_to_bf16(rand_float(-10.0f, 10.0f));
  }
  for (int i = 0; i < N_PAD; i++) z[i] = 0xDEAD;   // poison output

  // 2. Launch the kernel and wait for it.
  uint32_t args[] = {N, (uint32_t)(uintptr_t)x, (uint32_t)(uintptr_t)y, (uint32_t)(uintptr_t)z};
  uint32_t st = accel_run(vadd_kernel, args, 4);
  if (st & ACCEL_STATUS_ERROR) return 1;
  printf("kernel done: %u cycles, %u instructions\n",
         (uint32_t)accel_cycles(), (uint32_t)accel_instret());

  // 3. Check against the bit-exact reference model.
  int errors = 0;
  for (int i = 0; i < N; i++) {
    bf16_t exp = bf16_add(x[i], y[i]);
    if (z[i] != exp) {
      if (errors < 10)
        printf("mismatch z[%d]: got 0x%04x expected 0x%04x\n", i, z[i], exp);
      errors++;
    }
  }
  // Elements past n must not have been written.
  for (int i = N; i < N_PAD; i++)
    if (z[i] != 0xDEAD) {
      if (errors < 10) printf("z[%d] beyond n was overwritten: 0x%04x\n", i, z[i]);
      errors++;
    }

  printf("vadd: %d errors\n", errors);
  return errors ? 1 : 0;
}
