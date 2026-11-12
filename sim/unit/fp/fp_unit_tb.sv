//-----------------------------------------------------------------------------
// fp_unit_tb.sv -- randomized equivalence check of the RTL floating-point
// functions (hw/rtl/accel_fp_pkg.sv) against the C reference model
// (sw/common/bf16.h, through sim/unit/fp/fp_ref_dpi.c).
//
//   make unit                 (UNIT_N=<iterations>, default 200000)
//   +n=<iterations> +seed=<s> +verbose
//
// Operands are drawn from a mix of distributions: raw random bit patterns
// (covers NaN/inf/subnormal), special values, nearby exponents (catastrophic
// cancellation), and exponents near the underflow / overflow limits.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module fp_unit_tb;
  import accel_fp_pkg::*;

  import "DPI-C" function int ref_fp32_add(input int a, input int b);
  import "DPI-C" function int ref_bf16_mul_fp32(input int a, input int b);
  import "DPI-C" function int ref_fp32_to_bf16(input int x);
  import "DPI-C" function int ref_bf16_add(input int a, input int b);
  import "DPI-C" function int ref_bf16_sub(input int a, input int b);
  import "DPI-C" function int ref_bf16_mul(input int a, input int b);
  import "DPI-C" function int ref_bf16_macc(input int c, input int a, input int b);
  import "DPI-C" function int ref_bf16_max(input int a, input int b);
  import "DPI-C" function int ref_bf16_min(input int a, input int b);
  import "DPI-C" function int ref_mxu_mac(input int acc, input int a, input int b);

  int n, seed, errors, checks;
  bit verbose;

  localparam logic [31:0] F32_SPECIAL [10] = '{
    32'h0000_0000, 32'h8000_0000, 32'h7F80_0000, 32'hFF80_0000, 32'h7FC0_0000,
    32'h7F80_0001, 32'h0000_0001, 32'h807F_FFFF, 32'h7F7F_FFFF, 32'h0080_0000};
  localparam logic [15:0] BF16_SPECIAL [10] = '{
    16'h0000, 16'h8000, 16'h7F80, 16'hFF80, 16'h7FC0,
    16'h7F81, 16'h0001, 16'h807F, 16'h7F7F, 16'h0080};

  // ---------------- operand generators ----------------
  function automatic logic [31:0] gen_f32(logic [31:0] other);
    logic [7:0] e;
    unique case ($urandom % 8)
      0: return $urandom;                                         // anything
      1: return F32_SPECIAL[$urandom % 10];
      2: begin                                                    // near `other`
        e = other[30:23] + 8'($urandom % 5) - 8'd2;
        return {1'($urandom), e, 23'($urandom)};
      end
      3: return {~other[31], other[30:23], other[22:0] ^ 23'($urandom % 16)}; // cancellation
      4: return {1'($urandom), 8'(1 + $urandom % 30), 23'($urandom)};       // tiny
      5: return {1'($urandom), 8'(225 + $urandom % 30), 23'($urandom)};     // huge
      default: return {1'($urandom), 8'(100 + $urandom % 56), 23'($urandom)}; // ~1
    endcase
  endfunction

  function automatic logic [15:0] gen_bf16();
    unique case ($urandom % 8)
      0: return 16'($urandom);
      1: return BF16_SPECIAL[$urandom % 10];
      2: return {1'($urandom), 8'(1 + $urandom % 70), 7'($urandom)};    // product underflow
      3: return {1'($urandom), 8'(185 + $urandom % 70), 7'($urandom)};  // product overflow
      default: return {1'($urandom), 8'(110 + $urandom % 36), 7'($urandom)};
    endcase
  endfunction

  // ---------------- checking ----------------
  task automatic check(string what, logic [31:0] got, logic [31:0] exp,
                       logic [31:0] a, logic [31:0] b, logic [31:0] c = '0);
    checks++;
    if (got !== exp) begin
      errors++;
      if (errors <= 20 || verbose)
        $display("MISMATCH %-14s a=%08h b=%08h c=%08h : rtl=%08h ref=%08h", what, a, b, c, got, exp);
    end
  endtask

  initial begin
    logic [31:0] fa, fb, facc;
    logic [15:0] ha, hb, hc;

    if (!$value$plusargs("n=%d", n)) n = 200000;
    if ($value$plusargs("seed=%d", seed)) void'($urandom(seed));
    verbose = $test$plusargs("verbose");
    errors = 0;
    checks = 0;

    for (int i = 0; i < n; i++) begin
      fa   = gen_f32($urandom);
      fb   = gen_f32(fa);
      facc = gen_f32(fa);
      ha   = gen_bf16();
      hb   = gen_bf16();
      hc   = gen_bf16();

      check("fp32_add",      fp32_add(fa, fb),            ref_fp32_add(fa, fb), fa, fb);
      check("fp32_to_bf16",  32'(fp32_to_bf16(fa)),       ref_fp32_to_bf16(fa), fa, 0);
      check("bf16_mul_fp32", bf16_mul_fp32(ha, hb),       ref_bf16_mul_fp32(ha, hb), 32'(ha), 32'(hb));
      check("bf16_max",      32'(bf16_max(ha, hb)),       ref_bf16_max(ha, hb), 32'(ha), 32'(hb));
      check("bf16_min",      32'(bf16_min(ha, hb)),       ref_bf16_min(ha, hb), 32'(ha), 32'(hb));
      // Lane-level compositions exactly as used in accel_vpu / accel_mxu
      check("bf16_add", 32'(fp32_to_bf16(fp32_add(bf16_to_fp32(ha), bf16_to_fp32(hb)))),
            ref_bf16_add(ha, hb), 32'(ha), 32'(hb));
      check("bf16_sub", 32'(fp32_to_bf16(fp32_add(bf16_to_fp32(ha), bf16_to_fp32(hb) ^ 32'h8000_0000))),
            ref_bf16_sub(ha, hb), 32'(ha), 32'(hb));
      check("bf16_mul", 32'(fp32_to_bf16(bf16_mul_fp32(ha, hb))),
            ref_bf16_mul(ha, hb), 32'(ha), 32'(hb));
      check("bf16_macc", 32'(fp32_to_bf16(fp32_add(bf16_mul_fp32(ha, hb), bf16_to_fp32(hc)))),
            ref_bf16_macc(hc, ha, hb), 32'(ha), 32'(hb), 32'(hc));
      check("mxu_mac", fp32_add(facc, bf16_mul_fp32(ha, hb)),
            ref_mxu_mac(facc, ha, hb), 32'(ha), 32'(hb), facc);
    end

    $display("fp unit test: %0d checks, %0d mismatches", checks, errors);
    if (errors == 0) $display("*** UNIT PASSED ***");
    else             $display("*** UNIT FAILED ***");
    $finish;
  end

endmodule : fp_unit_tb
