//-----------------------------------------------------------------------------
// accel_vpu.sv
//-----------------------------------------------------------------------------
// Vector unit: the vector register file v0..v31 and VLMAX = VLEN/16 bf16
// lanes. The core decodes the instruction and drives this unit; the unit has
// no state machine of its own.
//
// Three ways in/out, all controlled by the core:
//   1. Arithmetic   ar_en: vd = op(vs2, op1) for every lane i < vl, written
//                   at the next clock edge. op1 is vs1 (.vv) or the scalar
//                   broadcast to every lane (.vf).
//   2. Load write   ld_en: vd = ld_data for every lane i < vl (vle16).
//   3. Read port    rd_idx -> rd_data, combinational (vse16 reads vs3).
//
// Lanes i >= vl are never written ("tail undisturbed").
//
// Element-wise operations are done in one cycle here (combinational, i.e. the
// FP_PIPE = 0 datapath). Reductions (vfredsum/vfredmax) and the x<->v moves
// are not implemented yet (milestone 4); the core rejects them as illegal.
//-----------------------------------------------------------------------------

module accel_vpu
  import accel_pkg::*;
  import accel_fp_pkg::*;
#(
  parameter int VLEN = 256
) (
  input  logic                    clk,

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
  output logic [VLEN-1:0]         rd_data
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
  // Register file writes, lane by lane, only for lanes i < vl
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    for (int i = 0; i < VLMAX; i++) begin
      if (i < vl) begin
        if (ar_en) vreg[ar_vd][16*i +: 16] <= ar_result[16*i +: 16];
        if (ld_en) vreg[ld_vd][16*i +: 16] <= ld_data[16*i +: 16];
      end
    end
  end

  assign rd_data = vreg[rd_idx];

endmodule : accel_vpu