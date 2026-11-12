// bf16.h -- bit-exact C reference model of the accelerator's numerics.
//
// Every function here matches the RTL in hw/rtl/accel_fp_pkg.sv bit for bit.
// The rules are described in docs/numerics.md:
//   * bf16 storage; arithmetic in fp32; results rounded to bf16 with
//     round-to-nearest-even.
//   * Subnormal inputs are treated as zero (DAZ), subnormal results are
//     flushed to zero (FTZ). Zeros keep their sign.
//   * NaN results are always the canonical quiet NaN (0x7FC0 / 0x7FC00000).
//   * bf16*bf16 products are exact in fp32; the vector unit rounds them to
//     bf16, the matrix unit keeps them in fp32 and accumulates in fp32.
//
// Unlike the RTL, this model uses the host's native IEEE float/double
// arithmetic, which makes it an independent check of the hardware algorithm.
// It is used in two places:
//   * by host programs running on the RV64G ISS (sw/tests/*) to compute the
//     expected results of a kernel, and
//   * natively by the FP unit test (sim/unit/fp) to check the RTL functions.
//
// IMPORTANT: compile with -ffp-contract=off. Otherwise the compiler may fuse
// a multiply and an add into one FMA instruction, which rounds differently.
#ifndef BF16_H
#define BF16_H

#include <stdint.h>

typedef uint16_t bf16_t;

#define BF16_QNAN 0x7FC0u
#define F32_QNAN  0x7FC00000u

// ---------------------------------------------------------------------------
// Bit casts
// ---------------------------------------------------------------------------
static inline uint32_t f32_bits(float f) {
  union { float f; uint32_t u; } c;
  c.f = f;
  return c.u;
}

