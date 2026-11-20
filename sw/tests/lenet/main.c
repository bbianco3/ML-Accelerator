// lenet -- inference with a pretrained LeNet-5 (MNIST digits) on every core.
//
// The host plays the role of a tiny ML compiler + runtime:
//   1. reads the trained weights and test images (lenet.bin, from train_lenet.py),
//   2. packs the weights into the layouts the kernel wants (padded to the
//      tile size, convolution weights in im2col order),
//   3. plans where every buffer lives: in each core's scratchpad if it fits,
//      in HBM otherwise (all instructions work on both),
//   4. launches lenet_kernel on all cores and checks the logits against a C
//      model of the same network (within the tolerance of check.h), and the
//      predicted digits against the labels.
// Works for any MAT_DIM, VLEN, NUM_CORES and SPAD_KB.
#include "accel.h"
#include "bf16.h"
#include "check.h"
#include "runtime.h"

extern void lenet_kernel(void);
// The pretrained weights and test images (lenet.bin, written by
// train_lenet.py), linked into host RAM. (Not a .S file: every .S file of a
// test is accelerator code.)
__asm__(".section .rodata\n"
        ".balign 8\n"
        ".globl lenet_blob\n"
        "lenet_blob:\n"
        ".incbin \"lenet.bin\"\n"
        ".globl lenet_blob_end\n"
        "lenet_blob_end:\n"
        ".text\n");
extern const uint8_t lenet_blob[], lenet_blob_end[];

//---------------------------------------------------------------------------
// Descriptors shared with kernel.S (offsets are .equ'd there)
//---------------------------------------------------------------------------
struct conv_desc {            // 128 bytes
  uint32_t params, params_src, params_bytes, bias;  // weights[kd_pad][cout_pad] + bias[cout_pad]
  uint32_t patch, band;                             // im2col tile, conv output of 2 rows
  uint32_t in_row_bytes, in_px_bytes, run_elems, k;
  uint32_t patch_row_bytes, patch_elems;
  uint32_t n_ktiles, n_ntiles, n_mtiles;
  uint32_t w_ktile_bytes, band_row_bytes;
  uint32_t out_w, n_bands, cout, pool_w, in_band_bytes, npix, band_row2_bytes, cout_pad;
  uint32_t shape;                                   // hcpy2d operand: {in_row_bytes, k, run}
  uint32_t pad[6];
};
struct fc_desc {              // 64 bytes
  uint32_t in, out, w, bias;
  uint32_t in_row_bytes, out_row_bytes, n_ktiles, n_ntiles, w_ktile_bytes, n_pad, relu;
  uint32_t pad[5];
};
struct lenet_desc {           // one per core, 1024 bytes apart
  uint32_t work;              // where the kernel keeps its working copy
  uint32_t n_mine;            // images this core classifies
  uint32_t img, img_step, img_bytes, img_buf;
  uint32_t pool1;             // conv1 output (pooled, HWC) = conv2 input
  uint32_t x, x_bytes, x_row_bytes;   // fc1 input: one image per row
  uint32_t logit, logit_step;
  uint32_t mat_dim, t_start;
  uint32_t stats[4];          // cycles: im2col, GEMM, bias/ReLU/pool, fully connected
  uint32_t pad[2];
  struct conv_desc conv[2];
  struct fc_desc fc[3];
  uint8_t pad2[1024 - 528];
};
_Static_assert(offsetof(struct lenet_desc, conv) == 80, "kernel.S D_CONV0");
_Static_assert(offsetof(struct lenet_desc, fc) == 336, "kernel.S D_FC0");
_Static_assert(offsetof(struct conv_desc, cout_pad) == 96, "kernel.S C_COUTPAD");
_Static_assert(offsetof(struct conv_desc, shape) == 100, "kernel.S C_SHAPE");
_Static_assert(sizeof(struct conv_desc) == 128, "kernel.S D_CONV1");
_Static_assert(offsetof(struct fc_desc, relu) == 40, "kernel.S F_RELU");
_Static_assert(sizeof(struct lenet_desc) == 1024, "kernel.S D_SHIFT");
#define DESC_USED 528

