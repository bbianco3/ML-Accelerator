//-----------------------------------------------------------------------------
// accel_axi_arbiter.sv
//-----------------------------------------------------------------------------
// Shares the single HBM AXI4 port between N masters (one per core).
//
// Every master uses its core index as its AXI ID, so the responses can be
// routed back without remembering anything:
//
//   AR      : round robin between the masters with arvalid = 1. Once a
//             master is picked, it keeps the channel until its AR handshake
//             (AXI forbids changing a request while valid is high).
//   R       : goes to the master whose index equals RID.
//   AW + W  : round robin as for AR, but the picked master keeps BOTH
//             channels until its AW and its (single) W beat are both done,
//             so write data can never be mixed up between masters.
//   B       : goes to the master whose index equals BID.
//
// Reads and writes are arbitrated independently, so one core can read while
// another writes. A master may have several reads in flight (its responses
// come back in order, all with its ID), but only one write.
//-----------------------------------------------------------------------------

module accel_axi_arbiter
  import accel_pkg::*;
#(
  parameter int N          = 2,
  parameter int HBM_ADDR_W = 32,
  parameter int HBM_DATA_W = 256,
  parameter int HBM_ID_W   = 4
) (
  input  logic                              clk,
  input  logic                              rst_n,

  // ---- from the N masters (index i = core i) ----
  input  logic [N-1:0][HBM_ID_W-1:0]        s_awid,
  input  logic [N-1:0][HBM_ADDR_W-1:0]      s_awaddr,
  input  logic [N-1:0][7:0]                 s_awlen,
  input  logic [N-1:0][2:0]                 s_awsize,
  input  logic [N-1:0][1:0]                 s_awburst,
  input  logic [N-1:0]                      s_awvalid,
  output logic [N-1:0]                      s_awready,
  input  logic [N-1:0][HBM_DATA_W-1:0]      s_wdata,
  input  logic [N-1:0][HBM_DATA_W/8-1:0]    s_wstrb,
  input  logic [N-1:0]                      s_wlast,
  input  logic [N-1:0]                      s_wvalid,
  output logic [N-1:0]                      s_wready,
  output logic [N-1:0][HBM_ID_W-1:0]        s_bid,
  output logic [N-1:0][1:0]                 s_bresp,
  output logic [N-1:0]                      s_bvalid,
  input  logic [N-1:0]                      s_bready,
  input  logic [N-1:0][HBM_ID_W-1:0]        s_arid,
  input  logic [N-1:0][HBM_ADDR_W-1:0]      s_araddr,
  input  logic [N-1:0][7:0]                 s_arlen,
  input  logic [N-1:0][2:0]                 s_arsize,
  input  logic [N-1:0][1:0]                 s_arburst,
  input  logic [N-1:0]                      s_arvalid,
  output logic [N-1:0]                      s_arready,
  output logic [N-1:0][HBM_ID_W-1:0]        s_rid,
  output logic [N-1:0][HBM_DATA_W-1:0]      s_rdata,
  output logic [N-1:0][1:0]                 s_rresp,
  output logic [N-1:0]                      s_rlast,
  output logic [N-1:0]                      s_rvalid,
  input  logic [N-1:0]                      s_rready,

  // ---- to HBM ----
  output logic [HBM_ID_W-1:0]               m_awid,
  output logic [HBM_ADDR_W-1:0]             m_awaddr,
  output logic [7:0]                        m_awlen,
  output logic [2:0]                        m_awsize,
  output logic [1:0]                        m_awburst,
  output logic                              m_awvalid,
  input  logic                              m_awready,
  output logic [HBM_DATA_W-1:0]             m_wdata,
  output logic [HBM_DATA_W/8-1:0]           m_wstrb,
  output logic                              m_wlast,
  output logic                              m_wvalid,
  input  logic                              m_wready,
  input  logic [HBM_ID_W-1:0]               m_bid,
  input  logic [1:0]                        m_bresp,
  input  logic                              m_bvalid,
  output logic                              m_bready,
  output logic [HBM_ID_W-1:0]               m_arid,
  output logic [HBM_ADDR_W-1:0]             m_araddr,
  output logic [7:0]                        m_arlen,
  output logic [2:0]                        m_arsize,
  output logic [1:0]                        m_arburst,
  output logic                              m_arvalid,
  input  logic                              m_arready,
  input  logic [HBM_ID_W-1:0]               m_rid,
  input  logic [HBM_DATA_W-1:0]             m_rdata,
  input  logic [1:0]                        m_rresp,
  input  logic                              m_rlast,
  input  logic                              m_rvalid,
  output logic                              m_rready
);

  localparam int IW = (N > 1) ? $clog2(N) : 1;     // width of a master index

  // Round robin: the first requester at or after `ptr`, wrapping around.
  function automatic logic [IW-1:0] rr_pick(input logic [N-1:0] req,
                                            input logic [IW-1:0] ptr);
    logic [IW-1:0] pick;
    pick = ptr;
    for (int k = N - 1; k >= 0; k--) begin          // k = 0 checked last, so it wins
      if (req[(int'(ptr) + k) % N]) pick = IW'((int'(ptr) + k) % N);
    end
    return pick;
  endfunction

  function automatic logic [IW-1:0] next_ptr(input logic [IW-1:0] i);
    return (int'(i) == N - 1) ? '0 : i + IW'(1);
  endfunction

  //===========================================================================
  // Read address channel
  //===========================================================================
  logic          ar_held;          // a master owns AR, waiting for arready
  logic [IW-1:0] ar_sel_q, ar_sel, ar_ptr;
  logic          ar_hs;

  assign ar_sel    = ar_held ? ar_sel_q : rr_pick(s_arvalid, ar_ptr);
  assign m_arvalid = s_arvalid[ar_sel];
  assign m_arid    = s_arid   [ar_sel];
  assign m_araddr  = s_araddr [ar_sel];
  assign m_arlen   = s_arlen  [ar_sel];
  assign m_arsize  = s_arsize [ar_sel];
  assign m_arburst = s_arburst[ar_sel];
  assign ar_hs     = m_arvalid && m_arready;

  always_comb begin
    s_arready = '0;
    s_arready[ar_sel] = m_arready;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ar_held  <= 1'b0;
      ar_sel_q <= '0;
      ar_ptr   <= '0;
    end else if (m_arvalid) begin
      if (ar_hs) begin
        ar_held <= 1'b0;
        ar_ptr  <= next_ptr(ar_sel);               // next time, start after it
      end else begin
        ar_held  <= 1'b1;                           // keep it until accepted
        ar_sel_q <= ar_sel;
      end
    end
  end

  //===========================================================================
  // Read data channel: route by RID
  //===========================================================================
  for (genvar i = 0; i < N; i++) begin : g_r
    assign s_rid[i]    = m_rid;
    assign s_rdata[i]  = m_rdata;
    assign s_rresp[i]  = m_rresp;
    assign s_rlast[i]  = m_rlast;
    assign s_rvalid[i] = m_rvalid && (int'(m_rid) == i);
  end
  assign m_rready = (int'(m_rid) < N) ? s_rready[IW'(m_rid)] : 1'b1;

  //===========================================================================
  // Write address + data: one master owns both until both are done
  //===========================================================================
  logic          wr_held;
  logic [IW-1:0] wr_sel_q, wr_sel, wr_ptr;
  logic          aw_done_q, w_done_q;              // finished parts of the write
  logic          wr_any, aw_hs, w_hs, aw_fin, w_fin;

  assign wr_sel = wr_held ? wr_sel_q : rr_pick(s_awvalid, wr_ptr);
  assign wr_any = wr_held || (|s_awvalid);

  assign m_awvalid = wr_any && s_awvalid[wr_sel] && !aw_done_q;
  assign m_awid    = s_awid   [wr_sel];
  assign m_awaddr  = s_awaddr [wr_sel];
  assign m_awlen   = s_awlen  [wr_sel];
  assign m_awsize  = s_awsize [wr_sel];
  assign m_awburst = s_awburst[wr_sel];

  assign m_wvalid  = wr_any && s_wvalid[wr_sel] && !w_done_q;
  assign m_wdata   = s_wdata[wr_sel];
  assign m_wstrb   = s_wstrb[wr_sel];
  assign m_wlast   = s_wlast[wr_sel];

  assign aw_hs  = m_awvalid && m_awready;
  assign w_hs   = m_wvalid  && m_wready;
  assign aw_fin = aw_done_q || aw_hs;
  assign w_fin  = w_done_q  || w_hs;

  always_comb begin
    s_awready = '0;
    s_wready  = '0;
    if (wr_any) begin
      s_awready[wr_sel] = m_awready && !aw_done_q;
      s_wready [wr_sel] = m_wready  && !w_done_q;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_held   <= 1'b0;
      wr_sel_q  <= '0;
      wr_ptr    <= '0;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
    end else if (wr_any) begin
      if (aw_fin && w_fin) begin                   // both parts sent: release
        wr_held   <= 1'b0;
        aw_done_q <= 1'b0;
        w_done_q  <= 1'b0;
        wr_ptr    <= next_ptr(wr_sel);
      end else begin
        wr_held   <= 1'b1;
        wr_sel_q  <= wr_sel;
        aw_done_q <= aw_fin;
        w_done_q  <= w_fin;
      end
    end
  end

  //===========================================================================
  // Write response channel: route by BID
  //===========================================================================
  for (genvar i = 0; i < N; i++) begin : g_b
    assign s_bid[i]    = m_bid;
    assign s_bresp[i]  = m_bresp;
    assign s_bvalid[i] = m_bvalid && (int'(m_bid) == i);
  end
  assign m_bready = (int'(m_bid) < N) ? s_bready[IW'(m_bid)] : 1'b1;

endmodule : accel_axi_arbiter