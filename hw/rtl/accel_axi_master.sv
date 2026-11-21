//-----------------------------------------------------------------------------
// accel_axi_master.sv
//-----------------------------------------------------------------------------
// Turns simple memory requests from a core into AXI4 transactions on the HBM
// port.
//
// Core side ("request/response"):
//   The core asks for ONE bus beat (HBM_DATA_W bits) at a time:
//     req_valid/req_ready   handshake: the request is taken when both are 1
//     req_write             0 = read, 1 = write
//     req_addr              any byte address inside the beat; the low bits
//                           are dropped (the HBM model needs aligned beats)
//     req_wdata/req_wstrb   the whole beat and one strobe bit per byte;
//                           only bytes with strobe = 1 are written
//   One cycle-wide pulse comes back when the transaction has finished:
//     resp_valid            1 for exactly one cycle
//     resp_rdata            the beat that was read (reads only)
//     resp_err              AXI returned SLVERR/DECERR (bad address)
//
// Reads are pipelined: a new read is taken while earlier reads are still in
// flight (up to MAX_RD), and their responses come back in request order
// (one AXI ID, and AXI keeps responses with the same ID in order). This is
// what lets mld request all its rows before the first one returns.
// Writes are one at a time, and never overlap reads: a write is taken only
// when no read is in flight, and nothing is taken until its B response.
//
// AXI side: full bus width (SIZE = log2(bytes per beat)), INCR, ID = ID_VALUE.
// Writes are single beats. Reads are single beats, or a burst of req_len+1
// beats when the core loads a whole tile whose rows are back to back in HBM
// (one entry in the HBM's queue of outstanding requests instead of MAT_DIM).
//-----------------------------------------------------------------------------

module accel_axi_master
  import accel_pkg::*;
