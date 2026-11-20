// hello -- host-only smoke test.
// Checks that the host ISS, console, FP unit and the accelerator's CSR port
// all work, and prints the accelerator configuration. No kernel is run.
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

int main(void) {
  printf("Hello from the RV64G host!\n");

  uint32_t id = accel_rd(ACCEL_ID);
  printf("accelerator ID = 0x%08x\n", id);
  if (id != ACCEL_ID_VALUE) {
    printf("FAIL: unexpected ID (expected 0x%08x)\n", ACCEL_ID_VALUE);
    return 1;
  }
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);

  // Exercise the host FPU (F and D extensions) and the bf16 reference model.
  volatile float a = 1.5f, b = 2.25f;
  volatile double c = 3.0;
  float s = a * b + (float)c;
  printf("1.5 * 2.25 + 3.0 = %f\n", (double)s);
  if (s != 6.375f) return 2;

  bf16_t x = f32_to_bf16(3.140625f), y = f32_to_bf16(-1.0f);
  bf16_t z = bf16_add(x, y);
  printf("bf16: 0x%04x + 0x%04x = 0x%04x (%f)\n", x, y, z, (double)bf16_to_f32(z));
  if (z != f32_to_bf16(2.140625f)) return 3;

  uint64_t t0 = sim_cycles();
  printf("cycle counter = %u\n", (uint32_t)t0);
  return 0;
}