//---------------------------------------------------------------------------
// Network
//---------------------------------------------------------------------------
struct conv_spec { int in_w, cin, k, cout; };            // square inputs
static const struct conv_spec C1 = {32, 1, 5, 6};        // 32x32x1  -> 28x28x6  -> 14x14x6
static const struct conv_spec C2 = {14, 6, 5, 16};       // 14x14x6  -> 10x10x16 -> 5x5x16
static const int FC_K[3] = {400, 120, 84}, FC_N[3] = {120, 84, 10};
#define MACS_PER_IMAGE (28 * 28 * 6 * 25 + 10 * 10 * 16 * 150 + 400 * 120 + 120 * 84 + 84 * 10)

struct blob {
  const bf16_t *cw[2], *cb[2], *fw[3], *fb[3];
  const uint8_t *img, *label;
  uint32_t n, acc32, acc16;
};

static uint32_t rup(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }
static uint32_t umax(uint32_t a, uint32_t b) { return a > b ? a : b; }

static int read_blob(struct blob *b) {
  const uint32_t *h = (const uint32_t *)lenet_blob;
  if (memcmp(lenet_blob, "LNT1", 4) != 0) return -1;
  b->n = h[1];
  b->acc32 = h[2];
  b->acc16 = h[3];
  const bf16_t *p = (const bf16_t *)(lenet_blob + 16);
  b->cw[0] = p; p += 6 * 25;
  b->cb[0] = p; p += 6;
  b->cw[1] = p; p += 16 * 150;
  b->cb[1] = p; p += 16;
  for (int l = 0; l < 3; l++) {
    b->fw[l] = p; p += FC_N[l] * FC_K[l];
    b->fb[l] = p; p += FC_N[l];
  }
  b->img = (const uint8_t *)p;
  b->label = b->img + b->n * 28 * 28;
  return (b->label + b->n <= lenet_blob_end) ? 0 : -1;
}

//---------------------------------------------------------------------------
// Packed layer geometry (what the accelerator and the reference both use)
//---------------------------------------------------------------------------
struct conv_geom {
  struct conv_spec s;
  uint32_t out_w, kd, kd_pad, cout_pad, n_mtiles, params_bytes, patch_bytes, band_bytes;
  bf16_t *params;             // [kd_pad][cout_pad] then bias[cout_pad], in HBM
};
struct fc_geom {
  uint32_t k_pad, n_pad;
  bf16_t *w, *bias;           // [k_pad][n_pad], [n_pad], in HBM
};

// Convolution weights in im2col order: row kk = (ky*K + kx)*Cin + ci, column co.
static void pack_conv(struct conv_geom *g, const bf16_t *w, const bf16_t *b, uint32_t D, uint32_t CP) {
  const struct conv_spec *s = &g->s;
  g->out_w = (uint32_t)(s->in_w - s->k + 1);
  g->kd = (uint32_t)(s->k * s->k * s->cin);
  g->kd_pad = rup(g->kd, D);
  g->cout_pad = rup((uint32_t)s->cout, CP);
  g->n_mtiles = (2 * g->out_w + D - 1) / D;
  g->params_bytes = (g->kd_pad + 1) * g->cout_pad * 2;
  g->patch_bytes = D * g->kd_pad * 2;
  g->band_bytes = g->n_mtiles * D * g->cout_pad * 2;
  g->params = hbm_alloc(g->params_bytes, HBM_ALIGN);
  memset(g->params, 0, g->params_bytes);
  for (int co = 0; co < s->cout; co++) {
    for (int ci = 0; ci < s->cin; ci++)
      for (int ky = 0; ky < s->k; ky++)
        for (int kx = 0; kx < s->k; kx++) {
          uint32_t kk = (uint32_t)((ky * s->k + kx) * s->cin + ci);
          g->params[kk * g->cout_pad + (uint32_t)co] = bf16_import(w[((co * s->cin + ci) * s->k + ky) * s->k + kx]);
        }
    g->params[g->kd_pad * g->cout_pad + (uint32_t)co] = bf16_import(b[co]);
  }
}

