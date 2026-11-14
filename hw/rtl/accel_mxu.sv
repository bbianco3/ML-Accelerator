//-----------------------------------------------------------------------------
// accel_mxu.sv
//-----------------------------------------------------------------------------
// Matrix unit: NUM_TREGS tile registers (MAT_DIM x MAT_DIM bf16),
// NUM_ACCS accumulators (MAT_DIM x MAT_DIM fp32) and an array of
// MXU_ROWS x MAT_DIM multiply-accumulate (MAC) units.
//
// The core decodes the instruction and drives this unit; it has no memory
// access of its own. The core moves tiles one ROW at a time:
//
//   1. Row write   wr_en: tile wr_tr, row wr_row  <- wr_data          (mld)
//                  wr_col = 1: the data goes into COLUMN wr_row instead (mld.t)
//   2. Row read    rd_* -> rd_data, combinational                     (mst, msta)
//                  rd_acc = 1 reads an accumulator, rounded to bf16 (msta)
//                  rd_col = 1 reads COLUMN rd_row instead (.t forms)
//   3. Compute     cmd_zero:  acc[cmd_acc] = 0, done in that cycle    (mzero)
//                  cmd_macc:  acc[cmd_acc] += tile[cmd_ta] x tile[cmd_tb]
//                             busy for MAT_DIM*MAT_DIM/MXU_ROWS cycles (mmacc)
//
// mmacc schedule. One output element is
//     acc[i][j] = add32(...add32(add32(acc[i][j], a[i][0]*b[0][j]), a[i][1]*b[1][j])...)
// i.e. k must go 0, 1, ..., MAT_DIM-1 in order (numerics.md). The array
// updates MXU_ROWS rows x MAT_DIM columns per cycle:
//     for k = 0 .. MAT_DIM-1:                    (step_k)
//       for g = 0 .. MAT_DIM/MXU_ROWS-1:         (step_g, row group)
//         rows i = g*MXU_ROWS .. g*MXU_ROWS+MXU_ROWS-1, all columns j:
//           acc[i][j] = add32(acc[i][j], mul(a[i][k], b[k][j]))
// Every element still sees k in ascending order, so MXU_ROWS changes the
// speed and the area but never the result.
//-----------------------------------------------------------------------------

module accel_mxu
  import accel_pkg::*;
  import accel_fp_pkg::*;
