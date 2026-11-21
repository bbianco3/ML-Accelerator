//-----------------------------------------------------------------------------
// accel_spad.sv
//-----------------------------------------------------------------------------
// One core's scratchpad and address router.
//
// Sits between the core and its accel_axi_master. Both sides use the same
// one-beat request/response interface (see accel_axi_master.sv), so neither
// the core nor the AXI master needs to know the scratchpad exists.
//
//   address 0x20xx_xxxx (SPAD_BASE window):
//       offset <  SPAD_KB KiB  -> the SRAM, answered in the next cycle
//       offset >= SPAD_KB KiB  -> bus error, answered in the next cycle
//   any other address          -> passed through to HBM (the AXI master)
//
// The SRAM word is one bus beat (HBM_DATA_W bits), so every access the core
// makes (a byte up to a whole vector or tile row) is one SRAM access. The
// byte strobes become the SRAM's per-bit write mask.
//
// A scratchpad request is answered in the next cycle, so the core may send
// one per cycle. The core never has scratchpad and HBM requests in flight at
// the same time (their responses could pass each other).
//-----------------------------------------------------------------------------

module accel_spad
  import accel_pkg::*;
#(
  parameter int HBM_DATA_W = 256,
  parameter int SPAD_KB    = 16
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- from the core ----
  input  logic                    req_valid,
  output logic                    req_ready,
  input  logic                    req_write,
  input  logic [31:0]             req_addr,
  input  logic [HBM_DATA_W-1:0]   req_wdata,
  input  logic [HBM_DATA_W/8-1:0] req_wstrb,
  input  logic [7:0]              req_len,     // read burst beats - 1 (HBM only)
  output logic                    resp_valid,
  output logic [HBM_DATA_W-1:0]   resp_rdata,
  output logic                    resp_err,

  // ---- to the AXI master (HBM) ----
  output logic                    hbm_req_valid,
  input  logic                    hbm_req_ready,
  output logic                    hbm_req_write,
  output logic [31:0]             hbm_req_addr,
  output logic [HBM_DATA_W-1:0]   hbm_req_wdata,
  output logic [HBM_DATA_W/8-1:0] hbm_req_wstrb,
  output logic [7:0]              hbm_req_len,
  input  logic                    hbm_resp_valid,
  input  logic [HBM_DATA_W-1:0]   hbm_resp_rdata,
  input  logic                    hbm_resp_err
);

  localparam int BYTES      = HBM_DATA_W / 8;
  localparam int OFF_W      = $clog2(BYTES);
  localparam int SPAD_BYTES = SPAD_KB * 1024;
  localparam int DEPTH      = (SPAD_BYTES > 0) ? SPAD_BYTES / BYTES : 1;
  localparam int AW         = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  //---------------------------------------------------------------------------
  // Decode the address
  //---------------------------------------------------------------------------
  logic        in_window;      // 0x20xx_xxxx
  logic        in_range;       // ... and inside the SRAM
  logic [23:0] offset;         // byte offset inside the window

  assign in_window = (req_addr[31:SPAD_WINDOW_W] == SPAD_BASE[31:SPAD_WINDOW_W]);
  assign offset    = req_addr[SPAD_WINDOW_W-1:0];
  assign in_range  = (SPAD_BYTES > 0) && (32'(offset) < SPAD_BYTES);

  //---------------------------------------------------------------------------
  // HBM path: pass straight through when the address is not ours
  //---------------------------------------------------------------------------
  assign hbm_req_valid = req_valid && !in_window;
  assign hbm_req_write = req_write;
  assign hbm_req_addr  = req_addr;
  assign hbm_req_wdata = req_wdata;
  assign hbm_req_len   = req_len;           // (the core never sends a burst here)
  assign hbm_req_wstrb = req_wstrb;

  // The scratchpad is always ready; HBM is ready when the AXI master is idle.
  assign req_ready = in_window ? 1'b1 : hbm_req_ready;

  //---------------------------------------------------------------------------
  // Scratchpad path
  //---------------------------------------------------------------------------
  logic spad_take;             // accept a scratchpad request this cycle
  logic spad_resp_q;           // ... so answer in the next cycle
  logic spad_err_q;            // ... with a bus error (out of range)

  assign spad_take = req_valid && in_window;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      spad_resp_q <= 1'b0;
      spad_err_q  <= 1'b0;
    end else begin
      spad_resp_q <= spad_take;
      spad_err_q  <= spad_take && !in_range;
    end
  end

  logic [HBM_DATA_W-1:0] sram_rdata;

  if (SPAD_BYTES > 0) begin : g_sram
    // byte strobes -> bit mask
    logic [HBM_DATA_W-1:0] wmask;
    for (genvar b = 0; b < BYTES; b++) begin : g_mask
      assign wmask[8*b +: 8] = {8{req_wstrb[b]}};
    end

    accel_sram_1rw #(.DEPTH(DEPTH), .WIDTH(HBM_DATA_W)) u_sram (
      .clk,
      .ce    (spad_take && in_range),
      .we    (req_write),
      .addr  (offset[OFF_W +: AW]),      // word address = byte offset / BYTES
      .wdata (req_wdata),
      .wmask (wmask),
      .rdata (sram_rdata)                // valid the cycle after a read
    );
  end else begin : g_no_sram
    assign sram_rdata = '0;
  end

  //---------------------------------------------------------------------------
  // Responses: at most one of the two paths answers in any cycle
  //---------------------------------------------------------------------------
  assign resp_valid = spad_resp_q || hbm_resp_valid;
  assign resp_rdata = spad_resp_q ? sram_rdata : hbm_resp_rdata;
  assign resp_err   = spad_resp_q ? spad_err_q : hbm_resp_err;

endmodule : accel_spad