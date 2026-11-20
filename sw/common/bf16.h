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
// Element encoding
// ---------------------------------------------------------------------------
// bf16_t is a 16-bit element container. ACCEL_NUMFMT (from the build)
// selects what it holds; kernels carry the same code in funct3 (accel_isa.h):
//   0  bf16
//   1  IEEE binary16: 1/5/10, bias 15, inf, canonical NaN 0x7E00
//   2  OCP fp8 E4M3FN in bits 7:0: 1/4/3, bias 7, no inf, NaN S.1111.111,
//      canonical 0x007F, max 448; bits 15:8 ignored on input, 0 in results
// The same rules apply to every encoding: arithmetic in fp32, RNE, DAZ,
// FTZ (by the magnitude after rounding), canonical NaN, products exact. A
// value too large for E4M3 (or inf) becomes NaN. The functions below take
// the encoding as an argument; the bf16_* API further down uses ACCEL_NUMFMT.
#define NUMFMT_BF16 0
#define NUMFMT_FP16 1
#define NUMFMT_E4M3 2
#ifndef ACCEL_NUMFMT
#define ACCEL_NUMFMT NUMFMT_BF16
#endif

static inline int nf_mbits(int f) { return f == NUMFMT_FP16 ? 10 : f == NUMFMT_E4M3 ? 3 : 7; }
static inline int nf_ebits(int f) { return f == NUMFMT_FP16 ? 5 : f == NUMFMT_E4M3 ? 4 : 8; }
static inline uint16_t nf_qnan(int f) {
  return f == NUMFMT_FP16 ? 0x7E00u : f == NUMFMT_E4M3 ? 0x007Fu : 0x7FC0u;
}

static inline int nf_is_nan(int f, uint16_t x) {
  const int mb = nf_mbits(f), eb = nf_ebits(f);
  const uint32_t emask = (1u << eb) - 1, mmask = (1u << mb) - 1;
  if (f == NUMFMT_E4M3) return (x & 0x7Fu) == 0x7Fu;
  return ((x >> mb) & emask) == emask && (x & mmask) != 0;
}

// Element -> fp32: exact; subnormal -> signed zero, NaN -> canonical NaN.
static inline float nf_to_f32(int f, uint16_t x) {
  const int mb = nf_mbits(f), eb = nf_ebits(f), bias = (1 << (eb - 1)) - 1;
  const uint32_t emask = (1u << eb) - 1;
  if (f == NUMFMT_E4M3) x &= 0xFFu;
  const uint32_t s = ((uint32_t)x >> (eb + mb)) & 1u, e = ((uint32_t)x >> mb) & emask,
                 m = x & ((1u << mb) - 1);
  if (nf_is_nan(f, x)) return f32_from_bits(0x7FC00000u);
  if (e == 0) return f32_from_bits(s << 31);
  if (e == emask && f != NUMFMT_E4M3) return f32_from_bits(s << 31 | 0x7F800000u);
  return f32_from_bits(s << 31 | (e - (uint32_t)bias + 127u) << 23 | m << (23 - mb));
}

// fp32 -> element: RNE, FTZ, canonical NaN; overflow -> inf (E4M3: NaN).
static inline uint16_t f32_to_nf(int f, float v) {
  const int mb = nf_mbits(f), eb = nf_ebits(f), bias = (1 << (eb - 1)) - 1;
  const int has_inf = (f != NUMFMT_E4M3);
  const uint32_t emask = (1u << eb) - 1, mmask = (1u << mb) - 1;
  const int emax = has_inf ? (int)emask - 1 : (int)emask;        // largest finite exponent
  const uint32_t mmax = has_inf ? mmask : mmask - 1;              // largest mantissa there
  const uint32_t u = f32_bits(v), sbit = (u >> 31) << (eb + mb);
  const uint16_t big = has_inf ? (uint16_t)(sbit | emask << mb) : nf_qnan(f);
  const int e = (int)((u >> 23) & 0xFFu);
  if (e == 0xFF) return (u & 0x7FFFFFu) ? nf_qnan(f) : big;
  if (e == 0) return (uint16_t)sbit;
  const int sh = 23 - mb;
  const uint32_t sig = (u & 0x7FFFFFu) | 0x800000u;
  uint32_t r = (sig + (1u << (sh - 1)) - 1u + ((sig >> sh) & 1u)) >> sh;
  int be = e - 127 + bias;
  if (r >> (mb + 1)) {
    r >>= 1;
    be++;
  }
  if (be < 1) return (uint16_t)sbit;
  if (be > emax || (be == emax && (r & mmask) > mmax)) return big;
  return (uint16_t)(sbit | (uint32_t)be << mb | (r & mmask));
}

