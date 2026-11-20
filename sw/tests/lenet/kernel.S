// lenet/kernel.S -- LeNet-5 inference on the accelerator, all cores.
//
// Each core classifies its share of the images (every ncores-th one) and
// runs the whole network itself:
//
//   per image:  conv1 -> conv2      (conv_layer: im2col + GEMM + bias/ReLU + pool)
//   per batch of up to MAT_DIM images:
//               fc1 -> fc2 -> fc3   (fc_layer: GEMM with one image per row)
//
// conv_layer works on "bands" of two output rows, so the 2x2 max pool can run
// right after them, and a band of the conv output fits in the scratchpad:
//   1. im2col: for MAT_DIM output pixels at a time, copy each pixel's
//      K x K x Cin input window into one row of the patch tile (one hcpy2d
//      gathers its K runs of K*Cin contiguous elements),
//   2. GEMM:   band tile = patch tile x weights on the matrix unit,
//   3. 2x2 max pool, then bias + ReLU on the pooled pixels (vector unit;
//      pooling first gives the same bits and does a quarter of the work).
//
// The host does the "compiling": it pads and packs the weights, and decides
// where every buffer lives (scratchpad when it fits, HBM otherwise). All of
// that is in the descriptor; this file only has loops and adds (the
// accelerator has no multiplier for addresses). See main.c for the layout.
#include "accel_isa.h"

// ---- descriptor offsets (struct lenet_desc in main.c) ----
.equ D_WORK,      0
.equ D_NMINE,     4
.equ D_IMG,       8
.equ D_IMGSTEP,  12
.equ D_IMGBYTES, 16
.equ D_IMGBUF,   20
.equ D_POOL1,    24
.equ D_X,        28
.equ D_XBYTES,   32
.equ D_XROW,     36
.equ D_LOGIT,    40
.equ D_LOGSTEP,  44
.equ D_MATDIM,   48
.equ D_TSTART,   52
.equ D_STATS,    56
.equ D_CONV0,    80
.equ D_CONV1,   208
.equ D_FC0,     336
.equ D_FC1,     400
.equ D_FC2,     464
.equ D_BYTES,   528
.equ D_SHIFT,    10          // descriptors are 1024 bytes apart

// struct conv_desc
.equ C_PARAMS,    0
.equ C_PSRC,      4
.equ C_PBYTES,    8
.equ C_BIAS,     12
.equ C_PATCH,    16
.equ C_BAND,     20
.equ C_INROW,    24
.equ C_INPX,     28
.equ C_RUN,      32
.equ C_K,        36
.equ C_PROW,     40
.equ C_PELEMS,   44
.equ C_NKT,      48
.equ C_NNT,      52
.equ C_NMT,      56
.equ C_WKT,      60
.equ C_BROW,     64
.equ C_OUTW,     68
.equ C_NBANDS,   72
.equ C_COUT,     76
.equ C_POOLW,    80
.equ C_INBAND,   84
.equ C_NPIX,     88
.equ C_BROW2,    92
.equ C_COUTPAD,  96
.equ C_SHAPE,    100

// struct fc_desc
.equ F_IN,        0
.equ F_OUT,       4
.equ F_W,         8
.equ F_BIAS,     12
.equ F_INROW,    16
.equ F_OUTROW,   20
.equ F_NKT,      24
.equ F_NNT,      28
.equ F_WKT,      32
.equ F_NPAD,     36
.equ F_RELU,     40

// Register use
//   main (kept across calls): s0 X row, s1 my HBM descriptor, s2 working
//     descriptor, s3 image pointer, s4 images in batch, s5 logits row,
//     s6 images left, s7 = 2*MAT_DIM (bytes per tile column step), s8 = MAT_DIM
//   subroutines may change: a0-a7, t0-t6, s9-s11, gp, tp, ra

// stats[idx] += cycle - t_start; t_start = cycle      (changes t2, t3, t4)
.macro STAT idx
  csrr  t2, cycle
  lw    t3, D_TSTART(s2)
  sub   t3, t2, t3
  lw    t4, D_STATS + 4*\idx(s2)
  add   t4, t4, t3
  sw    t4, D_STATS + 4*\idx(s2)
  sw    t2, D_TSTART(s2)