#(
  parameter int HBM_ADDR_W = 32,
  parameter int HBM_DATA_W = 256,
  parameter int HBM_ID_W   = 4,
  parameter int ID_VALUE   = 0
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- core side ----
  input  logic                    req_valid,
  output logic                    req_ready,
  input  logic                    req_write,
  input  logic [31:0]             req_addr,
  input  logic [HBM_DATA_W-1:0]   req_wdata,
  input  logic [HBM_DATA_W/8-1:0] req_wstrb,
  input  logic [7:0]              req_len,     // reads: burst of req_len+1 beats from req_addr
  output logic                    resp_valid,
  output logic [HBM_DATA_W-1:0]   resp_rdata,
  output logic                    resp_err,

  // ---- AXI4 master ----
  output logic [HBM_ID_W-1:0]     m_axi_awid,
  output logic [HBM_ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]              m_axi_awlen,
  output logic [2:0]              m_axi_awsize,
  output logic [1:0]              m_axi_awburst,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,
  output logic [HBM_DATA_W-1:0]   m_axi_wdata,
  output logic [HBM_DATA_W/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,
  input  logic [HBM_ID_W-1:0]     m_axi_bid,
  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,
  output logic [HBM_ID_W-1:0]     m_axi_arid,
  output logic [HBM_ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [HBM_ID_W-1:0]     m_axi_rid,
  input  logic [HBM_DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready
);

  localparam int BYTES = HBM_DATA_W / 8;        // bytes per beat
  localparam int OFF_W = $clog2(BYTES);         // address bits inside a beat

  //---------------------------------------------------------------------------
  // Reads: an AR slot + a count of reads in flight
  //---------------------------------------------------------------------------
  //   take a read  -> ar_pend (AR offered until accepted), rd_out + 1
  //   each R beat  -> one response pulse, rd_out - 1
  // A new read is taken only when the AR slot is empty, so at most one read
  // address is waiting for ARREADY (one read per 2 cycles at best).
  //
  // Writes: IDLE --> W (AW and W offered) --> B (wait for the response) --> IDLE
  localparam int MAX_RD = 32;                // beats in flight (a 16-beat tile burst + more)
  localparam int RC_W   = $clog2(MAX_RD + 1);

  typedef enum logic [1:0] {W_IDLE, W_W, W_B} wstate_e;
  wstate_e wstate;

  logic [31:0]             addr_q;      // beat-aligned address (AR or AW)
  logic [HBM_DATA_W-1:0]   wdata_q;
  logic [BYTES-1:0]        wstrb_q;
  logic                    aw_done, w_done;   // which write channels finished
  logic                    ar_pend;           // a read address waiting for ARREADY
  logic [RC_W-1:0]         rd_out;            // beats requested, not back yet
  logic [7:0]              arlen_q;           // burst length of the waiting AR
  logic [RC_W:0]           rd_room;           // rd_out + this request's beats

  logic rd_ok, wr_ok, take_rd, take_wr, ar_hs, r_hs;
  assign rd_room = (RC_W+1)'(rd_out) + (RC_W+1)'(req_len) + (RC_W+1)'(1);
  assign rd_ok   = (wstate == W_IDLE) && !ar_pend && (rd_room <= (RC_W+1)'(MAX_RD));
  assign wr_ok   = (wstate == W_IDLE) && !ar_pend && (rd_out == '0);
  assign req_ready = req_write ? wr_ok : rd_ok;
  assign take_rd = req_valid && !req_write && rd_ok;
  assign take_wr = req_valid &&  req_write && wr_ok;
  assign ar_hs   = ar_pend && m_axi_arready;
  assign r_hs    = m_axi_rvalid && (rd_out != '0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wstate     <= W_IDLE;
      addr_q     <= '0;
      wdata_q    <= '0;
      wstrb_q    <= '0;
      aw_done    <= 1'b0;
      w_done     <= 1'b0;
      ar_pend    <= 1'b0;
      arlen_q    <= '0;
      rd_out     <= '0;
      resp_valid <= 1'b0;
      resp_rdata <= '0;
      resp_err   <= 1'b0;
    end else begin
      resp_valid <= 1'b0;                      // a pulse unless set below

      // ---- take a request ----
      if (take_rd || take_wr) begin
        addr_q  <= {req_addr[31:OFF_W], {OFF_W{1'b0}}};
        wdata_q <= req_wdata;
        wstrb_q <= req_wstrb;
      end
      if (take_wr) begin
        aw_done <= 1'b0;
        w_done  <= 1'b0;
        wstate  <= W_W;
      end

      // ---- reads ----
      if (take_rd) begin
        ar_pend <= 1'b1;
        arlen_q <= req_len;
      end
      else if (ar_hs) ar_pend <= 1'b0;
      rd_out <= rd_out + (take_rd ? RC_W'(req_len) + RC_W'(1) : '0) - RC_W'(r_hs);
      if (r_hs) begin                           // one response pulse per beat
        resp_valid <= 1'b1;
        resp_rdata <= m_axi_rdata;
        resp_err   <= (m_axi_rresp != AXI_RESP_OKAY);
      end

      // ---- write: AW and W may be accepted in different cycles ----
      unique case (wstate)
        W_W: begin
          if (m_axi_awready) aw_done <= 1'b1;
          if (m_axi_wready)  w_done  <= 1'b1;
          if ((aw_done || m_axi_awready) && (w_done || m_axi_wready))
            wstate <= W_B;
        end
        W_B: begin
          if (m_axi_bvalid) begin
            resp_valid <= 1'b1;
            resp_err   <= (m_axi_bresp != AXI_RESP_OKAY);
            wstate     <= W_IDLE;
          end
        end
        default: ;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // AXI outputs
  //---------------------------------------------------------------------------
  localparam logic [2:0] SIZE = 3'(OFF_W);

  // Read address
  assign m_axi_arid    = HBM_ID_W'(ID_VALUE);
  assign m_axi_araddr  = HBM_ADDR_W'(addr_q);
  assign m_axi_arlen   = arlen_q;               // 1 beat, or an mld tile burst
  assign m_axi_arsize  = SIZE;
  assign m_axi_arburst = AXI_BURST_INCR;
  assign m_axi_arvalid = ar_pend;
  assign m_axi_rready  = (rd_out != '0);

  // Write address + data (both offered at once, each until accepted)
  assign m_axi_awid    = HBM_ID_W'(ID_VALUE);
  assign m_axi_awaddr  = HBM_ADDR_W'(addr_q);
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = SIZE;
  assign m_axi_awburst = AXI_BURST_INCR;
  assign m_axi_awvalid = (wstate == W_W) && !aw_done;
  assign m_axi_wdata   = wdata_q;
  assign m_axi_wstrb   = wstrb_q;
  assign m_axi_wlast   = 1'b1;                  // the only beat is the last
  assign m_axi_wvalid  = (wstate == W_W) && !w_done;
  assign m_axi_bready  = (wstate == W_B);

endmodule : accel_axi_master