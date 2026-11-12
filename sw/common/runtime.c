// runtime.c -- see runtime.h.
#include "runtime.h"

#include <stdarg.h>

// ---------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------
void putchar_(char c) { *(volatile uint32_t *)SIMCTRL_PUTCHAR = (uint8_t)c; }

void puts_(const char *s) {
  while (*s) putchar_(*s++);
  putchar_('\n');
}

static void out_pad(int n, char c) {
  while (n-- > 0) putchar_(c);
}

static void out_str(const char *s, int width, int left) {
  int len = 0;
  while (s[len]) len++;
  if (!left) out_pad(width - len, ' ');
  for (int i = 0; i < len; i++) putchar_(s[i]);
  if (left) out_pad(width - len, ' ');
}

static void out_uint(uint64_t v, unsigned base, int upper, int neg, int width, int zero, int left) {
  char buf[24];
  int n = 0;
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  do {
    buf[n++] = digits[v % base];
    v /= base;
  } while (v);
  int len = n + (neg ? 1 : 0);
  if (!left && !zero) out_pad(width - len, ' ');
  if (neg) putchar_('-');
  if (!left && zero) out_pad(width - len, '0');
  while (n) putchar_(buf[--n]);
  if (left) out_pad(width - len, ' ');
}

static void out_float(double v, int prec, int width, int left) {
  if (v != v) { out_str("nan", width, left); return; }
  if (v > 1.7e308 || v < -1.7e308) { out_str(v < 0 ? "-inf" : "inf", width, left); return; }
  char buf[64];
  int n = 0;
  if (v < 0 || (v == 0 && 1.0 / v < 0)) { buf[n++] = '-'; v = -v; }
  if (prec > 9) prec = 9;
  double scale = 1;
  for (int i = 0; i < prec; i++) scale *= 10;
  v = v * scale + 0.5;
  if (v >= 1.8e19) { out_str("<big>", width, left); return; }
  uint64_t whole = (uint64_t)v;
  uint64_t ip = whole / (uint64_t)scale, fp = whole % (uint64_t)scale;
  char tmp[24];
  int t = 0;
  do { tmp[t++] = (char)('0' + ip % 10); ip /= 10; } while (ip);
  while (t) buf[n++] = tmp[--t];
  if (prec) {
    buf[n++] = '.';
    for (int i = prec - 1; i >= 0; i--) {
      tmp[i] = (char)('0' + fp % 10);
      fp /= 10;
    }
    for (int i = 0; i < prec; i++) buf[n++] = tmp[i];
  }
  buf[n] = 0;
  out_str(buf, width, left);
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  for (; *fmt; fmt++) {
    if (*fmt != '%') { putchar_(*fmt); continue; }
    fmt++;
    int left = 0, zero = 0, width = 0, prec = -1, lng = 0;
    for (;; fmt++) {
      if (*fmt == '-') left = 1;
      else if (*fmt == '0') zero = 1;
      else break;
    }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    if (*fmt == '.') {
      prec = 0;
      fmt++;
      while (*fmt >= '0' && *fmt <= '9') prec = prec * 10 + (*fmt++ - '0');
    }
    while (*fmt == 'l') { lng++; fmt++; }
    switch (*fmt) {
      case 'd': case 'i': {
        int64_t v = (lng >= 2) ? va_arg(ap, long long) : (lng == 1) ? va_arg(ap, long) : va_arg(ap, int);
        out_uint(v < 0 ? (uint64_t)(-v) : (uint64_t)v, 10, 0, v < 0, width, zero, left);
        break;
      }
      case 'u': case 'x': case 'X': {
        uint64_t v = (lng >= 2) ? va_arg(ap, unsigned long long)
                   : (lng == 1) ? va_arg(ap, unsigned long) : va_arg(ap, unsigned);
        out_uint(v, *fmt == 'u' ? 10 : 16, *fmt == 'X', 0, width, zero, left);
        break;
      }
      case 'p':
        putchar_('0'); putchar_('x');
        out_uint((uintptr_t)va_arg(ap, void *), 16, 0, 0, 8, 1, 0);
        break;
      case 'c': putchar_((char)va_arg(ap, int)); break;
      case 's': { const char *s = va_arg(ap, const char *); out_str(s ? s : "(null)", width, left); break; }
      case 'f': out_float(va_arg(ap, double), prec < 0 ? 6 : prec, width, left); break;
      case '%': putchar_('%'); break;
      case 0: fmt--; break;
      default: putchar_('%'); putchar_(*fmt); break;
    }
  }
  va_end(ap);
  return 0;
}

// ---------------------------------------------------------------------------
// Program control
// ---------------------------------------------------------------------------
void exit(int code) {
  *(volatile uint32_t *)SIMCTRL_EXIT = (uint32_t)code;
  for (;;) {}
}

// ---------------------------------------------------------------------------
// Random numbers
// ---------------------------------------------------------------------------
static uint32_t rng_state = 0x12345678u;

void srand_(uint32_t seed) { rng_state = seed ? seed : 0x12345678u; }

uint32_t rand_u32(void) {
  uint32_t x = rng_state;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  rng_state = x;
  return x;
}

float rand_float(float lo, float hi) {
  float u = (float)(rand_u32() >> 8) * (1.0f / 16777216.0f);
  return lo + (hi - lo) * u;
}

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------
void *memcpy(void *dst, const void *src, size_t n) {
  uint8_t *d = (uint8_t *)dst;
  const uint8_t *s = (const uint8_t *)src;
  while (n--) *d++ = *s++;
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  uint8_t *d = (uint8_t *)dst;
  while (n--) *d++ = (uint8_t)c;
  return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
  const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
  for (; n; n--, x++, y++)
    if (*x != *y) return *x < *y ? -1 : 1;
  return 0;
}

extern char __hbm_free_start[];
static uintptr_t hbm_next;

void *hbm_alloc(size_t bytes, size_t align) {
  if (!hbm_next) hbm_next = (uintptr_t)__hbm_free_start;
  hbm_next = (hbm_next + align - 1) & ~(uintptr_t)(align - 1);
  void *p = (void *)hbm_next;
  hbm_next += bytes;
  if (hbm_next > HBM_BASE + HBM_SIZE) {
    printf("hbm_alloc: out of HBM\n");
    exit(1);
  }
  return p;
}
