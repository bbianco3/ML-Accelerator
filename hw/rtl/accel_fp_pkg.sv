//-----------------------------------------------------------------------------
// accel_fp_pkg.sv
//-----------------------------------------------------------------------------
// Synthesizable floating-point functions used by the vector unit (VPU) and
// matrix unit (MXU). The exact numerical contract implemented here is
// documented in docs/numerics.md and mirrored bit-for-bit by the C reference
// model in sw/common/bf16.h. sim/unit/fp checks the two against each other.
//
// Summary of the numerics contract:
//   * Storage format is bf16 (1 sign, 8 exponent, 7 mantissa bits).
//   * Arithmetic is performed in fp32 and rounded to bf16 with
//     round-to-nearest-even (RNE).
//   * Subnormal inputs are treated as signed zero (DAZ) and subnormal
//     results are flushed to signed zero (FTZ).
//   * Any NaN result is the canonical quiet NaN (bf16 0x7FC0,
//     fp32 0x7FC00000). NaN payloads are never propagated.
//   * bf16 x bf16 products are exact in fp32 (8b x 8b = 16b significand), so
//     multiplication only "rounds" on overflow (-> inf) and underflow (-> 0).
//-----------------------------------------------------------------------------

package accel_fp_pkg;

  localparam logic [15:0] BF16_QNAN = 16'h7FC0;
  localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;

  //---------------------------------------------------------------------------
  // Classification helpers
  //---------------------------------------------------------------------------
  function automatic logic bf16_is_nan(input logic [15:0] x);
    return (x[14:7] == 8'hFF) && (x[6:0] != 7'd0);
  endfunction

  function automatic logic fp32_is_nan(input logic [31:0] x);
    return (x[30:23] == 8'hFF) && (x[22:0] != 23'd0);
  endfunction

  // Denormals-are-zero for bf16 operands.
  function automatic logic [15:0] bf16_daz(input logic [15:0] x);
    if (x[14:7] == 8'h00) return {x[15], 15'd0};
    return x;
  endfunction

  //---------------------------------------------------------------------------
  // Conversions
  //---------------------------------------------------------------------------
  // bf16 -> fp32: exact, except subnormals become signed zero.
  function automatic logic [31:0] bf16_to_fp32(input logic [15:0] x);
    if (x[14:7] == 8'h00) return {x[15], 31'd0};
    return {x, 16'd0};
  endfunction

  // fp32 -> bf16: round to nearest even, canonical NaN, flush-to-zero.
  function automatic logic [15:0] fp32_to_bf16(input logic [31:0] x);
    logic [31:0] r;
    if (fp32_is_nan(x))       return BF16_QNAN;
    if (x[30:23] == 8'h00)    return {x[31], 15'd0};
    // Adding 0x7FFF + lsb implements RNE; a carry out of the mantissa
    // correctly bumps the exponent (and saturates to inf at the top).
    r = x + 32'h0000_7FFF + {31'd0, x[16]};
    return r[31:16];
  endfunction

  //---------------------------------------------------------------------------
  // Leading-zero count of a 27-bit value (value is known to be non-zero).
  //---------------------------------------------------------------------------
  function automatic logic [4:0] lzc27(input logic [26:0] x);
    logic [4:0] n;
    logic       found;
    n     = 5'd0;
    found = 1'b0;
    for (int i = 26; i >= 0; i--) begin
      if (!found && x[i]) begin
        n     = 5'(26 - i);
        found = 1'b1;
      end
    end
    return n;
  endfunction

  //---------------------------------------------------------------------------
  // fp32 addition, RNE, DAZ/FTZ, canonical NaN.
  // Correctly rounded for all normal operands (guard/round/sticky scheme).
  //---------------------------------------------------------------------------
  function automatic logic [31:0] fp32_add(input logic [31:0] a_in,
                                           input logic [31:0] b_in);
    logic [31:0]       a, b, t;
    logic              a_inf, b_inf, a_zero, b_zero;
    logic              sr, rnd;
    logic [7:0]        ea, eb, d;
    logic [53:0]       sh;
    logic [26:0]       xa, xb, m;      // {hidden, frac[22:0], G, R, S}
    logic [27:0]       s;
    logic [24:0]       mr;
    logic [4:0]        lz;
    logic signed [9:0] er;

    // DAZ
    a = (a_in[30:23] == 8'h00) ? {a_in[31], 31'd0} : a_in;
    b = (b_in[30:23] == 8'h00) ? {b_in[31], 31'd0} : b_in;

    a_inf  = (a[30:23] == 8'hFF) && (a[22:0] == 23'd0);
    b_inf  = (b[30:23] == 8'hFF) && (b[22:0] == 23'd0);
    a_zero = (a[30:0] == 31'd0);
    b_zero = (b[30:0] == 31'd0);

    // Special operands
    if (fp32_is_nan(a) || fp32_is_nan(b)) return FP32_QNAN;
    if (a_inf && b_inf)  return (a[31] == b[31]) ? a : FP32_QNAN;
    if (a_inf)           return a;
    if (b_inf)           return b;
    if (a_zero && b_zero) return {a[31] & b[31], 31'd0};
    if (a_zero)          return b;
    if (b_zero)          return a;

    // Order operands so that |a| >= |b|
    if (b[30:0] > a[30:0]) begin
      t = a; a = b; b = t;
    end
    sr = a[31];
    ea = a[30:23];
    eb = b[30:23];
    d  = ea - eb;

    xa = {1'b1, a[22:0], 3'b000};
    if (d >= 8'd27) begin
      xb = 27'd1;                                   // only sticky survives
    end else begin
      sh = {1'b1, b[22:0], 3'b000, 27'd0} >> d;
      xb = sh[53:27];
      xb[0] = xb[0] | (|sh[26:0]);
    end

    if (a[31] == b[31]) begin
      s = {1'b0, xa} + {1'b0, xb};
      if (s[27]) begin
        m    = s[27:1];
        m[0] = m[0] | s[0];
        er   = $signed({2'b00, ea}) + 10'sd1;
      end else begin
        m    = s[26:0];
        er   = $signed({2'b00, ea});
      end
    end else begin
      m = xa - xb;
      if (m == 27'd0) return 32'd0;                 // exact cancellation -> +0
      lz = lzc27(m);
      m  = m << lz;
      er = $signed({2'b00, ea}) - $signed({5'd0, lz});
    end

    // Round to nearest, ties to even
    rnd = m[2] & (m[1] | m[0] | m[3]);
    mr  = {1'b0, m[26:3]} + {24'd0, rnd};
    if (mr[24]) begin
      mr = mr >> 1;
      er = er + 10'sd1;
    end

    if (er <= 0)   return {sr, 31'd0};               // FTZ
    if (er >= 255) return {sr, 8'hFF, 23'd0};        // overflow -> inf
    return {sr, er[7:0], mr[22:0]};
  endfunction

  //---------------------------------------------------------------------------
  // bf16 x bf16 -> fp32. Exact except overflow (-> inf) / underflow (-> 0).
  //---------------------------------------------------------------------------
  function automatic logic [31:0] bf16_mul_fp32(input logic [15:0] a_in,
                                                input logic [15:0] b_in);
    logic [15:0]       a, b, p;
    logic              s, a_inf, b_inf, a_zero, b_zero;
    logic [22:0]       frac;
    logic signed [9:0] e;

    a = bf16_daz(a_in);
    b = bf16_daz(b_in);
    s = a[15] ^ b[15];

    a_inf  = (a[14:7] == 8'hFF) && (a[6:0] == 7'd0);
    b_inf  = (b[14:7] == 8'hFF) && (b[6:0] == 7'd0);
    a_zero = (a[14:0] == 15'd0);
    b_zero = (b[14:0] == 15'd0);

    if (bf16_is_nan(a) || bf16_is_nan(b))      return FP32_QNAN;
    if ((a_inf && b_zero) || (b_inf && a_zero)) return FP32_QNAN;
    if (a_inf || b_inf)                         return {s, 8'hFF, 23'd0};
    if (a_zero || b_zero)                       return {s, 31'd0};

    p = 16'({1'b1, a[6:0]}) * 16'({1'b1, b[6:0]});  // in [2^14, 2^16)
    e = $signed({2'b00, a[14:7]}) + $signed({2'b00, b[14:7]}) - 10'sd127;
    if (p[15]) begin
      e    = e + 10'sd1;
      frac = {p[14:0], 8'd0};
    end else begin
      frac = {p[13:0], 9'd0};
    end

    if (e <= 0)   return {s, 31'd0};
    if (e >= 255) return {s, 8'hFF, 23'd0};
    return {s, e[7:0], frac};
  endfunction

  //---------------------------------------------------------------------------
  // bf16 comparisons, max and min. -0 < +0. NaN in -> canonical NaN out.
  //---------------------------------------------------------------------------
  // a < b for two non-NaN, already-DAZ'd values.
  function automatic logic bf16_lt(input logic [15:0] a, input logic [15:0] b);
    if (a[15] != b[15]) return a[15];
    if (!a[15])         return a[14:0] < b[14:0];
    return a[14:0] > b[14:0];
  endfunction

  function automatic logic [15:0] bf16_max(input logic [15:0] a_in,
                                           input logic [15:0] b_in);
    logic [15:0] a, b;
    a = bf16_daz(a_in);
    b = bf16_daz(b_in);
    if (bf16_is_nan(a) || bf16_is_nan(b)) return BF16_QNAN;
    return bf16_lt(a, b) ? b : a;
  endfunction

  function automatic logic [15:0] bf16_min(input logic [15:0] a_in,
                                           input logic [15:0] b_in);
    logic [15:0] a, b;
    a = bf16_daz(a_in);
    b = bf16_daz(b_in);
    if (bf16_is_nan(a) || bf16_is_nan(b)) return BF16_QNAN;
    return bf16_lt(a, b) ? a : b;
  endfunction

endpackage : accel_fp_pkg
