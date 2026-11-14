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
// Element-wise operations are done in one cycle here (combinational, i.e. the
// FP_PIPE = 0 datapath). Reductions process ONE element per cycle, strictly
// in order 0, 1, ..., vl-1: floating-point addition is not associative, and
// numerics.md fixes this order, so an adder tree would give different bits.
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
  input  logic                    ar_en,
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

  // One lane: a = vs2[i], b = op1[i], d = old vd[i] (for vfmacc).
  // Every case matches the C reference in sw/common/bf16.h bit for bit.
  function automatic logic [15:0] lane_op(input logic [6:0]  op,
                                          input logic [15:0] a,
                                          input logic [15:0] b,
                                          input logic [15:0] d);
    logic [31:0] fb;
    case (op)
      VOP_ADD:  return fp32_to_bf16(fp32_add(bf16_to_fp32(a), bf16_to_fp32(b)));
      VOP_SUB: begin
        fb = bf16_to_fp32(b);
        return fp32_to_bf16(fp32_add(bf16_to_fp32(a), {~fb[31], fb[30:0]}));
      end
      VOP_MUL:  return fp32_to_bf16(bf16_mul_fp32(a, b));
      VOP_MAX:  return bf16_max(a, b);
      VOP_MIN:  return bf16_min(a, b);
      VOP_MACC: return fp32_to_bf16(fp32_add(bf16_mul_fp32(a, b), bf16_to_fp32(d)));
      VOP_MV:   return b;                          // bit copy, no DAZ
      default:  return d;
    endcase
  endfunction

  //---------------------------------------------------------------------------
  // Datapath: VLMAX lanes side by side
  //---------------------------------------------------------------------------
  logic [VLEN-1:0] va, vb, vd_old, ar_result;

  assign va     = vreg[ar_vs2];
  assign vd_old = vreg[ar_vd];
  assign vb     = ar_vf ? {VLMAX{ar_scalar}} : vreg[ar_vs1];

  for (genvar i = 0; i < VLMAX; i++) begin : g_lane
    assign ar_result[16*i +: 16] = lane_op(ar_op, va[16*i +: 16], vb[16*i +: 16],
                                           vd_old[16*i +: 16]);
  end

  //---------------------------------------------------------------------------
  // Reduction engine: one element per cycle, in order
  //---------------------------------------------------------------------------
  //   start:      acc = f(init) (sum) / m = init (max); idx = 0
  //   each cycle: acc = add32(acc, f(vs2[idx])) / m = max(m, vs2[idx]); idx++
  //   idx = vl-1: write vd[0] = r(acc) / m, raise red_done
  localparam int VL_W = $clog2(VLMAX) + 1;

  logic            red_busy, red_max_q;
  logic [VL_W-1:0] red_idx;
  logic [4:0]      red_vd_q, red_vs2_q;
  logic [31:0]     red_acc;           // running fp32 sum
  logic [15:0]     red_m;             // running bf16 max
  logic [15:0]     red_init, red_elem, red_result;
  logic [31:0]     red_acc_next;
  logic [15:0]     red_m_next;
  logic            red_last;

  assign red_init     = red_vf ? red_scalar : vreg[red_vs1][15:0];
  assign red_elem     = vreg[red_vs2_q][16*red_idx +: 16];
  assign red_acc_next = fp32_add(red_acc, bf16_to_fp32(red_elem));
  assign red_m_next   = bf16_max(red_m, red_elem);
  assign red_result   = red_max_q ? red_m_next : fp32_to_bf16(red_acc_next);
  assign red_last     = red_busy && (red_idx == vl - VL_W'(1));
  assign red_done     = red_last;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      red_busy <= 1'b0;
    end else if (red_start) begin
      red_busy  <= 1'b1;
      red_idx   <= '0;
      red_max_q <= red_max;
      red_vd_q  <= red_vd;
      red_vs2_q <= red_vs2;
      red_acc   <= bf16_to_fp32(red_init);
      red_m     <= red_init;
    end else if (red_busy) begin
      red_acc <= red_acc_next;
      red_m   <= red_m_next;
      red_idx <= red_idx + VL_W'(1);
      if (red_last) red_busy <= 1'b0;
    end
  end

  //---------------------------------------------------------------------------
  // Register file writes, lane by lane, only for lanes i < vl
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    for (int i = 0; i < VLMAX; i++) begin
      if (i < vl) begin
        if (ar_en) vreg[ar_vd][16*i +: 16] <= ar_result[16*i +: 16];
        if (ld_en) vreg[ld_vd][16*i +: 16] <= ld_data[16*i +: 16];
      end
    end
    // lane 0 only
    if (sx_en && vl != '0) vreg[sx_vd][15:0]    <= sx_data;
    if (red_done)          vreg[red_vd_q][15:0] <= red_result;
  end

  assign rd_data = vreg[rd_idx];

endmodule : accel_vpu