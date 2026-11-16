//-----------------------------------------------------------------------------
// accel_vpu.sv 4
//-----------------------------------------------------------------------------
// Vector unit: the vector register file v0..v31 and VLMAX = VLEN/16 bf16
// lanes. The core decodes the instruction and drives this unit; the unit has
// no state machine of its own.
//
// Ways in/out, all controlled by the core:
//   1. Arithmetic   ar_en: vd = op(vs2, op1) for every lane i < vl, written
//                   at the next clock edge. op1 is vs1 (.vv) or the scalar
//                   broadcast to every lane (.vf).
//   2. Load write   ld_en: vd = ld_data for every lane i < vl (vle16).
//   3. Read port    rd_idx -> rd_data, combinational (vse16 reads vs3,
//                   vmv.x.s reads lane 0 of vs2).
//   4. Lane-0 write sx_en: vd[0] = sx_data if vl > 0 (vmv.s.x).
//   5. Reduction    red_start: vfredsum / vfredmax over lanes 0..vl-1.
//                   Takes vl cycles; red_done pulses in the last one, the
//                   same cycle vd[0] is written. The core must hold vl and
//                   not touch the VPU until then, and must not start a
//                   reduction with vl = 0 (that is a no-op).
//
// Lanes i >= vl are never written ("tail undisturbed").
//
// Element-wise operations go through a three-stage pipeline per lane:
//   stage 1 (the cycle ar_en is high): read operands, multiply / prepare the
//            two adder inputs, or compute the result directly (mul, max,
//            min, mv need no adder)                         -> s1_* registers
//   stage 2: fp32_add_align                                 -> s2_* registers
//   stage 3: fp32_add_finish, round to bf16, write vd lanes i < vl
// ar_busy is high while an operation is in stages 2-3; the core waits for it
// before the next instruction, so nothing can read vd too early.
//
// Reductions process ONE element per step, strictly in order 0, 1, ...,
// vl-1: floating-point addition is not associative, and numerics.md fixes
// this order, so an adder tree would give different bits. With the adder
// split in two, each step takes two cycles (align, then finish), because the
// next element needs the previous sum.
//-----------------------------------------------------------------------------

module accel_vpu
  import accel_pkg::*;
  import accel_fp_pkg::*;