// fc1's input is conv2's pooled output in HWC order; PyTorch flattens CHW.
static void pack_fc(struct fc_geom *g, int l, uint32_t k_pad, const bf16_t *w, const bf16_t *b,
                    uint32_t CP) {
  g->k_pad = k_pad;
  g->n_pad = rup((uint32_t)FC_N[l], CP);
  g->w = hbm_alloc(g->k_pad * g->n_pad * 2, HBM_ALIGN);
  g->bias = hbm_alloc(g->n_pad * 2, HBM_ALIGN);
  memset(g->w, 0, g->k_pad * g->n_pad * 2);
  memset(g->bias, 0, g->n_pad * 2);
  for (int n = 0; n < FC_N[l]; n++) {
    for (int k = 0; k < FC_K[l]; k++) {
      int src = k;
      if (l == 0) {                      // k = (y*5 + x)*16 + c  <-  c*25 + y*5 + x
        int c = k % 16, yx = k / 16;
        src = c * 25 + yx;
      }
      g->w[(uint32_t)k * g->n_pad + (uint32_t)n] = bf16_import(w[n * FC_K[l] + src]);
    }
    g->bias[n] = bf16_import(b[n]);
  }
}

//---------------------------------------------------------------------------
// Reference: the same arithmetic as the kernel, element by element
//---------------------------------------------------------------------------
static bf16_t ref_act[28 * 28 * 16];
static bf16_t ref_patch[512];

static void ref_conv(const struct conv_geom *g, const bf16_t *in, bf16_t *pooled) {
  const struct conv_spec *s = &g->s;
  const uint32_t W = g->out_w, cp = g->cout_pad;
  const bf16_t *bias = g->params + g->kd_pad * cp;
  for (uint32_t y = 0; y < W; y++)
    for (uint32_t x = 0; x < W; x++) {
      for (uint32_t kk = 0; kk < g->kd_pad; kk++) {
        bf16_t v = 0;
        if (kk < g->kd) {
          uint32_t run = (uint32_t)(s->k * s->cin), ky = kk / run, kx = (kk % run) / (uint32_t)s->cin,
                   ci = kk % (uint32_t)s->cin;
          v = in[((y + ky) * (uint32_t)s->in_w + x + kx) * (uint32_t)s->cin + ci];
        }
        ref_patch[kk] = v;
      }
      for (int co = 0; co < s->cout; co++) {
        float acc = 0.0f;                                  // mzero
        for (uint32_t kk = 0; kk < g->kd_pad; kk++)        // mmacc over the k tiles, k ascending
          acc = mxu_mac(acc, ref_patch[kk], g->params[kk * cp + (uint32_t)co]);
        bf16_t v = bf16_add(f32_to_bf16(acc), bias[co]);   // msta, vfadd
        ref_act[(y * W + x) * (uint32_t)s->cout + (uint32_t)co] = bf16_max(v, 0);   // vfmax (ReLU)
      }
    }
  const uint32_t P = W / 2, C = (uint32_t)s->cout;
  for (uint32_t y = 0; y < P; y++)
    for (uint32_t x = 0; x < P; x++)
      for (uint32_t c = 0; c < C; c++) {
        const bf16_t *a = &ref_act[((2 * y) * W + 2 * x) * C + c];
        bf16_t m = bf16_max(bf16_max(a[0], a[C]), bf16_max(a[W * C], a[W * C + C]));
        pooled[(y * P + x) * C + c] = m;
      }
}

static void ref_fc(const struct fc_geom *g, int l, const bf16_t *in, bf16_t *out) {
  for (uint32_t n = 0; n < g->n_pad; n++) {
    if (n >= (uint32_t)FC_N[l]) {             // padding columns: zero weights and bias
      out[n] = 0;
      continue;
    }
    float acc = 0.0f;
    for (uint32_t k = 0; k < g->k_pad; k++) acc = mxu_mac(acc, in[k], g->w[k * g->n_pad + n]);
    bf16_t v = bf16_add(f32_to_bf16(acc), g->bias[n]);
    out[n] = (l < 2) ? bf16_max(v, 0) : v;
  }
}

