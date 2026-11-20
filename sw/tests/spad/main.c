// spad -- the per-core scratchpad: scalar, vector and matrix accesses of
// every kind, partial (masked) stores, out-of-range accesses, and how much
// faster it is than HBM. Adapts to any SPAD_KB, including 0 (no scratchpad).
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

extern void spad_basic(void), spad_timing(void), spad_sweep(void), spad_oob(void);
extern char pc_spad_oob[];

struct spad_params {          // layout must match kernel.S
  uint32_t out, vsrc, vdst, msrc, mdst, row_bytes, vec_off, mat_off;
};
static struct spad_params params HBM_BUF;
static uint32_t out[32] HBM_BUF;

static uint32_t round_up(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  int errors = 0;
  const uint32_t D = cfg.mat_dim, vlmax = cfg.vlmax, vbytes = cfg.vlen / 8;
  const uint32_t row_bytes = D * 2, tile_bytes = D * D * 2;

  // ---- out-of-range access is a bus error (also the only check without a scratchpad) ----
  uint32_t oob_args[] = {cfg.spad_bytes};
  accel_launch(spad_oob, oob_args, 1);
  uint32_t st = accel_wait();
  if (!(st & ACCEL_STATUS_ERROR) || ACCEL_STATUS_CAUSE(st) != ACCEL_ERR_BUS ||
      accel_rd(ACCEL_ERR_PC) != (uint32_t)(uintptr_t)pc_spad_oob) {
    printf("out-of-range access: status=0x%08x pc=0x%08x (expected bus error at 0x%08x)\n", st,
           accel_rd(ACCEL_ERR_PC), (uint32_t)(uintptr_t)pc_spad_oob);
    errors++;
  } else {
    printf("out-of-range access at SPAD_BASE+%u: bus error, ok\n", cfg.spad_bytes);
  }

  if (cfg.spad_bytes == 0) {
    printf("no scratchpad in this configuration (SPAD_KB=0)\n");
    printf("spad: %d errors\n", errors);
    return errors ? 1 : 0;
  }

  // ---- scratchpad layout: [scalars 16 B][2 vectors][one tile] ----
  uint32_t vec_off = round_up(16, vbytes);
  uint32_t mat_off = round_up(vec_off + 2 * vbytes, row_bytes);
  if (vec_off + 2 * vbytes > cfg.spad_bytes) {
    printf("scratchpad too small for this test\n");
    return 1;
  }
  if (mat_off + tile_bytes > cfg.spad_bytes) mat_off = 0;   // skip the matrix part

  bf16_t *vsrc = hbm_alloc(2 * vbytes, HBM_ALIGN);
  bf16_t *vdst = hbm_alloc(2 * vbytes, HBM_ALIGN);
  bf16_t *msrc = hbm_alloc(tile_bytes, HBM_ALIGN);
  bf16_t *mdst = hbm_alloc(tile_bytes, HBM_ALIGN);
  srand_(7);
  for (uint32_t i = 0; i < 2 * vlmax; i++) vsrc[i] = f32_to_bf16(rand_float(-4.0f, 4.0f));
  for (uint32_t i = 0; i < D * D; i++) msrc[i] = f32_to_bf16(rand_float(-4.0f, 4.0f));

  params = (struct spad_params){(uint32_t)(uintptr_t)out, (uint32_t)(uintptr_t)vsrc, (uint32_t)(uintptr_t)vdst, (uint32_t)(uintptr_t)msrc,
                                (uint32_t)(uintptr_t)mdst, row_bytes, vec_off, mat_off};
  uint32_t args[] = {(uint32_t)(uintptr_t)&params};
  st = accel_run(spad_basic, args, 1);
  if (st & ACCEL_STATUS_ERROR) return 1;

  // scalars
  const uint32_t want[] = {cfg.spad_bytes, 0x12345678u, 0x0000AB00u, 0xFFFFFFABu, 0xCDEFu,
                           0xCDEF0000u};   // halfword at byte 10 = upper half of word 8
  for (int i = 0; i < 6; i++) {
    if (out[i] != want[i]) {
      printf("  scalar check %d: got 0x%08x expected 0x%08x\n", i, out[i], want[i]);
      errors++;
    }
  }
  // vectors: first copy unchanged, second has 1.0 in its first min(3, VLMAX) elements
  for (uint32_t i = 0; i < 2 * vlmax; i++) {
    bf16_t exp = (i >= vlmax && i - vlmax < 3) ? f32_to_bf16(1.0f) : vsrc[i];
    if (vdst[i] != exp) {
      if (errors < 10) printf("  vector[%u]: got 0x%04x expected 0x%04x\n", i, vdst[i], exp);
      errors++;
    }
  }
  // matrix: transposed copy
  if (mat_off) {
    for (uint32_t r = 0; r < D; r++)
      for (uint32_t c = 0; c < D; c++)
        if (mdst[r * D + c] != msrc[c * D + r]) {
          if (errors < 10) printf("  tile[%u][%u] wrong\n", r, c);
          errors++;
        }
  } else {
    printf("(tile does not fit next to the vectors: matrix check skipped)\n");
  }
  printf("scalar / vector / matrix accesses: %s\n", errors ? "WRONG" : "ok");

  // ---- every part of the scratchpad is distinct storage ----
  {
    uint32_t sargs[] = {(uint32_t)(uintptr_t)out, cfg.spad_bytes};
    st = accel_run(spad_sweep, sargs, 2);
    if (st & ACCEL_STATUS_ERROR) return 1;
    int e = 0;
    for (uint32_t i = 0; i < 16; i++) {
      if (out[2 * i] != 0xA0000000u + i || out[2 * i + 1] != 0xB0000000u + i) {
        if (e < 5) printf("  region %u: read 0x%08x / 0x%08x\n", i, out[2 * i], out[2 * i + 1]);
        e++;
      }
    }
    printf("address sweep over all %u bytes (16 regions): %s\n", cfg.spad_bytes, e ? "WRONG" : "ok");
    errors += e;
  }

  // ---- speed: 4 tile loads from HBM vs. from the scratchpad ----
  uint32_t toff = round_up(16, row_bytes);
  if (toff + tile_bytes <= cfg.spad_bytes) {
    uint32_t targs[] = {(uint32_t)(uintptr_t)out, (uint32_t)(uintptr_t)msrc, row_bytes, toff};
    st = accel_run(spad_timing, targs, 4);
    if (st & ACCEL_STATUS_ERROR) return 1;
    printf("4 x mld of a %ux%u tile: HBM %u cycles, scratchpad %u cycles (%u.%01ux faster)\n",
           D, D, out[0], out[1], out[0] / out[1], (out[0] % out[1]) * 10 / out[1]);
    if (out[1] >= out[0]) {
      printf("  scratchpad is not faster than HBM\n");
      errors++;
    }
  }

  printf("spad: %d errors\n", errors);
  return errors ? 1 : 0;
}
