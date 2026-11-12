// mat_layout.h -- matrix storage formats for HBM and how kernels reach tiles.
//
// The matrix unit only knows two hardware primitives:
//   mld   tr, base, stride     memory row r (base + r*stride) -> tile row r
//   mld.t tr, base, stride     memory row r (base + r*stride) -> tile column r
// (same for mst / msta). Every format below is expressed with those, so
// supporting a new format is purely a software change.
//
//   MAT_ROW_MAJOR  element (r,c) at base + 2*(r*ld + c)          ld >= cols
//   MAT_COL_MAJOR  element (r,c) at base + 2*(c*ld + r)          ld >= rows
//   MAT_BLOCKED    tiles of T x T stored contiguously, tile grid row-major,
//                  row-major inside a tile. Each tile is ONE contiguous
//                  block of T*T*2 bytes -- the friendliest format for HBM.
//
// For any format, tile (ti, tj) is loaded with
//     addr   = base + ti*rstep + tj*cstep
//     mld{.t if xpose} tr, addr, stride
// mat_tile_desc() computes {rstep, cstep, stride, xpose}; kernels receive the
// descriptor and never need to know which format they are working on (see
// sw/tests/layouts). Alignment: base, ld*2 must be multiples of T*2 (and of
// VLEN/8 if vector instructions touch the data); mat_alloc() takes care of it.
// See docs/memory-formats.md.
#ifndef MAT_LAYOUT_H
#define MAT_LAYOUT_H

#include <stdint.h>

#include "accel.h"
#include "bf16.h"
#include "runtime.h"

typedef enum { MAT_ROW_MAJOR = 0, MAT_COL_MAJOR = 1, MAT_BLOCKED = 2 } mat_layout_t;

typedef struct {
  bf16_t      *base;
  uint32_t     rows, cols;   // logical size (multiples of tile)
  uint32_t     ld;           // leading dimension in elements (ROW/COL major)
  uint32_t     tile;         // T = MAT_DIM
  mat_layout_t layout;
} mat_t;

// What a kernel needs to address tiles. Layout of this struct is ABI: kernels
// read it with lw at offsets 0, 4, 8, 12, 16.
typedef struct {
  uint32_t base;    // address of tile (0, 0)
  uint32_t rstep;   // bytes to the next tile row    (ti + 1)
  uint32_t cstep;   // bytes to the next tile column (tj + 1)
  uint32_t stride;  // stride operand of mld/mst/msta (bytes)
  uint32_t xpose;   // 1 = use the .t instruction forms
} mat_tile_desc_t;

static inline const char *mat_layout_name(mat_layout_t l) {
  return l == MAT_ROW_MAJOR ? "row-major" : l == MAT_COL_MAJOR ? "col-major" : "blocked";
}

// Allocate a rows x cols bf16 matrix in HBM. `pad` extra elements are added
// to the leading dimension of ROW/COL major matrices (must be a multiple of
// the tile size); padding is a common trick to spread accesses over banks.
static inline mat_t mat_alloc(uint32_t rows, uint32_t cols, mat_layout_t layout,
                              uint32_t tile, uint32_t pad) {
  mat_t m = {0, rows, cols, 0, tile, layout};
  uint32_t elems;
  if (layout == MAT_ROW_MAJOR)      { m.ld = cols + pad; elems = rows * m.ld; }
  else if (layout == MAT_COL_MAJOR) { m.ld = rows + pad; elems = cols * m.ld; }
  else                              { m.ld = 0;          elems = rows * cols; }
  m.base = (bf16_t *)hbm_alloc(elems * 2u, HBM_ALIGN);
  return m;
}

static inline bf16_t *mat_elem(const mat_t *m, uint32_t r, uint32_t c) {
  switch (m->layout) {
    case MAT_ROW_MAJOR: return m->base + r * m->ld + c;
    case MAT_COL_MAJOR: return m->base + c * m->ld + r;
    default: {
      uint32_t T = m->tile, tiles_per_row = m->cols / T;
      uint32_t tile_idx = (r / T) * tiles_per_row + (c / T);
      return m->base + tile_idx * T * T + (r % T) * T + (c % T);
    }
  }
}

static inline bf16_t mat_get(const mat_t *m, uint32_t r, uint32_t c) { return *mat_elem(m, r, c); }
static inline void   mat_set(const mat_t *m, uint32_t r, uint32_t c, bf16_t v) { *mat_elem(m, r, c) = v; }

// Copy in / out of a plain row-major array (src_ld elements per row).
static inline void mat_from_rowmajor(const mat_t *m, const bf16_t *src, uint32_t src_ld) {
  for (uint32_t r = 0; r < m->rows; r++)
    for (uint32_t c = 0; c < m->cols; c++) mat_set(m, r, c, src[r * src_ld + c]);
}

static inline void mat_fill(const mat_t *m, bf16_t v) {
  for (uint32_t r = 0; r < m->rows; r++)
    for (uint32_t c = 0; c < m->cols; c++) mat_set(m, r, c, v);
}

static inline mat_tile_desc_t mat_tile_desc(const mat_t *m) {
  uint32_t T = m->tile, b = (uint32_t)(uintptr_t)m->base;
  mat_tile_desc_t d;
  switch (m->layout) {
    case MAT_ROW_MAJOR:
      d = (mat_tile_desc_t){b, T * m->ld * 2u, T * 2u, m->ld * 2u, 0};
      break;
    case MAT_COL_MAJOR:   // memory "rows" are matrix columns -> transpose
      d = (mat_tile_desc_t){b, T * 2u, T * m->ld * 2u, m->ld * 2u, 1};
      break;
    default:
      d = (mat_tile_desc_t){b, (m->cols / T) * T * T * 2u, T * T * 2u, T * 2u, 0};
      break;
  }
  return d;
}

#endif // MAT_LAYOUT_H
