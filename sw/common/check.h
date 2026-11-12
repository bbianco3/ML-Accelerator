// check.h -- comparing accelerator results with a reference, within tolerance.
//
// Results of matrix/tensor workloads do not have to match the reference model
// bit for bit: an accelerator may sum in a different order or keep different
// intermediate precision. A value is accepted when
//
//     |got - ref| <= CHECK_ABS_TOL + CHECK_REL_TOL * |ref|
//
// The two tolerances come from competition.json (tolerance_abs,
// tolerance_rel) through the build (sw/sw.mk), so every test and every team
// uses the same ones. NaN matches only NaN, infinity only the same infinity.
// See docs/numerics.md ("Tolerance").
#ifndef CHECK_H
#define CHECK_H

#include "bf16.h"

#ifndef CHECK_REL_TOL
#define CHECK_REL_TOL 0.02
#endif
#ifndef CHECK_ABS_TOL
#define CHECK_ABS_TOL 0.02
#endif

static inline float check_absf(float x) { return x < 0.0f ? -x : x; }

static inline int f32_close(float got, float ref) {
  uint32_t g = f32_bits(got), r = f32_bits(ref);
  if (g == r) return 1;
  int g_special = (g & 0x7F800000u) == 0x7F800000u, r_special = (r & 0x7F800000u) == 0x7F800000u;
  if (g_special || r_special)                       // inf or NaN on either side
    return f32_bits_is_nan(g) && f32_bits_is_nan(r);
  return check_absf(got - ref) <= (float)(CHECK_ABS_TOL) + (float)(CHECK_REL_TOL) * check_absf(ref);
}

// bf16 result against a bf16 reference.
static inline int bf16_close(bf16_t got, bf16_t ref) {
  return got == ref || f32_close(bf16_to_f32(got), bf16_to_f32(ref));
}

// Largest |got - ref| seen so far (for reporting how close a design is).
static inline void check_track(float *max_err, bf16_t got, bf16_t ref) {
  float d = check_absf(bf16_to_f32(got) - bf16_to_f32(ref));
  if (d > *max_err) *max_err = d;                   // false for NaN: ignored
}

#endif // CHECK_H
