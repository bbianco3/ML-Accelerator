// copy -- the hcpy instruction: x[rs2] bf16 elements from x[rs1] to x[rd],
// and hcpy2d: several such runs, a source stride apart, back to back.
//
// Every run length in a list, at every source and destination offset inside
// a bus beat, HBM -> HBM; then the same through the scratchpad (HBM -> spad,
// spad -> spad, spad -> HBM). Each destination slot is pre-filled with a
// pattern, so a copy that writes one byte too many or too few is caught.
// Last: an odd address is MISALIGNED, n = 0 copies nothing, and one timing.
#include "accel.h"
#include "bf16.h"
#include "runtime.h"

extern void copy_jobs(void), copy_one(void), copy2d_jobs(void), copy2d_one(void);
extern char pc_copy_one[], pc_copy2d_one[];

#define SLOT     192u                 // destination slot (bytes)
#define SRC_LEN  1024u                // shared source buffer (bytes)
#define MAX_JOBS 6000u

typedef struct { uint32_t dst, src, n; } job_t;

static job_t   jobs[MAX_JOBS] HBM_BUF;
static uint8_t src_hbm[SRC_LEN] HBM_BUF;

static const uint32_t lens[] = {1, 2, 3, 15, 16, 17, 30, 31, 33, 70};
#define NLENS (sizeof(lens) / sizeof(lens[0]))

static uint8_t pattern(uint32_t slot, uint32_t i) { return (uint8_t)(0xA5 ^ (slot * 7) ^ i); }

// Check slot s (bytes at `got`) against: pattern, with [doff, doff+2n) = src[soff..]
static int check(const char *what, uint32_t s, const uint8_t *got, const uint8_t *src,
                 uint32_t soff, uint32_t doff, uint32_t n) {
  for (uint32_t i = 0; i < SLOT; i++) {
    uint8_t exp = (i >= doff && i < doff + 2 * n) ? src[soff + i - doff] : pattern(s, i);
    if (got[i] != exp) {
      printf("%s: n=%u src_off=%u dst_off=%u: byte %u is 0x%02x, expected 0x%02x\n", what, n,
             soff, doff, i, got[i], exp);
      return 1;
    }
  }
  return 0;
}