.endm

//=============================================================================
ACCEL_KERNEL(lenet_kernel)        // a0 = per-core descriptors in HBM
  csrr  t0, mhartid
  slli  t0, t0, D_SHIFT
  add   s1, a0, t0
  lw    s2, D_WORK(s1)            // working copy (in the scratchpad if it fits)
  mv    t0, s2
  mv    t1, s1
  li    t2, D_BYTES
  jal   vcopy
  lw    s8, D_MATDIM(s2)
  slli  s7, s8, 1
  lw    s6, D_NMINE(s2)
  lw    s3, D_IMG(s2)
  lw    s5, D_LOGIT(s2)
  csrr  t0, cycle
  sw    t0, D_TSTART(s2)

.Lbatch:
  beqz  s6, .Ldone
  lw    t0, D_X(s2)               // fc1 input matrix: zero it (padding must be 0)
  lw    t2, D_XBYTES(s2)
  jal   vzero
  lw    s0, D_X(s2)
  li    s4, 0
.Limg:
  beqz  s6, .Lfc
  beq   s4, s8, .Lfc              // at most MAT_DIM images per batch
  lw    t0, D_IMGBUF(s2)          // image -> where conv1 reads it
  mv    t1, s3
  lw    t2, D_IMGBYTES(s2)
  jal   vcopy
  lw    t0, D_IMGSTEP(s2)
  add   s3, s3, t0
  csrr  t0, cycle
  sw    t0, D_TSTART(s2)
  addi  a0, s2, D_CONV0           // conv1: image -> pool1
  lw    a1, D_IMGBUF(s2)
  lw    a2, D_POOL1(s2)
  jal   conv_layer
  addi  a0, s2, D_CONV1           // conv2: pool1 -> row s4 of X
  lw    a1, D_POOL1(s2)
  mv    a2, s0
  jal   conv_layer
  lw    t0, D_XROW(s2)
  add   s0, s0, t0
  addi  s4, s4, 1
  addi  s6, s6, -1
  j     .Limg

.Lfc:
  csrr  t0, cycle
  sw    t0, D_TSTART(s2)
  addi  a0, s2, D_FC0
  jal   fc_layer
  addi  a0, s2, D_FC1
  jal   fc_layer
  addi  a0, s2, D_FC2
  jal   fc_layer
  STAT  3
  lw    s9, D_FC2 + F_OUT(s2)     // copy the logits rows to the output
.Llogits:
  beqz  s4, .Lbatch
  mv    t0, s5
  mv    t1, s9
  lw    t2, D_FC2 + F_OUTROW(s2)
  jal   vcopy
  lw    t0, D_FC2 + F_OUTROW(s2)
  add   s9, s9, t0
  lw    t0, D_LOGSTEP(s2)
  add   s5, s5, t0
  addi  s4, s4, -1
  j     .Llogits

.Ldone:
  lw    t0, D_STATS + 0(s2)       // cycle breakdown back to the host
  sw    t0, D_STATS + 0(s1)
  lw    t0, D_STATS + 4(s2)
  sw    t0, D_STATS + 4(s1)
  lw    t0, D_STATS + 8(s2)
  sw    t0, D_STATS + 8(s1)
  lw    t0, D_STATS + 12(s2)
  sw    t0, D_STATS + 12(s1)
  ecall

//=============================================================================
// conv_layer(a0 = conv descriptor, a1 = input map (HWC), a2 = pooled output (HWC))
//=============================================================================
conv_layer:
  mv    s11, ra
  lw    t0, C_PARAMS(a0)          // weights + bias to where they are used
  lw    t1, C_PSRC(a0)
  beq   t0, t1, 1f
  lw    t2, C_PBYTES(a0)
  jal   vcopy
