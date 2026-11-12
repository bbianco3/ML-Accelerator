# Matrix memory formats

Large matrices live in HBM and are processed one `MAT_DIM x MAT_DIM` tile at
a time. **How a matrix is laid out in memory is a software choice.** The
hardware provides two primitives that cover the common formats, and
[`sw/common/mat_layout.h`](../sw/common/mat_layout.h) turns a format into the
numbers a kernel needs.

## Hardware primitives

```
mld   tr, base, stride     memory row r = [base + r*stride, +MAT_DIM*2)  ->  tile ROW r
mld.t tr, base, stride     memory row r                                  ->  tile COLUMN r
```

(`mst`/`mst.t` and `msta`/`msta.t` are the store equivalents.) `base` and
`stride` must be multiples of `MAT_DIM*2` bytes.

## Supported formats

With tile size `T = MAT_DIM`:

| Format | Element `(r, c)` at | Tile `(ti, tj)` address | `stride` | instr |
|---|---|---|---|---|
| `MAT_ROW_MAJOR` | `base + 2(r*ld + c)` | `base + ti*T*ld*2 + tj*T*2` | `ld*2` | `mld` |
| `MAT_COL_MAJOR` | `base + 2(c*ld + r)` | `base + ti*T*2 + tj*T*ld*2` | `ld*2` | `mld.t` |
| `MAT_BLOCKED` | tile-contiguous, tiles in row-major order | `base + (ti*cols/T + tj)*T*T*2` | `T*2` | `mld` |

`ld` (the *leading dimension*) is the distance between rows (row-major) or
columns (col-major) in elements. It may be larger than the matrix (padding),
but must be a multiple of `T`.

All three reduce to the same **tile descriptor**:

```c
typedef struct {
  uint32_t base;    // tile (0,0)
  uint32_t rstep;   // + bytes per tile row    (ti -> ti+1)
  uint32_t cstep;   // + bytes per tile column (tj -> tj+1)
  uint32_t stride;  // mld/mst/msta stride operand
  uint32_t xpose;   // use .t forms
} mat_tile_desc_t;
// tile (ti,tj): addr = base + ti*rstep + tj*cstep
```

A kernel that takes descriptors works for **every** format and any mix of
formats. See [`sw/tests/layouts`](../sw/tests/layouts), which runs one GEMM
kernel over all 27 combinations of A/B/C formats and checks that the results
are bit-identical.

## Host API

```c
#include "mat_layout.h"
mat_t A = mat_alloc(M, K, MAT_COL_MAJOR, cfg.mat_dim, /*pad=*/0);  // in HBM
mat_from_rowmajor(&A, host_array, K);      // fill from a plain C array
mat_tile_desc_t d = mat_tile_desc(&A);     // hand this to the kernel
bf16_t x = mat_get(&A, r, c);              // read back any element
```

## Which format should I use?

| Format | Pro | Con |
|---|---|---|
| Row-major | what every C program and framework uses; zero conversion | a tile is `T` separate rows -> `T` separate HBM bursts |
| Column-major | free transpose (e.g. `B^T` weights, `A^T B` products) | same burst pattern as row-major |
| Blocked | each tile is **one contiguous `T*T*2`-byte block**: ideal for long bursts, prefetching and DMA | needs a packing step on the host (or a kernel) |

With the reference memory engine (one transaction at a time, one row per
transaction) all three cost the same, which is what the `layouts` test
prints. Once the memory engine merges contiguous rows into a single burst,
or keeps several requests outstanding, blocked tiles load several times
faster. That makes it a good, measurable student project.

## Adding a format

Formats that are still "rows with a constant stride" (padded, sub-matrix
views, batched matrices with a batch stride) need **no hardware change**.
Add a case to `mat_elem()` and `mat_tile_desc()`. Formats that are not, such
as swizzled/XOR layouts, packed 2:4 sparsity or bf16 pairs interleaved for
SIMD, need a new addressing mode in `accel_core.sv` (the `S_MX_ROW` address
update) plus a new `funct3` value. Document it here and in
[isa.md](isa.md).