#(
  parameter int VLEN = 256
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic [$clog2(VLEN/16):0] vl,       // 0 .. VLMAX

  // 1. arithmetic
  input  logic                    ar_en,      // 1-cycle pulse: start an op
  output logic                    ar_busy,    // op still in the pipeline
  input  logic [6:0]              ar_op,     // funct7: VOP_*
  input  logic                    ar_vf,     // 1: op1 = scalar broadcast
  input  logic [4:0]              ar_vd,
  input  logic [4:0]              ar_vs1,
  input  logic [4:0]              ar_vs2,
  input  logic [15:0]             ar_scalar,

  // 2. load write
  input  logic                    ld_en,
  input  logic [4:0]              ld_vd,
  input  logic [VLEN-1:0]         ld_data,

  // 3. read port
  input  logic [4:0]              rd_idx,
  output logic [VLEN-1:0]         rd_data,

  // 4. lane-0 write (vmv.s.x)
  input  logic                    sx_en,
  input  logic [4:0]              sx_vd,
  input  logic [15:0]             sx_data,

  // 5. reduction (vfredsum / vfredmax)
  input  logic                    red_start,  // 1-cycle pulse from EXEC
  input  logic                    red_max,    // 0: sum, 1: max
  input  logic                    red_vf,     // init = scalar (.vf) or vs1[0] (.vs)
  input  logic [4:0]              red_vd,
  input  logic [4:0]              red_vs1,
  input  logic [4:0]              red_vs2,
  input  logic [15:0]             red_scalar,
  output logic                    red_done   // pulse: vd[0] written this cycle
);

  localparam int VLMAX = VLEN / 16;

  logic [VLEN-1:0] vreg [32];

  //---------------------------------------------------------------------------
  // Element-wise datapath: VLMAX lanes side by side, three stages
  //---------------------------------------------------------------------------
  // Per lane, with a = vs2[i], b = op1[i], d = old vd[i] (for vfmacc), the
  // result matches the C reference in sw/common/bf16.h bit for bit:
  //   add : r(add32(f(a),  f(b)))       mul : r(mul(a, b))
  //   sub : r(add32(f(a), -f(b)))       max/min : bf16_max/min(a, b)
  //   macc: r(add32(mul(a, b), f(d)))   mv  : b (bit copy)
  logic [VLEN-1:0] va, vb, vd_old;

  assign va     = vreg[ar_vs2];
  assign vd_old = vreg[ar_vd];
  assign vb     = ar_vf ? {VLMAX{ar_scalar}} : vreg[ar_vs1];

  logic              s1_valid, s2_valid;
  logic              s1_use_add, s2_use_add;     // result comes from the adder
  logic [4:0]        s1_vd, s2_vd;
  logic [VLMAX-1:0]  s1_mask, s2_mask;           // lanes i < vl
  logic [31:0]       s1_x [VLMAX], s1_y [VLMAX]; // adder inputs
  logic [15:0]       s1_direct [VLMAX];          // result when no adder is used
  logic [15:0]       s2_direct [VLMAX];
  fp32_add_mid_t     s2_mid [VLMAX];
  logic [VLEN-1:0]   s3_result;

  logic use_add;
  assign use_add = (ar_op == VOP_ADD) || (ar_op == VOP_SUB) || (ar_op == VOP_MACC);

  for (genvar i = 0; i < VLMAX; i++) begin : g_lane
    logic [15:0] a, b, d;
    logic [31:0] x, y, fb;
    logic [15:0] direct;

    assign a  = va[16*i +: 16];
    assign b  = vb[16*i +: 16];
    assign d  = vd_old[16*i +: 16];
    assign fb = bf16_to_fp32(b);

    // stage 1: adder inputs, or the finished result
    always_comb begin
      x      = '0;
      y      = '0;
      direct = d;
      case (ar_op)
        VOP_ADD:  begin x = bf16_to_fp32(a);    y = fb;                    end
        VOP_SUB:  begin x = bf16_to_fp32(a);    y = {~fb[31], fb[30:0]};   end
        VOP_MACC: begin x = bf16_mul_fp32(a, b); y = bf16_to_fp32(d);      end
        VOP_MUL:  direct = fp32_to_bf16(bf16_mul_fp32(a, b));
        VOP_MAX:  direct = bf16_max(a, b);
        VOP_MIN:  direct = bf16_min(a, b);
        VOP_MV:   direct = b;                          // bit copy, no DAZ
        default:  ;
      endcase
    end

    always_ff @(posedge clk) begin
      if (ar_en) begin                                 // -> stage 1 registers
        s1_x[i]      <= x;
        s1_y[i]      <= y;
        s1_direct[i] <= direct;
      end
      if (s1_valid) begin                              // -> stage 2 registers
        s2_mid[i]    <= fp32_add_align(s1_x[i], s1_y[i]);
        s2_direct[i] <= s1_direct[i];
      end
    end

    // stage 3: finish and round, or pass the direct result through
    assign s3_result[16*i +: 16] = s2_use_add ? fp32_to_bf16(fp32_add_finish(s2_mid[i]))
                                              : s2_direct[i];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s2_valid <= 1'b0;
    end else begin
      s1_valid <= ar_en;
      s2_valid <= s1_valid;
    end
    if (ar_en) begin
      s1_use_add <= use_add;
      s1_vd      <= ar_vd;
      for (int i = 0; i < VLMAX; i++) s1_mask[i] <= (i < vl);
    end
    if (s1_valid) begin
      s2_use_add <= s1_use_add;
      s2_vd      <= s1_vd;
      s2_mask    <= s1_mask;
    end
  end

  assign ar_busy = s1_valid || s2_valid;

  //---------------------------------------------------------------------------
  // Reduction engine: one element per step, in order, two cycles per step
  //---------------------------------------------------------------------------
  //   start:   acc = f(init) (sum) / m = init (max); idx = 0
  //   phase 0: mid = align(acc, f(vs2[idx])); m = max(m, vs2[idx])
  //   phase 1: acc = finish(mid); idx++
  //   last element, phase 1: write vd[0] = r(acc) / m, raise red_done
  localparam int VL_W = $clog2(VLMAX) + 1;

  logic            red_busy, red_max_q, red_phase;
  logic [VL_W-1:0] red_idx;
  logic [4:0]      red_vd_q, red_vs2_q;
  logic [31:0]     red_acc;           // running fp32 sum
  fp32_add_mid_t   red_mid;           // the sum between its two halves
  logic [15:0]     red_m;             // running bf16 max
  logic [15:0]     red_init, red_elem, red_result;
  logic [31:0]     red_sum;
  logic            red_last;

  assign red_init   = red_vf ? red_scalar : vreg[red_vs1][15:0];
  assign red_elem   = vreg[red_vs2_q][16*red_idx +: 16];
  assign red_sum    = fp32_add_finish(red_mid);
  assign red_result = red_max_q ? red_m : fp32_to_bf16(red_sum);
  assign red_last   = red_busy && red_phase && (red_idx == vl - VL_W'(1));
  assign red_done   = red_last;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      red_busy <= 1'b0;
    end else if (red_start) begin
      red_busy  <= 1'b1;
      red_phase <= 1'b0;
      red_idx   <= '0;
      red_max_q <= red_max;
      red_vd_q  <= red_vd;
      red_vs2_q <= red_vs2;
      red_acc   <= bf16_to_fp32(red_init);
      red_m     <= red_init;
    end else if (red_busy) begin
      if (!red_phase) begin                     // phase 0: align, max
        red_mid   <= fp32_add_align(red_acc, bf16_to_fp32(red_elem));
        red_m     <= bf16_max(red_m, red_elem);
        red_phase <= 1'b1;
      end else begin                            // phase 1: finish, next element
        red_acc   <= red_sum;
        red_phase <= 1'b0;
        red_idx   <= red_idx + VL_W'(1);
        if (red_last) red_busy <= 1'b0;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Register file writes, lane by lane, only for lanes i < vl
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    for (int i = 0; i < VLMAX; i++) begin
      if (i < vl) begin
        if (ld_en) vreg[ld_vd][16*i +: 16] <= ld_data[16*i +: 16];
      end
      // element-wise result, stage 3 (lane mask captured at issue)
      if (s2_valid && s2_mask[i]) vreg[s2_vd][16*i +: 16] <= s3_result[16*i +: 16];
    end
    // lane 0 only
    if (sx_en && vl != '0) vreg[sx_vd][15:0]    <= sx_data;
    if (red_done)          vreg[red_vd_q][15:0] <= red_result;
  end

  assign rd_data = vreg[rd_idx];

endmodule : accel_vpu