1:
  lw    t0, C_PATCH(a0)           // zero the patch tile (its padding columns)
  lw    t2, C_PELEMS(a0)
  slli  t2, t2, 1
  jal   vzero
  lw    s9, C_NBANDS(a0)
  mv    s10, a1                   // input window of the band's first pixel
  mv    tp, a2                    // pooled output pointer

.Lband:
  lw    a7, C_BAND(a0)            // band rows for this M tile
  lw    a6, C_NMT(a0)             // M tiles left in the band
  li    a3, 0                     // pixel index in the band
  li    a4, 0                     // x of that pixel
  mv    a5, s10                   // its input window (top-left)
.Lmtile:
  // ---- 1. im2col: up to MAT_DIM patch rows ----
  lw    t0, C_PATCH(a0)
  mv    t1, s8
.Lrow:
  lw    t2, C_NPIX(a0)
  bge   a3, t2, .Lrow_next        // past the band: leave the row as it is
  lw    t2, C_SHAPE(a0)           // K runs of K*Cin elements, an input row apart
  hcpy2d t0, a5, t2               // input window -> patch row
  addi  a3, a3, 1                 // next pixel
  addi  a4, a4, 1
  lw    t2, C_INPX(a0)
  add   a5, a5, t2
  lw    t2, C_OUTW(a0)
  bne   a4, t2, .Lrow_next
  li    a4, 0                     // second output row of the band
  lw    t2, C_INROW(a0)
  add   a5, s10, t2
.Lrow_next:
  lw    t2, C_PROW(a0)
  add   t0, t0, t2
  addi  t1, t1, -1
  bnez  t1, .Lrow
  STAT  0

  // ---- 2. GEMM: band rows = patch tile x weights ----
  lw    t0, C_NNT(a0)
  lw    t1, C_PARAMS(a0)          // weight column tile
  mv    t5, a7                    // band column tile
  lw    gp, C_BROW(a0)            // weight / band row stride
  lw    ra, C_PROW(a0)            // patch row stride
  lw    t6, C_WKT(a0)             // weight bytes per k tile
.Lnt:
  mzero acc0
  lw    t2, C_NKT(a0)
  lw    t3, C_PATCH(a0)
  mv    t4, t1
.Lkt:
  mld   tr0, t3, ra
  mld   tr1, t4, gp
  mmacc acc0, tr0, tr1
  add   t3, t3, s7
  add   t4, t4, t6
  addi  t2, t2, -1
  bnez  t2, .Lkt
  msta  acc0, t5, gp
  add   t1, t1, s7
  add   t5, t5, s7
  addi  t0, t0, -1
  bnez  t0, .Lnt
  STAT  1
  lw    t0, C_WKT(a0)             // MAT_DIM band rows on
  add   a7, a7, t0
  addi  a6, a6, -1
  bnez  a6, .Lmtile

  // ---- 3. 2x2 max pool, then bias + ReLU, all on the vector unit ----
  // Pooling first is exact: bf16 rounding never reverses an order, so
  // max(a_i) + b rounds to max(a_i + b), and ReLU commutes with max. The
  // bias and ReLU then run on a quarter of the pixels.
  lw    t0, C_BAND(a0)            // top-left pixel of the 2x2 window
  lw    t1, C_POOLW(a0)
  lw    gp, C_BROW(a0)            // next pixel in the row
  lw    ra, C_BROW2(a0)           // same pixel in the second row
.Lpx:
  lw    t2, C_COUT(a0)            // channels left
  mv    t3, t0                    // this chunk of channels, top-left pixel
  lw    t4, C_BIAS(a0)