//---------------------------------------------------------------------------
int main(void) {
  accel_config_t cfg = accel_get_config();
  accel_print_config(&cfg);
  struct blob b;
  if (read_blob(&b) != 0) {
    printf("lenet.bin is missing or corrupt\n");
    return 1;
  }
  printf("LeNet-5, pretrained on MNIST: %u.%02u %% test accuracy (bf16 weights: %u.%02u %%)\n",
         b.acc32 / 100, b.acc32 % 100, b.acc16 / 100, b.acc16 % 100);

  // the kernel needs a VPU and an MXU on every core it runs on
  const uint32_t D = cfg.mat_dim, NC = cfg.num_full_cores;
  const uint32_t CP = umax(D, cfg.vlmax);              // row lengths: whole tiles and vectors
  const uint32_t AL = umax(2 * D, cfg.vlen / 8);       // buffer alignment (mld/mst, vle/vse)

  // ---- 2. pack the weights ----
  struct conv_geom cg[2] = {{.s = C1}, {.s = C2}};
  pack_conv(&cg[0], b.cw[0], b.cb[0], D, CP);
  pack_conv(&cg[1], b.cw[1], b.cb[1], D, CP);
  struct fc_geom fg[3];
  pack_fc(&fg[0], 0, rup(400, D), b.fw[0], b.fb[0], CP);
  pack_fc(&fg[1], 1, fg[0].n_pad, b.fw[1], b.fb[1], CP);
  pack_fc(&fg[2], 2, fg[1].n_pad, b.fw[2], b.fb[2], CP);

  // ---- 3. plan the per-core working memory ----
  //  conv phase: [desc][weights+bias][patch tile | image][band][pool1]
  //  fc phase:   [desc][h1][h2][h3]                    (reuses the conv space)
  const uint32_t img_bytes = 32 * 32 * 2, pool1_bytes = 14 * 14 * 6 * 2;
  const uint32_t o_params = rup(DESC_USED, AL);
  const uint32_t o_patch = o_params + rup(umax(cg[0].params_bytes, cg[1].params_bytes), AL);
  const uint32_t o_img = o_patch + rup(cg[0].patch_bytes, AL);
  const uint32_t o_band = o_patch + umax(rup(cg[0].patch_bytes, AL) + rup(img_bytes, AL),
                                         rup(cg[1].patch_bytes, AL));
  const uint32_t o_pool1 = o_band + rup(umax(cg[0].band_bytes, cg[1].band_bytes), AL);
  const uint32_t conv_end = o_pool1 + rup(pool1_bytes, AL);
  uint32_t o_h[3], fc_end = o_params;
  for (int l = 0; l < 3; l++) {
    o_h[l] = fc_end;
    fc_end += rup(D * fg[l].n_pad * 2, AL);
  }
  const uint32_t need = umax(conv_end, fc_end);
  const uint32_t x_bytes = D * fg[0].k_pad * 2;
  const int in_spad = need <= cfg.spad_bytes;
  const int x_in_spad = in_spad && need + rup(x_bytes, AL) <= cfg.spad_bytes;
  uint32_t n_img = b.n;
  if (!in_spad && n_img > NC) n_img = NC;   // everything in HBM: correct but slow, 1 image per core
  printf("working memory per core: %u bytes + fc1 input %u bytes -> %s%s (scratchpad: %u bytes)\n",
         need, x_bytes, in_spad ? "scratchpad" : "HBM",
         in_spad ? (x_in_spad ? "" : ", fc1 input in HBM") : "", cfg.spad_bytes);
  if (n_img < b.n) printf("(using %u of %u images to keep the simulation short)\n", n_img, b.n);

  // Images: normalized like in training, zero-padded to 32x32, bf16
  bf16_t *images = hbm_alloc(n_img * img_bytes, HBM_ALIGN);
  memset(images, 0, n_img * img_bytes);
  for (uint32_t i = 0; i < n_img; i++)
    for (int y = 0; y < 28; y++)
      for (int x = 0; x < 28; x++) {
        float v = ((float)b.img[i * 784 + (uint32_t)(y * 28 + x)] / 255.0f - 0.1307f) / 0.3081f;
        images[i * 1024 + (uint32_t)((y + 2) * 32 + x + 2)] = f32_to_bf16(v);
      }
  const uint32_t logit_row = fg[2].n_pad * 2;
  bf16_t *logits = hbm_alloc(n_img * logit_row, HBM_ALIGN);
  memset(logits, 0xFF, n_img * logit_row);

  // ---- descriptors, one per core ----
  struct lenet_desc *desc = hbm_alloc(NC * sizeof(struct lenet_desc), 1024);
  for (uint32_t c = 0; c < NC; c++) {
    uint32_t local = SPAD_BASE, xaddr;
    if (!in_spad) local = (uint32_t)(uintptr_t)hbm_alloc(need, HBM_ALIGN);
    xaddr = x_in_spad ? local + need : (uint32_t)(uintptr_t)hbm_alloc(x_bytes, HBM_ALIGN);
    struct lenet_desc *d = &desc[c];
    memset(d, 0, sizeof *d);
    d->work = local;
    d->n_mine = (c < n_img) ? (n_img - c + NC - 1) / NC : 0;
    d->img = (uint32_t)(uintptr_t)images + c * img_bytes;
    d->img_step = NC * img_bytes;
    d->img_bytes = img_bytes;
    d->img_buf = local + o_img;
    d->pool1 = local + o_pool1;
    d->x = xaddr;
    d->x_bytes = x_bytes;
    d->x_row_bytes = fg[0].k_pad * 2;
    d->logit = (uint32_t)(uintptr_t)logits + c * logit_row;
    d->logit_step = NC * logit_row;
    d->mat_dim = D;
    for (int l = 0; l < 2; l++) {
      const struct conv_geom *g = &cg[l];
      struct conv_desc *cd = &d->conv[l];
      cd->params_src = (uint32_t)(uintptr_t)g->params;
      cd->params = in_spad ? local + o_params : cd->params_src;
      cd->params_bytes = g->params_bytes;
      cd->bias = cd->params + g->kd_pad * g->cout_pad * 2;
      cd->patch = local + o_patch;
      cd->band = local + o_band;
      cd->in_row_bytes = (uint32_t)(g->s.in_w * g->s.cin * 2);
      cd->in_px_bytes = (uint32_t)(g->s.cin * 2);
      cd->run_elems = (uint32_t)(g->s.k * g->s.cin);
      cd->k = (uint32_t)g->s.k;
      cd->patch_row_bytes = g->kd_pad * 2;
      cd->patch_elems = D * g->kd_pad;
      cd->n_ktiles = g->kd_pad / D;
      cd->n_ntiles = g->cout_pad / D;
      cd->n_mtiles = g->n_mtiles;
      cd->w_ktile_bytes = D * g->cout_pad * 2;
      cd->band_row_bytes = g->cout_pad * 2;
      cd->out_w = g->out_w;
      cd->n_bands = g->out_w / 2;
      cd->cout = (uint32_t)g->s.cout;
      cd->pool_w = g->out_w / 2;
      cd->in_band_bytes = 2 * cd->in_row_bytes;
      cd->npix = 2 * g->out_w;
      cd->band_row2_bytes = g->out_w * g->cout_pad * 2;
      cd->cout_pad = g->cout_pad;
      // one im2col patch row = K runs of K*Cin elements, an input row apart
      if (cd->run_elems > 255 || cd->k > 255 || cd->in_row_bytes > 0xFFFF) {
        printf("conv%d too large for hcpy2d\n", l + 1);
        return 1;
      }
      cd->shape = (cd->in_row_bytes << 16) | (cd->k << 8) | cd->run_elems;
    }
    for (int l = 0; l < 3; l++) {
      const struct fc_geom *g = &fg[l];
      struct fc_desc *fd = &d->fc[l];
      fd->in = (l == 0) ? xaddr : local + o_h[l - 1];
      fd->out = local + o_h[l];
      fd->w = (uint32_t)(uintptr_t)g->w;
      fd->bias = (uint32_t)(uintptr_t)g->bias;
      fd->in_row_bytes = g->k_pad * 2;
      fd->out_row_bytes = g->n_pad * 2;
      fd->n_ktiles = g->k_pad / D;
      fd->n_ntiles = g->n_pad / D;
      fd->w_ktile_bytes = D * g->n_pad * 2;
      fd->n_pad = g->n_pad;
      fd->relu = (l < 2);
    }
  }

  // ---- 4. run on all cores ----
  // Region of interest = the inference itself (not weight packing or checking).
  uint32_t args[] = {(uint32_t)(uintptr_t)desc};
  // The host only waits here. Polling STATUS (the default) keeps the host CPU
  // busy; build with SW_CFLAGS="-O2 -g -DLENET_WAIT_IRQ" to sleep until the
  // interrupt instead and compare the host energy (docs/software-optimization.md).
  roi_begin();
  accel_launch_cores(lenet_kernel, args, 1, NC);
#ifdef LENET_WAIT_IRQ
  uint32_t st = accel_wait_irq();
#else
  uint32_t st = accel_wait();
#endif
  roi_end();
  if (st & ACCEL_STATUS_ERROR) accel_report_error(st);
  if (st & ACCEL_STATUS_ERROR) return 1;
  uint32_t cyc = (uint32_t)accel_cycles();

  // ---- check: logits within tolerance of the reference, and the digits ----
  float max_err = 0.0f;
  int errors = 0, correct = 0, ref_correct = 0;
  static bf16_t x_in[1024], p1[14 * 14 * 6], h[4][512];
  printf("image : label predicted\n");
  for (uint32_t i = 0; i < n_img; i++) {
    memcpy(x_in, &images[i * 1024], img_bytes);
    ref_conv(&cg[0], x_in, p1);
    memset(h[0], 0, sizeof h[0]);
    ref_conv(&cg[1], p1, h[0]);                        // 400 values; padding stays 0
    ref_fc(&fg[0], 0, h[0], h[1]);
    ref_fc(&fg[1], 1, h[1], h[2]);
    ref_fc(&fg[2], 2, h[2], h[3]);
    const bf16_t *got = &logits[i * fg[2].n_pad];
    int best = 0, ref_best = 0;
    for (int n = 0; n < 10; n++) {
      if (bf16_to_f32(h[3][n]) > bf16_to_f32(h[3][ref_best])) ref_best = n;
      check_track(&max_err, got[n], h[3][n]);
      if (!bf16_close(got[n], h[3][n])) {
        if (errors < 10) printf("  image %u logit %d: got 0x%04x expected 0x%04x\n", i, n, got[n], h[3][n]);
        errors++;
      }
      if (bf16_to_f32(got[n]) > bf16_to_f32(got[best])) best = n;
    }
    correct += (best == b.label[i]);
    ref_correct += (ref_best == b.label[i]);
    printf("  %2u  :   %u     %d %s\n", i, b.label[i], best, best == b.label[i] ? "" : "<-- wrong");
  }
  printf("logits vs. reference model: %s (largest difference %f); %d of %u digits correct\n",
         errors ? "MISMATCH" : "within tolerance", (double)max_err, correct, n_img);

  // ---- performance ----
  const uint32_t macs = n_img * MACS_PER_IMAGE;
  const uint32_t *s = desc[0].stats;
  uint32_t tot = s[0] + s[1] + s[2] + s[3];
  if (tot == 0) tot = 1;
  printf("%u images on %u core%s: %u cycles (%u per image), %u.%02u MACs/cycle\n", n_img, NC,
         NC > 1 ? "s" : "", cyc, cyc / n_img, macs / cyc, (macs % cyc) * 100 / cyc);
  printf("core 0 time: im2col %u%%, conv GEMM %u%%, bias/ReLU/pool %u%%, fully connected %u%%\n",
         s[0] * 100 / tot, s[1] * 100 / tot, s[2] * 100 / tot, s[3] * 100 / tot);

  if (correct < ref_correct) errors++;      // as many digits right as the reference model (in bf16: all)
  printf("lenet: %d errors\n", errors);
  return errors ? 1 : 0;
}