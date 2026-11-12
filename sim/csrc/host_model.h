// host_model.h -- timing and energy model of the host CPU.
//
// The host is a FIXED part of the platform: a 2 GHz RV64G core whose area
// and clock are not yours to change. What you control is how much work it
// does. This model charges every host instruction with time (core cycles)
// and energy, in the style of gem5 + McPAT but small enough to live inside
// the RTL simulation:
//
//   time    = sum over instructions of (class latency + cache-miss and
//             branch-mispredict penalties)                      [core cycles]
//   energy  = busy cycles * E_CYCLE + sum of per-event energies
//             + idle cycles * E_IDLE_CYCLE + P_LEAK * time
//
// It is only applied inside the region of interest (roi_begin()/roi_end() in
// sw/common/runtime.h). All constants are below. They are order-of-magnitude
// values for a 7 nm-class application core, NOT the output of a calibrated
// McPAT run -- see docs/host-model.md for how to recalibrate them.
//
// Competition rule: this file is part of the fixed infrastructure.
#ifndef HOST_MODEL_H
#define HOST_MODEL_H

#include <stdint.h>

#include "rv64_iss.h"

// ---- clock -------------------------------------------------------------------
#define HM_CYCLE_PS        500        // 2 GHz

// ---- latency in core cycles, by instruction class ------------------------------
#define HM_LAT_ALU         1
#define HM_LAT_BRANCH      1
#define HM_LAT_JUMP        1
#define HM_LAT_LOAD        2          // L1 hit
#define HM_LAT_STORE       1
#define HM_LAT_MUL         3
#define HM_LAT_DIV         20
#define HM_LAT_FP          3
#define HM_LAT_FMUL        4
#define HM_LAT_FMA         5
#define HM_LAT_FDIV        15
#define HM_LAT_SYS         3
#define HM_LAT_TRAP        8

// ---- penalties in core cycles ---------------------------------------------------
#define HM_PEN_L1_MISS     12         // L1D miss served by L2
#define HM_PEN_L2_MISS     100        // L2 miss served by memory (50 ns)
#define HM_PEN_MISPREDICT  8
#define HM_LAT_DEVICE      1          // MMIO access; the link delay is added by the testbench

// ---- caches (data only; instruction fetch is assumed to hit) --------------------
#define HM_LINE_SHIFT      6          // 64-byte lines
#define HM_L1_SETS         64         // 64 sets x 8 ways x 64 B = 32 KiB
#define HM_L1_WAYS         8
#define HM_L2_SETS         1024       // 1024 sets x 8 ways x 64 B = 512 KiB
#define HM_L2_WAYS         8

// ---- branch prediction ----------------------------------------------------------
#define HM_BHT_ENTRIES     4096       // 2-bit counters, indexed by pc
#define HM_BTB_ENTRIES     512        // last target of indirect jumps; returns always hit

// ---- energy in picojoules ---------------------------------------------------------
#define HM_E_CYCLE         50.0       // every busy cycle: clock tree, pipeline, fetch
#define HM_E_IDLE_CYCLE    5.0        // every cycle spent in WFI or stalled on the device
#define HM_E_ALU           10.0
#define HM_E_BRANCH        10.0
#define HM_E_JUMP          10.0
#define HM_E_LOAD          25.0       // includes the L1 access
#define HM_E_STORE         30.0
#define HM_E_MUL           40.0
#define HM_E_DIV           150.0
#define HM_E_FP            40.0
#define HM_E_FMUL          50.0
#define HM_E_FMA           60.0
#define HM_E_FDIV          200.0
#define HM_E_SYS           10.0
#define HM_E_TRAP          100.0
#define HM_E_L2_ACCESS     200.0      // per L1 miss
#define HM_E_MEM_ACCESS    3000.0     // per L2 miss (one 64-byte line from memory)
#define HM_E_MISPREDICT    100.0      // on top of the wasted cycles

// ---- leakage ------------------------------------------------------------------------
#define HM_P_LEAK_MW       20.0       // core + caches, always on

typedef struct {
  uint64_t instr;
  uint64_t busy_cycles;
  uint64_t class_count[EV_NUM_CLASSES];
  uint64_t l1_miss, l2_miss, mispredict, device;
  double   dyn_pj;                    // busy-cycle + per-event energy
} hm_stats_t;

void hm_reset(void);                               // clear caches, predictor and statistics
// Account one retired instruction. is_device: its memory access went to MMIO.
// Returns the instruction's cost in core cycles.
uint32_t hm_account(const iss_event_t *ev, int is_device);
const hm_stats_t *hm_stats(void);

#endif // HOST_MODEL_H