.Lch:
  vsetvl   t5, t2
  vle16    v1, 0(t3)              // top-left
  add      t6, t3, gp
  vle16    v2, 0(t6)              // top-right
  vfmax.vv v1, v1, v2
  add      t6, t3, ra
  vle16    v2, 0(t6)              // bottom-left
  vfmax.vv v1, v1, v2
  add      t6, t6, gp
  vle16    v2, 0(t6)              // bottom-right
  vfmax.vv v1, v1, v2
  vle16    v2, 0(t4)
  vfadd.vv v1, v1, v2             // + bias
  vfmax.vf v1, v1, zero           // ReLU
  vse16    v1, 0(t3)              // park it in the (used) top-left pixel
  slli     t6, t5, 1
  add      t3, t3, t6
  add      t4, t4, t6
  sub      t2, t2, t5
  bnez     t2, .Lch
  lw    t2, C_COUT(a0)            // pooled output is unpadded HWC (not
  hcpy  tp, t0, t2                // VLEN/8-aligned), so copy it out
  slli  t2, t2, 1
  add   tp, tp, t2
  slli  t2, gp, 1                 // two pixels right
  add   t0, t0, t2
  addi  t1, t1, -1
  bnez  t1, .Lpx
  STAT  2

  lw    t0, C_INBAND(a0)          // next band: two input rows down
  add   s10, s10, t0
  addi  s9, s9, -1
  bnez  s9, .Lband
  mv    ra, s11
  ret

//=============================================================================
// fc_layer(a0 = fc descriptor): out[D][n_pad] = act(in[D][k_pad] x W + bias)
//=============================================================================
fc_layer:
  mv    s11, ra
  lw    t0, F_NNT(a0)
  lw    t1, F_W(a0)
  lw    t5, F_OUT(a0)
  lw    gp, F_OUTROW(a0)          // weight / output row stride
  lw    ra, F_INROW(a0)
  lw    t6, F_WKT(a0)
.Lfnt:
  mzero acc0
  lw    t2, F_NKT(a0)
  lw    t3, F_IN(a0)
  mv    t4, t1
.Lfkt:
  mld   tr0, t3, ra
  mld   tr1, t4, gp
  mmacc acc0, tr0, tr1
  add   t3, t3, s7
  add   t4, t4, t6
  addi  t2, t2, -1
  bnez  t2, .Lfkt
  msta  acc0, t5, gp
  add   t1, t1, s7
  add   t5, t5, s7
  addi  t0, t0, -1
  bnez  t0, .Lfnt
  lw    t0, F_OUT(a0)
  mv    t1, s8
  lw    t2, F_NPAD(a0)
  lw    t3, F_BIAS(a0)
  lw    t4, F_RELU(a0)
  jal   bias_relu
  mv    ra, s11
  ret

//=============================================================================
// bias_relu(t0 = rows, t1 = row count, t2 = row length (elements, multiple
// of VLMAX), t3 = bias[row length], t4 = 1 for ReLU): row += bias, max(row, 0)
//=============================================================================
bias_relu:
1:
  beqz  t1, 9f
  mv    t6, t0
  mv    a3, t3
  mv    a4, t2
2:
  vsetvl   t5, a4
  vle16    v1, 0(t6)
  vle16    v2, 0(a3)
  vfadd.vv v1, v1, v2
  beqz     t4, 3f
  vfmax.vf v1, v1, zero
3:
  vse16    v1, 0(t6)
  slli     a5, t5, 1
  add      t6, t6, a5
  add      a3, a3, a5
  sub      a4, a4, t5
  bnez     a4, 2b
  slli  a5, t2, 1
  add   t0, t0, a5
  addi  t1, t1, -1
  j     1b
9:
  ret

// vcopy(t0 = dst, t1 = src, t2 = bytes): both VLEN/8-aligned
vcopy:
  srli  t2, t2, 1
1:
  beqz  t2, 9f
  vsetvl t3, t2
  vle16 v1, 0(t1)
  vse16 v1, 0(t0)
  slli  t4, t3, 1
  add   t0, t0, t4
  add   t1, t1, t4
  sub   t2, t2, t3
  j     1b
9:
  ret

// vzero(t0 = dst, t2 = bytes): dst VLEN/8-aligned
vzero:
  srli  t2, t2, 1
  vsetvl t3, zero
  vmv.v.x v1, zero
1:
  beqz  t2, 9f
  vsetvl t3, t2
  vse16 v1, 0(t0)
  slli  t4, t3, 1
  add   t0, t0, t4
  sub   t2, t2, t3
  j     1b
9:
  ret