// Exact element x element product in fp32 (flushes below 2^-126).
static inline float nf_mul_f32(int f, uint16_t a, uint16_t b) {
  if (nf_is_nan(f, a) || nf_is_nan(f, b)) return f32_from_bits(0x7FC00000u);
  const int sb = nf_ebits(f) + nf_mbits(f);
  const uint32_t s = (((uint32_t)a ^ b) >> sb) & 1u;
  double p = (double)nf_to_f32(f, a) * (double)nf_to_f32(f, b);  // exact
  if (p != p) return f32_from_bits(0x7FC00000u);                 // inf * 0
  if (p < 0x1p-126 && p > -0x1p-126) return f32_from_bits(s << 31);
  return (float)p;
}

// a < b on fp32 bit patterns (non-NaN; -0 < +0).
static inline int nf_f32_lt(uint32_t a, uint32_t b) {
  if ((a ^ b) >> 31) return (int)(a >> 31);
  if (!(a >> 31)) return (a & 0x7FFFFFFFu) < (b & 0x7FFFFFFFu);
  return (a & 0x7FFFFFFFu) > (b & 0x7FFFFFFFu);
}

static inline uint16_t nf_max(int f, uint16_t a, uint16_t b) {
  if (nf_is_nan(f, a) || nf_is_nan(f, b)) return nf_qnan(f);
  float x = nf_to_f32(f, a), y = nf_to_f32(f, b);
  return f32_to_nf(f, nf_f32_lt(f32_bits(x), f32_bits(y)) ? y : x);
}

static inline uint16_t nf_min(int f, uint16_t a, uint16_t b) {
  if (nf_is_nan(f, a) || nf_is_nan(f, b)) return nf_qnan(f);
  float x = nf_to_f32(f, a), y = nf_to_f32(f, b);
  return f32_to_nf(f, nf_f32_lt(f32_bits(x), f32_bits(y)) ? x : y);
}

// A bf16 value from a file (e.g. trained weights) in the element encoding.
static inline uint16_t bf16_import(uint16_t raw_bf16) {
  if (ACCEL_NUMFMT == NUMFMT_BF16) return raw_bf16;
  return f32_to_nf(ACCEL_NUMFMT, nf_to_f32(NUMFMT_BF16, raw_bf16));
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------
static inline int bf16_is_nan(bf16_t x) {
  if (ACCEL_NUMFMT) return nf_is_nan(ACCEL_NUMFMT, x);
  return ((x & 0x7F80u) == 0x7F80u) && (x & 0x007Fu);
}

static inline int f32_bits_is_nan(uint32_t u) {
  return ((u & 0x7F800000u) == 0x7F800000u) && (u & 0x007FFFFFu);
}

// Denormals-are-zero.
static inline bf16_t bf16_daz(bf16_t x) {
  if (ACCEL_NUMFMT) return nf_is_nan(ACCEL_NUMFMT, x) ? x : f32_to_nf(ACCEL_NUMFMT, nf_to_f32(ACCEL_NUMFMT, x));
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
  if (ACCEL_NUMFMT) return nf_to_f32(ACCEL_NUMFMT, x);
  return f32_from_bits((uint32_t)bf16_daz(x) << 16);
}

// fp32 -> bf16 (RNE, canonical NaN, FTZ). Also the way to make bf16 inputs.
static inline bf16_t f32_to_bf16(float f) {
  if (ACCEL_NUMFMT) return f32_to_nf(ACCEL_NUMFMT, f);
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
  if (ACCEL_NUMFMT) return nf_mul_f32(ACCEL_NUMFMT, a, b);
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
  if (ACCEL_NUMFMT) return nf_max(ACCEL_NUMFMT, a, b);
  a = bf16_daz(a); b = bf16_daz(b);
  if (bf16_is_nan(a) || bf16_is_nan(b)) return BF16_QNAN;
  return bf16_lt_daz(a, b) ? b : a;
}

static inline bf16_t bf16_min(bf16_t a, bf16_t b) {
  if (ACCEL_NUMFMT) return nf_min(ACCEL_NUMFMT, a, b);
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
