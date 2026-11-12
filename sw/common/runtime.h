// runtime.h -- minimal freestanding runtime for host programs.
// There is no libc: use these instead of <stdio.h> / <stdlib.h>.
#ifndef RUNTIME_H
#define RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#include "memory_map.h"

// ---- console (goes to the simulation log, line-buffered, prefixed [host]) --
void putchar_(char c);
void puts_(const char *s);
// Supports %d %i %u %x %X %p %c %s %f %% with optional '-', '0', width and
// (for %f) precision. %d/%u/%x take an int (int32_t, uint32_t); use
// %ld/%lu/%lx or %lld/%llu/%llx for 64-bit values (long, size_t, uint64_t).
int  printf(const char *fmt, ...);

// ---- program control ----
void exit(int code) __attribute__((noreturn));

// Testbench cycle counter (same clock as the accelerator).
static inline uint64_t sim_cycles(void) {
  volatile uint32_t *lo = (volatile uint32_t *)SIMCTRL_CYCLE_LO;
  volatile uint32_t *hi = (volatile uint32_t *)SIMCTRL_CYCLE_HI;
  uint32_t h, l;
  do {
    h = *hi;
    l = *lo;
  } while (h != *hi);
  return ((uint64_t)h << 32) | l;
}

// ---- region of interest ----
// Bracket the work you want measured (the inference, not the test's setup and
// checking). Inside the region the host runs in real time as a 2 GHz core and
// its energy is counted; the simulation prints time and host energy at exit.
// Outside, the host runs +host_ipc instructions per accelerator clock for
// free. See docs/host-model.md.
static inline void roi_begin(void) { *(volatile uint32_t *)SIMCTRL_ROI = 1; }
static inline void roi_end(void)   { *(volatile uint32_t *)SIMCTRL_ROI = 0; }

// ---- deterministic pseudo-random numbers (xorshift32) ----
void     srand_(uint32_t seed);
uint32_t rand_u32(void);
float    rand_float(float lo, float hi);   // uniform in [lo, hi)

// ---- memory ----
void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int   memcmp(const void *a, const void *b, size_t n);

// Bump allocator for HBM buffers beyond the statically declared ones.
// Never frees. Alignment must be a power of two.
void *hbm_alloc(size_t bytes, size_t align);

#endif // RUNTIME_H