#(
  parameter int MAT_DIM   = 16,
  parameter int NUM_TREGS = 4,
  parameter int NUM_ACCS  = 2,
  parameter int MXU_ROWS  = 4
) (
  input  logic                   clk,
  input  logic                   rst_n,

  // 1. row write (mld)
  input  logic                   wr_en,
  input  logic [1:0]             wr_tr,
  input  logic [$clog2(MAT_DIM)-1:0] wr_row,
  input  logic                   wr_col,
  input  logic [MAT_DIM*16-1:0]  wr_data,

  // 2. row read (mst / msta)
  input  logic                   rd_acc,      // 0: tile register, 1: accumulator
  input  logic [1:0]             rd_idx,
  input  logic [$clog2(MAT_DIM)-1:0] rd_row,
  input  logic                   rd_col,
  output logic [MAT_DIM*16-1:0]  rd_data,

  // 3. compute (mzero / mmacc)
  input  logic                   cmd_zero,    // 1-cycle pulse
  input  logic                   cmd_macc,    // 1-cycle pulse
  input  logic [1:0]             cmd_acc,
  input  logic [1:0]             cmd_ta,
  input  logic [1:0]             cmd_tb,
  output logic                   busy         // mmacc still running
);

  localparam int D      = MAT_DIM;
  localparam int ROW_W  = D * 16;            // one bf16 tile row
  localparam int AROW_W = D * 32;            // one fp32 accumulator row
  localparam int GROUPS = D / MXU_ROWS;      // row groups per k step
  localparam int IDX_W  = $clog2(D);
  localparam int G_W    = (GROUPS > 1) ? $clog2(GROUPS) : 1;

  // synopsys translate_off
  initial begin
    if (D % MXU_ROWS != 0)
      $fatal(1, "accel_mxu: MAT_DIM (%0d) must be a multiple of MXU_ROWS (%0d)", D, MXU_ROWS);
    if (NUM_TREGS > 4 || NUM_ACCS > 4)
      $fatal(1, "accel_mxu: register index ports are 2 bits wide");
  end
  // synopsys translate_on

  // Storage: one packed vector per row. Element j of a row is [16j +: 16]
  // (tiles) or [32j +: 32] (accumulators), the same order as in memory.
  logic [ROW_W-1:0]  treg [NUM_TREGS][D];
  logic [AROW_W-1:0] areg [NUM_ACCS][D];

  //===========================================================================
  // 2. Row read (combinational)
  //===========================================================================
  logic [15:0] e;                          // element j of the row/column read

  always_comb begin
    rd_data = '0;
    e       = '0;
    for (int j = 0; j < D; j++) begin
      if (rd_acc) begin
        if (rd_col) e = fp32_to_bf16(areg[rd_idx][j][32*rd_row +: 32]);
        else        e = fp32_to_bf16(areg[rd_idx][rd_row][32*j +: 32]);
      end else begin
        if (rd_col) e = treg[rd_idx][j][16*rd_row +: 16];
        else        e = treg[rd_idx][rd_row][16*j +: 16];
      end
      rd_data[16*j +: 16] = e;
    end
  end

  //===========================================================================
  // 3. mmacc sequencer: which k and which row group this cycle
  //===========================================================================
  logic [IDX_W-1:0] step_k;
  logic [G_W-1:0]   step_g;
  logic [1:0]       acc_q, ta_q, tb_q;
  logic             last_step;

  assign last_step = (step_k == IDX_W'(D - 1)) && (step_g == G_W'(GROUPS - 1));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy   <= 1'b0;
      step_k <= '0;
      step_g <= '0;
      acc_q  <= '0;
      ta_q   <= '0;
      tb_q   <= '0;
    end else if (cmd_macc) begin
      busy   <= 1'b1;
      step_k <= '0;
      step_g <= '0;
      acc_q  <= cmd_acc;
      ta_q   <= cmd_ta;
      tb_q   <= cmd_tb;
    end else if (busy) begin
      if (last_step) busy <= 1'b0;
      if (step_g == G_W'(GROUPS - 1)) begin
        step_g <= '0;
        step_k <= step_k + IDX_W'(1);
      end else begin
        step_g <= step_g + G_W'(1);
      end
    end
  end

  //===========================================================================
  // The MAC array: MXU_ROWS x MAT_DIM MACs, all in the same cycle
  //===========================================================================
  //   row i = step_g*MXU_ROWS + r,   column j,   k = step_k
  //   acc[i][j] <- add32(acc[i][j], mul(a[i][k], b[k][j]))
  logic [ROW_W-1:0]  b_row;                   // row k of tile b, shared by all MACs
  logic [AROW_W-1:0] mac_out [MXU_ROWS];      // new values for the MXU_ROWS rows

  assign b_row = treg[tb_q][step_k];

  for (genvar r = 0; r < MXU_ROWS; r++) begin : g_mac_row
    logic [IDX_W-1:0]  i;
    logic [15:0]       a_ik;
    logic [AROW_W-1:0] acc_row;

    assign i       = IDX_W'(step_g * MXU_ROWS + r);
    assign a_ik    = treg[ta_q][i][16*step_k +: 16];
    assign acc_row = areg[acc_q][i];

    for (genvar j = 0; j < D; j++) begin : g_mac
      assign mac_out[r][32*j +: 32] =
        fp32_add(acc_row[32*j +: 32], bf16_mul_fp32(a_ik, b_row[16*j +: 16]));
    end
  end

  //===========================================================================
  // Register writes
  //===========================================================================
  always_ff @(posedge clk) begin
    // 1. mld / mld.t: one row (or column) of a tile register
    if (wr_en) begin
      if (wr_col) begin
        for (int i = 0; i < D; i++)
          treg[wr_tr][i][16*wr_row +: 16] <= wr_data[16*i +: 16];
      end else begin
        treg[wr_tr][wr_row] <= wr_data;
      end
    end

    // 3. mzero
    if (cmd_zero) begin
      for (int i = 0; i < D; i++) areg[cmd_acc][i] <= '0;
    end

    // 3. mmacc: MXU_ROWS accumulator rows per cycle
    if (busy) begin
      for (int r = 0; r < MXU_ROWS; r++)
        areg[acc_q][step_g * MXU_ROWS + r] <= mac_out[r];
    end
  end

endmodule : accel_mxu