// host_model.c -- timing and energy model of the host CPU (see host_model.h).
#include "host_model.h"

#include <string.h>

typedef struct {
  uint64_t tag[HM_L2_WAYS];        // line address + 1 (0 = invalid)
  uint32_t age[HM_L2_WAYS];
} cset_t;

static cset_t   l1[HM_L1_SETS], l2[HM_L2_SETS];
static uint32_t lru_clock;
static uint8_t  bht[HM_BHT_ENTRIES];
static uint64_t btb[HM_BTB_ENTRIES];
static hm_stats_t st;

static const uint8_t lat[EV_NUM_CLASSES] = {
  [EV_ALU] = HM_LAT_ALU,   [EV_BRANCH] = HM_LAT_BRANCH, [EV_JUMP] = HM_LAT_JUMP,
  [EV_LOAD] = HM_LAT_LOAD, [EV_STORE] = HM_LAT_STORE,   [EV_MUL] = HM_LAT_MUL,
  [EV_DIV] = HM_LAT_DIV,   [EV_FP] = HM_LAT_FP,         [EV_FMUL] = HM_LAT_FMUL,
  [EV_FMA] = HM_LAT_FMA,   [EV_FDIV] = HM_LAT_FDIV,     [EV_SYS] = HM_LAT_SYS,
  [EV_TRAP] = HM_LAT_TRAP};

static const double energy[EV_NUM_CLASSES] = {
  [EV_ALU] = HM_E_ALU,   [EV_BRANCH] = HM_E_BRANCH, [EV_JUMP] = HM_E_JUMP,
  [EV_LOAD] = HM_E_LOAD, [EV_STORE] = HM_E_STORE,   [EV_MUL] = HM_E_MUL,
  [EV_DIV] = HM_E_DIV,   [EV_FP] = HM_E_FP,         [EV_FMUL] = HM_E_FMUL,
  [EV_FMA] = HM_E_FMA,   [EV_FDIV] = HM_E_FDIV,     [EV_SYS] = HM_E_SYS,
  [EV_TRAP] = HM_E_TRAP};

void hm_reset(void) {
  memset(l1, 0, sizeof l1);
  memset(l2, 0, sizeof l2);
  memset(bht, 1, sizeof bht);      // weakly not-taken
  memset(btb, 0, sizeof btb);
  memset(&st, 0, sizeof st);
  lru_clock = 0;
}

const hm_stats_t *hm_stats(void) { return &st; }

// Look up a line in a set-associative LRU cache; insert it on a miss.
static int cache_access(cset_t *sets, unsigned nsets, unsigned ways, uint64_t line) {
  cset_t *s = &sets[line % nsets];
  uint64_t tag = line + 1;
  unsigned victim = 0;
  lru_clock++;
  for (unsigned w = 0; w < ways; w++) {
    if (s->tag[w] == tag) {
      s->age[w] = lru_clock;
      return 1;
    }
    if (s->age[w] < s->age[victim]) victim = w;
  }
  s->tag[victim] = tag;
  s->age[victim] = lru_clock;
  return 0;
}

uint32_t hm_account(const iss_event_t *ev, int is_device) {
  uint32_t cyc = lat[ev->cls];
  double   e   = energy[ev->cls];

  if (ev->mem != EV_MEM_NONE) {
    if (is_device) {
      cyc = HM_LAT_DEVICE;
      st.device++;
    } else {
      uint64_t line = ev->addr >> HM_LINE_SHIFT;
      if (!cache_access(l1, HM_L1_SETS, HM_L1_WAYS, line)) {
        st.l1_miss++;
        cyc += HM_PEN_L1_MISS;
        e   += HM_E_L2_ACCESS;
        if (!cache_access(l2, HM_L2_SETS, HM_L2_WAYS, line)) {
          st.l2_miss++;
          cyc += HM_PEN_L2_MISS;
          e   += HM_E_MEM_ACCESS;
        }
      }
    }
  }

  int miss = 0;
  if (ev->cls == EV_BRANCH) {
    uint8_t *ctr = &bht[(ev->pc >> 2) % HM_BHT_ENTRIES];
    miss = ((*ctr >= 2) != (ev->taken != 0));
    if (ev->taken) { if (*ctr < 3) (*ctr)++; }
    else           { if (*ctr > 0) (*ctr)--; }
  } else if (ev->indirect && !ev->is_ret) {
    uint64_t *t = &btb[(ev->pc >> 2) % HM_BTB_ENTRIES];
    miss = (*t != ev->target);
    *t = ev->target;
  }
  if (miss) {
    st.mispredict++;
    cyc += HM_PEN_MISPREDICT;
    e   += HM_E_MISPREDICT;
  }

  st.instr++;
  st.class_count[ev->cls]++;
  st.busy_cycles += cyc;
  st.dyn_pj += e + (double)cyc * HM_E_CYCLE;
  return cyc;
}
