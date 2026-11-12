// fp_ref_dpi.c -- DPI wrappers exposing the C reference model (sw/common/bf16.h)
// to the FP unit testbench. Compiled natively (x86-64, SSE: IEEE RNE).
#include <stdint.h>

#include "bf16.h"
#include "svdpi.h"

int ref_fp32_add(int a, int b) {
  return (int)f32_bits(f32_add(f32_from_bits((uint32_t)a), f32_from_bits((uint32_t)b)));
}
int ref_bf16_mul_fp32(int a, int b) {
  return (int)f32_bits(bf16_mul_f32((bf16_t)a, (bf16_t)b));
}
int ref_fp32_to_bf16(int x) { return f32_to_bf16(f32_from_bits((uint32_t)x)); }
int ref_bf16_add(int a, int b) { return bf16_add((bf16_t)a, (bf16_t)b); }
int ref_bf16_sub(int a, int b) { return bf16_sub((bf16_t)a, (bf16_t)b); }
int ref_bf16_mul(int a, int b) { return bf16_mul((bf16_t)a, (bf16_t)b); }
int ref_bf16_macc(int c, int a, int b) { return bf16_macc((bf16_t)c, (bf16_t)a, (bf16_t)b); }
int ref_bf16_max(int a, int b) { return bf16_max((bf16_t)a, (bf16_t)b); }
int ref_bf16_min(int a, int b) { return bf16_min((bf16_t)a, (bf16_t)b); }
int ref_mxu_mac(int acc, int a, int b) {
  return (int)f32_bits(mxu_mac(f32_from_bits((uint32_t)acc), (bf16_t)a, (bf16_t)b));
}