static inline float f32_from_bits(uint32_t u) {
  union { float f; uint32_t u; } c;
  c.u = u;
  return c.f;
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------
static inline int bf16_is_nan(bf16_t x) {
  return ((x & 0x7F80u) == 0x7F80u) && (x & 0x007Fu);
}

static inline int f32_bits_is_nan(uint32_t u) {
  return ((u & 0x7F800000u) == 0x7F800000u) && (u & 0x007FFFFFu);
}

// Denormals-are-zero.
static inline bf16_t bf16_daz(bf16_t x) {
  return (x & 0x7F80u) ? x : (bf16_t)(x & 0x8000u);
}

// Canonicalise NaN and flush subnormals of an fp32 bit pattern.
static inline uint32_t f32_canon_ftz(uint32_t u) {
  if (f32_bits_is_nan(u)) return F32_QNAN;
  if ((u & 0x7F800000u) == 0) return u & 0x80000000u;
  return u;
}

// ---------------------------------------------------------------------------
// Conversions
// ---------------------------------------------------------------------------
// bf16 -> fp32 (exact; subnormal -> signed zero)
static inline float bf16_to_f32(bf16_t x) {
  return f32_from_bits((uint32_t)bf16_daz(x) << 16);
}

// fp32 -> bf16 (RNE, canonical NaN, FTZ). Also the way to make bf16 inputs.
static inline bf16_t f32_to_bf16(float f) {
  uint32_t u = f32_bits(f);
  if (f32_bits_is_nan(u)) return BF16_QNAN;
  if ((u & 0x7F800000u) == 0) return (bf16_t)((u >> 16) & 0x8000u);
  u += 0x7FFFu + ((u >> 16) & 1u);
  return (bf16_t)(u >> 16);
}

// ---------------------------------------------------------------------------
// fp32 primitives (hardware: fp32_add, bf16_mul_fp32)
// ---------------------------------------------------------------------------
static inline float f32_add(float a, float b) {
  a = f32_from_bits(f32_canon_ftz(f32_bits(a)));
  b = f32_from_bits(f32_canon_ftz(f32_bits(b)));
  float r = a + b;
  return f32_from_bits(f32_canon_ftz(f32_bits(r)));
}

// Exact bf16*bf16 product as fp32. Flushes if the exact product is below
// the smallest normal (2^-126), overflows to inf.
static inline float bf16_mul_f32(bf16_t a, bf16_t b) {
  if (bf16_is_nan(a) || bf16_is_nan(b)) return f32_from_bits(F32_QNAN);
  double p = (double)bf16_to_f32(a) * (double)bf16_to_f32(b);   // exact
  if (p != p) return f32_from_bits(F32_QNAN);                   // inf * 0
  if (p < 0x1p-126 && p > -0x1p-126)
    return f32_from_bits(((uint32_t)((a ^ b) & 0x8000u)) << 16);
  return (float)p;                                              // exact or inf
}

// ---------------------------------------------------------------------------
// Vector-unit element operations (bf16 in, bf16 out)
// ---------------------------------------------------------------------------
static inline bf16_t bf16_add(bf16_t a, bf16_t b) {
  return f32_to_bf16(f32_add(bf16_to_f32(a), bf16_to_f32(b)));
}

static inline bf16_t bf16_sub(bf16_t a, bf16_t b) {
  return f32_to_bf16(f32_add(bf16_to_f32(a), -bf16_to_f32(b)));
}

static inline bf16_t bf16_mul(bf16_t a, bf16_t b) {
  return f32_to_bf16(bf16_mul_f32(a, b));
}

// vd + vs2 * op1, with the product exact and a single fp32 add.
static inline bf16_t bf16_macc(bf16_t acc, bf16_t a, bf16_t b) {
  return f32_to_bf16(f32_add(bf16_mul_f32(a, b), bf16_to_f32(acc)));
}

static inline int bf16_lt_daz(bf16_t a, bf16_t b) {      // a, b DAZ'd, non-NaN
  if ((a ^ b) & 0x8000u) return (a & 0x8000u) != 0;
  if (!(a & 0x8000u)) return (a & 0x7FFFu) < (b & 0x7FFFu);
  return (a & 0x7FFFu) > (b & 0x7FFFu);
}

static inline bf16_t bf16_max(bf16_t a, bf16_t b) {
  a = bf16_daz(a); b = bf16_daz(b);
  if (bf16_is_nan(a) || bf16_is_nan(b)) return BF16_QNAN;
  return bf16_lt_daz(a, b) ? b : a;
}

static inline bf16_t bf16_min(bf16_t a, bf16_t b) {
  a = bf16_daz(a); b = bf16_daz(b);
  if (bf16_is_nan(a) || bf16_is_nan(b)) return BF16_QNAN;
  return bf16_lt_daz(a, b) ? a : b;
}

// vredsum: init + x[0] + x[1] + ... (sequential fp32, one rounding at the end)
static inline bf16_t bf16_redsum(bf16_t init, const bf16_t *x, int n) {
  float acc = bf16_to_f32(init);
  for (int i = 0; i < n; i++) acc = f32_add(acc, bf16_to_f32(x[i]));
  return f32_to_bf16(acc);
}

static inline bf16_t bf16_redmax(bf16_t init, const bf16_t *x, int n) {
  bf16_t m = init;
  for (int i = 0; i < n; i++) m = bf16_max(m, x[i]);
  return m;
}

// ---------------------------------------------------------------------------
// Matrix unit: one multiply-accumulate step, acc (fp32) += a * b
// ---------------------------------------------------------------------------
static inline float mxu_mac(float acc, bf16_t a, bf16_t b) {
  return f32_add(acc, bf16_mul_f32(a, b));
}

// C[M][N] (fp32, row stride ldc floats) += A[M][K] x B[K][N] (bf16), with the
// accumulation order the hardware uses: k = 0, 1, ..., K-1 for each element.
static inline void mxu_matmul_ref(float *c, int ldc,
                                  const bf16_t *a, int lda,
                                  const bf16_t *b, int ldb,
                                  int m, int n, int k) {
  for (int i = 0; i < m; i++)
    for (int j = 0; j < n; j++) {
      float acc = c[i * ldc + j];
      for (int kk = 0; kk < k; kk++)
        acc = mxu_mac(acc, a[i * lda + kk], b[kk * ldb + j]);
      c[i * ldc + j] = acc;
    }
}

#endif // BF16_H