int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  const uint32_t beat = cfg.hbm_data_w / 8;
  int errors = 0;

  srand_(11);
  for (uint32_t i = 0; i < SRC_LEN; i++) src_hbm[i] = (uint8_t)rand_u32();

  // ---- 1. HBM -> HBM: every length x every source / destination offset ----
  uint32_t ncase = NLENS * (beat / 2) * (beat / 2);
  uint8_t *dst = hbm_alloc(ncase * SLOT, HBM_ALIGN);
  uint32_t nj = 0, s = 0;
  for (uint32_t l = 0; l < NLENS; l++)
    for (uint32_t so = 0; so < beat; so += 2)
      for (uint32_t d = 0; d < beat; d += 2, s++) {
        for (uint32_t i = 0; i < SLOT; i++) dst[s * SLOT + i] = pattern(s, i);
        jobs[nj++] = (job_t){(uint32_t)(uintptr_t)(dst + s * SLOT + d),
                             (uint32_t)(uintptr_t)(src_hbm + so), lens[l]};
      }
  uint32_t args[] = {(uint32_t)(uintptr_t)jobs, nj};
  uint32_t st = accel_run(copy_jobs, args, 2);
  if (st & ACCEL_STATUS_ERROR) { printf("HBM -> HBM kernel faulted\n"); return 1; }
  int bad = 0;
  s = 0;
  for (uint32_t l = 0; l < NLENS; l++)
    for (uint32_t so = 0; so < beat; so += 2)
      for (uint32_t d = 0; d < beat; d += 2, s++)
        if (!bad) bad = check("HBM->HBM", s, dst + s * SLOT, src_hbm, so, d, lens[l]);
  printf("HBM -> HBM: %u copies, %s\n", s, bad ? "FAILED" : "ok");
  errors += bad;

  // ---- 2. through the scratchpad ----
  // Per case: stage the pattern slot HBM -> spad, the test copy into it (from
  // the spad source, or from HBM for odd cases), then the slot spad -> HBM.
  if (cfg.spad_bytes >= SRC_LEN + SLOT) {
    const uint32_t sp_src = SPAD_BASE, sp_slot = SPAD_BASE + SRC_LEN;
    static const uint32_t sp_lens[] = {1, 5, 17, 30, 33, 70};
    uint32_t nsp = 6 * (beat / 2) * (beat / 2);
    uint8_t *img = hbm_alloc(nsp * SLOT, HBM_ALIGN);   // pattern in, result out
    nj = 0;
    jobs[nj++] = (job_t){sp_src, (uint32_t)(uintptr_t)src_hbm, SRC_LEN / 2};
    s = 0;
    for (uint32_t l = 0; l < 6; l++)
      for (uint32_t so = 0; so < beat; so += 2)
        for (uint32_t d = 0; d < beat; d += 2, s++) {
          uint32_t from_hbm = (so / 2 + d / 2) & 1;
          uint32_t src = from_hbm ? (uint32_t)(uintptr_t)(src_hbm + so) : sp_src + so;
          for (uint32_t i = 0; i < SLOT; i++) img[s * SLOT + i] = pattern(s, i);
          jobs[nj++] = (job_t){sp_slot, (uint32_t)(uintptr_t)(img + s * SLOT), SLOT / 2};
          jobs[nj++] = (job_t){sp_slot + d, src, sp_lens[l]};
          jobs[nj++] = (job_t){(uint32_t)(uintptr_t)(img + s * SLOT), sp_slot, SLOT / 2};
        }
    uint32_t args2[] = {(uint32_t)(uintptr_t)jobs, nj};
    st = accel_run(copy_jobs, args2, 2);
    if (st & ACCEL_STATUS_ERROR) { printf("scratchpad kernel faulted\n"); return 1; }
    bad = 0;
    s = 0;
    for (uint32_t l = 0; l < 6; l++)
      for (uint32_t so = 0; so < beat; so += 2)
        for (uint32_t d = 0; d < beat; d += 2, s++)
          if (!bad) bad = check("scratchpad", s, img + s * SLOT, src_hbm, so, d, sp_lens[l]);
    printf("through the scratchpad: %u copies, %s\n", s, bad ? "FAILED" : "ok");
    errors += bad;
  } else {
    printf("scratchpad too small for this test: skipped\n");
  }

  // ---- 2b. hcpy2d: rows x run x stride, every source / destination offset ----
  {
    static const uint32_t shp[][3] = {   // rows, run, stride (bytes)
        {1, 5, 0}, {2, 1, 2}, {5, 5, 64}, {5, 30, 168}, {3, 17, 34}, {4, 16, 96}, {2, 33, 70}};
    const uint32_t S2 = 384;            // slot: up to 5*30*2 = 300 bytes + offset
    uint32_t n2 = 7 * (beat / 2) * (beat / 2);
    uint8_t *d2 = hbm_alloc(n2 * S2, HBM_ALIGN);
    nj = 0;
    s = 0;
    for (uint32_t c = 0; c < 7; c++)
      for (uint32_t so = 0; so < beat; so += 2)
        for (uint32_t d = 0; d < beat; d += 2, s++) {
          for (uint32_t i = 0; i < S2; i++) d2[s * S2 + i] = pattern(s, i);
          uint32_t src = (uint32_t)(uintptr_t)(src_hbm + so);
          if (cfg.spad_bytes >= SRC_LEN && (s & 1)) src = SPAD_BASE + so;  // staged below
          jobs[nj++] = (job_t){(uint32_t)(uintptr_t)(d2 + s * S2 + d), src,
                               (shp[c][2] << 16) | (shp[c][0] << 8) | shp[c][1]};
        }
    if (cfg.spad_bytes >= SRC_LEN) {     // the scratchpad copy of the source, with hcpy
      uint32_t a[] = {SPAD_BASE, (uint32_t)(uintptr_t)src_hbm, SRC_LEN / 2};
      accel_run(copy_one, a, 3);
    }
    uint32_t args3[] = {(uint32_t)(uintptr_t)jobs, nj};
    st = accel_run(copy2d_jobs, args3, 2);
    if (st & ACCEL_STATUS_ERROR) { printf("hcpy2d kernel faulted\n"); return 1; }
    bad = 0;
    s = 0;
    for (uint32_t c = 0; c < 7 && !bad; c++)
      for (uint32_t so = 0; so < beat && !bad; so += 2)
        for (uint32_t d = 0; d < beat && !bad; d += 2, s++) {
          const uint32_t rows = shp[c][0], rb = 2 * shp[c][1], stride = shp[c][2];
          const uint8_t *got = d2 + s * S2;
          for (uint32_t i = 0; i < S2; i++) {
            uint8_t exp = pattern(s, i);
            if (i >= d && i < d + rows * rb) {
              uint32_t k = i - d, r = k / rb;
              exp = src_hbm[so + r * stride + k % rb];
            }
            if (got[i] != exp) {
              printf("hcpy2d: rows=%u run=%u stride=%u src_off=%u dst_off=%u: byte %u is 0x%02x, "
                     "expected 0x%02x\n", rows, rb / 2, stride, so, d, i, got[i], exp);
              bad = 1;
              break;
            }
          }
        }
    printf("hcpy2d: %u copies, %s\n", n2, bad ? "FAILED" : "ok");
    errors += bad;

    uint32_t a[] = {(uint32_t)(uintptr_t)d2, (uint32_t)(uintptr_t)src_hbm, (3u << 16) | (2u << 8) | 4u};
    accel_launch(copy2d_one, a, 3);
    st = accel_wait();
    int ok = (st & ACCEL_STATUS_ERROR) && ACCEL_STATUS_CAUSE(st) == ACCEL_ERR_MISALIGNED &&
             accel_rd(ACCEL_ERR_PC) == (uint32_t)(uintptr_t)pc_copy2d_one;
    printf("hcpy2d odd stride: %s\n", ok ? "misaligned, ok" : "WRONG");
    if (!ok) errors++;
    accel_wr(ACCEL_STATUS, ACCEL_STATUS_DONE | ACCEL_STATUS_ERROR);
  }

  // ---- 3. n = 0 copies nothing; an odd address is MISALIGNED ----
  uint8_t *z = hbm_alloc(64, HBM_ALIGN);
  for (uint32_t i = 0; i < 64; i++) z[i] = (uint8_t)i;
  uint32_t a0[] = {(uint32_t)(uintptr_t)(z + 2), (uint32_t)(uintptr_t)src_hbm, 0};
  accel_run(copy_one, a0, 3);
  for (uint32_t i = 0; i < 64; i++)
    if (z[i] != i) { printf("n = 0 wrote byte %u\n", i); errors++; break; }
  for (int which = 0; which < 2; which++) {
    uint32_t a[] = {(uint32_t)(uintptr_t)(z + (which ? 2 : 3)),
                    (uint32_t)(uintptr_t)(src_hbm + (which ? 1 : 0)), 4};
    accel_launch(copy_one, a, 3);
    st = accel_wait();
    int ok = (st & ACCEL_STATUS_ERROR) && ACCEL_STATUS_CAUSE(st) == ACCEL_ERR_MISALIGNED &&
             accel_rd(ACCEL_ERR_PC) == (uint32_t)(uintptr_t)pc_copy_one;
    printf("odd %s address: %s\n", which ? "source" : "destination",
           ok ? "misaligned, ok" : "WRONG");
    if (!ok) errors++;
    accel_wr(ACCEL_STATUS, ACCEL_STATUS_DONE | ACCEL_STATUS_ERROR);
  }

  // ---- 4. timing: one 30-element run, as in lenet's conv2 ----
  if (cfg.spad_bytes >= SRC_LEN + SLOT) {
    uint32_t a[] = {SPAD_BASE + SRC_LEN + 6, SPAD_BASE + 10, 30};
    accel_run(copy_one, a, 3);
    printf("30-element copy, scratchpad -> scratchpad: %u cycles (whole kernel)\n",
           accel_rd(ACCEL_CYCLES_LO));
  }

  printf("copy: %d errors\n", errors);
  return errors ? 1 : 0;
}