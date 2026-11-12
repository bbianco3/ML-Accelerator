// scalar_ops -- checks the RV32I subset executed by the accelerator's control
// core against the same operations computed on the host.
#include "accel.h"
#include "runtime.h"

#define NOUT 36

static uint32_t out[64] HBM_BUF;
static uint8_t  in[64]  HBM_BUF;

extern void scalar_ops_kernel(void);
extern char scalar_auipc_label[];

static int check_case(int32_t x, int32_t y) {
  for (int i = 0; i < 64; i++) out[i] = 0xDEADBEEF;
  uint32_t args[8] = {(uint32_t)(uintptr_t)out, (uint32_t)x, (uint32_t)y, (uint32_t)(uintptr_t)in, 0, 0, 0, 0xA7A7A7A7u};
  uint32_t st = accel_run(scalar_ops_kernel, args, 8);
  if (st & ACCEL_STATUS_ERROR) return 100;

  uint32_t ux = (uint32_t)x, uy = (uint32_t)y, sh = uy & 31;
  uint32_t exp[NOUT];
  exp[0]  = ux + uy;
  exp[1]  = ux - uy;
  exp[2]  = ux & uy;
  exp[3]  = ux | uy;
  exp[4]  = ux ^ uy;
  exp[5]  = ux << sh;
  exp[6]  = ux >> sh;
  exp[7]  = (uint32_t)(x >> sh);
  exp[8]  = x < y;
  exp[9]  = ux < uy;
  exp[10] = ux - 7;
  exp[11] = ux ^ 0x5a5;
  exp[12] = ux | (uint32_t)-16;
  exp[13] = ux & 0xf0;
  exp[14] = x < -3;
  exp[15] = ux < 5;
  exp[16] = ux << 7;
  exp[17] = ux >> 5;
  exp[18] = (uint32_t)(x >> 3);
  exp[19] = 0xABCDE000u;
  exp[20] = (uint32_t)(uintptr_t)scalar_auipc_label;
  exp[21] = (uint32_t)(int32_t)(int8_t)in[3];
  exp[22] = in[3];
  exp[23] = (uint32_t)(int32_t)(int16_t)(in[6] | (in[7] << 8));
  exp[24] = (uint32_t)(in[6] | (in[7] << 8));
  exp[25] = in[8] | (in[9] << 8) | (in[10] << 16) | ((uint32_t)in[11] << 24);
  exp[26] = in[36] | (in[37] << 8) | (in[38] << 16) | ((uint32_t)in[39] << 24);
  exp[27] = ((uy & 0xFFFF) << 16) | 0x3300u | (ux & 0xFF);
  exp[28] = 1u | ((ux != uy) << 1) | ((x < y) << 2) | ((x >= y) << 3) | ((ux < uy) << 4) | ((ux >= uy) << 5);
  exp[29] = 55;
  exp[30] = ux + 100;
  exp[31] = accel_get_config().vlen / 8;
  exp[32] = 0;  // cycle: only checked to be non-zero
  exp[33] = 0;  // instret: only checked to be non-zero
  exp[34] = 0;
  exp[35] = 0xA7A7A7A7u;

  int errors = 0;
  for (int i = 0; i < NOUT; i++) {
    int ok = (i == 32 || i == 33) ? (out[i] != 0 && out[i] != 0xDEADBEEF) : (out[i] == exp[i]);
    if (!ok) {
      printf("  x=%d y=%d result[%d]: got 0x%08x expected 0x%08x\n", x, y, i, out[i], exp[i]);
      errors++;
    }
  }
  return errors;
}

int main(void) {
  for (int i = 0; i < 64; i++) in[i] = (uint8_t)(0x80 + 7 * i);

  static const int32_t cases[][2] = {
    {5, 3}, {-5, 3}, {3, -5}, {7, 7}, {0x7FFFFFFF, 1}, {(int32_t)0x80000000, 31},
    {-1, 0}, {123456789, -987654321},
  };
  int errors = 0;
  for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; c++)
    errors += check_case(cases[c][0], cases[c][1]);

  printf("scalar_ops: %d errors\n", errors);
  return errors ? 1 : 0;
}
