// host -- self-test of the simulated host CPU (no kernel is run).
//
//   1. RV64G: 64-bit integer, multiply/divide, 32-bit "W" arithmetic, atomics
//      and FP <-> 64-bit integer conversions give the right answers.
//   2. The tolerance check used for matrix results (check.h).
//   3. Region of interest: inside roi_begin()/roi_end() the host is a timed
//      2 GHz core with a cache model, so a loop that misses the cache takes
//      much longer than one that hits. The simulation log then ends with the
//      host's time and energy for the region (docs/host-model.md).
#include "check.h"
#include "runtime.h"

#define CHECK(cond)                                         \
  do {                                                      \
    if (!(cond)) {                                          \
      printf("FAIL line %d: %s\n", __LINE__, #cond);        \
      errors++;                                             \
    }                                                       \
  } while (0)

static int errors;
static uint8_t big[512 * 1024];        // larger than the modelled L1D (32 KiB)

// Read `n` bytes, `stride` apart. Returns accelerator clock cycles spent.
static uint64_t walk(uint32_t n, uint32_t stride, uint32_t *sum) {
  volatile uint8_t *p = big;
  uint32_t s = 0;
  uint64_t t0 = sim_cycles();
  for (uint32_t i = 0; i < n; i++) s += p[(size_t)i * stride];
  uint64_t t1 = sim_cycles();
  *sum = s;
  return t1 - t0;
}

int main(void) {
  printf("host self-test: sizeof(void *) = %d, sizeof(long) = %d\n", (int)sizeof(void *), (int)sizeof(long));
  CHECK(sizeof(void *) == 8 && sizeof(long) == 8);

  // ---- 64-bit integer ----
  volatile uint64_t a = 0x123456789ABCDEF0ull, b = 0xFEDCBA9876543210ull;
  CHECK(a * b == 0x236D88FE5618CF00ull);
  CHECK((uint64_t)(((unsigned __int128)a * b) >> 64) == 0x121FA00AD77D7422ull);            // mulhu
  CHECK((uint64_t)(((__int128)(int64_t)a * (int64_t)b) >> 64) == 0xFFEB49923CC09532ull);   // mulh
  volatile int64_t n = -1234567890123456789ll, d = 987654321ll;
  CHECK(n / d == -1249999988ll && n % d == -725308641ll);
  volatile uint64_t top = 0x8000000000000000ull;
  volatile int sh = 40;
  CHECK((top >> sh) == 8388608ull);
  CHECK((uint64_t)((int64_t)0xF000000000000000ull >> (sh + 20)) == 0xFFFFFFFFFFFFFFFFull);

  // ---- 32-bit arithmetic on a 64-bit core (addw, sraiw, ...) ----
  volatile uint32_t w = 0x7FFFFFFFu;
  CHECK(w + 1u == 0x80000000u);
  CHECK((int32_t)(w + 1u) >> 4 == (int32_t)0xF8000000);
  volatile int32_t wi = -7;
  CHECK(wi / 2 == -3 && wi % 2 == -1 && (uint32_t)wi / 2u == 0x7FFFFFFCu);

  // ---- atomics (lr/sc or amoadd.d) ----
  uint64_t cnt = 41;
  CHECK(__atomic_fetch_add(&cnt, 1, __ATOMIC_SEQ_CST) == 41 && cnt == 42);

  // ---- FP <-> 64-bit integer ----
  volatile double big_d = 9007199254740994.0;      // 2^53 + 2
  CHECK((int64_t)big_d == 9007199254740994ll);
  CHECK((double)top == 9223372036854775808.0);
  volatile float f = -3.75f;
  CHECK((int64_t)f == -3 && (float)n < -1.2e18f);
  printf("1/3 = %f, 2^40 = %lu\n", 1.0 / 3.0, 1ul << 40);

  // ---- tolerance check of check.h (limits come from competition.json) ----
  CHECK(bf16_close(0x3F80, 0x3F80) && bf16_close(0x3F81, 0x3F80));   // 1.0 vs 1.0078
  CHECK(!bf16_close(0x3FA0, 0x3F80) && !bf16_close(0xBF80, 0x3F80)); // 1.25, -1.0 vs 1.0
  CHECK(bf16_close(0x7FC0, 0x7FC1) && !bf16_close(0x7FC0, 0x3F80));  // NaN only matches NaN
  CHECK(bf16_close(0x7F80, 0x7F80) && !bf16_close(0x7F80, 0x7F7F) && !bf16_close(0x7F80, 0xFF80));

  // ---- region of interest: timed host with a cache model ----
  volatile uint32_t *roi = (volatile uint32_t *)SIMCTRL_ROI;
  CHECK(*roi == 0);
  uint32_t s0, s1, s2;
  roi_begin();
  CHECK(*roi == 1);
  uint64_t cold = walk(4096, 64, &s0);   // 4096 different lines, never seen: every load misses
  uint64_t warm = walk(4096, 0, &s1);    // one line: every load hits
  uint64_t again = walk(256, 64, &s2);   // 16 KiB of lines, now in the L1D or L2: fast again
  roi_end();
  CHECK(*roi == 0);
  printf("4096 loads: %u cycles when every load misses the caches, %u when every load hits\n",
         (uint32_t)cold, (uint32_t)warm);
  CHECK(warm > 0 && cold > 8 * warm);
  CHECK(again * 16 < cold);
  CHECK(s0 == 0 && s1 == 0 && s2 == 0);

  printf("host: %d errors\n", errors);
  return errors != 0;
}
