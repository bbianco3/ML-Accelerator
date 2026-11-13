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
// Only one request is in flight at a time: req_ready is 0 from the moment a
// request is taken until its response pulse. The core waits for the pulse
// before it sends the next request, so no queueing is needed.
//
// AXI side: every transaction is a single beat (LEN = 0), full bus width
// (SIZE = log2(bytes per beat)), INCR burst, ID = ID_VALUE.
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
  // State machine
  //---------------------------------------------------------------------------
  //   IDLE --read--> AR  --(AR handshake)--> R --(R beat)-->  IDLE + resp pulse
  //   IDLE --write-> W   --(AW and W done)--> B --(B resp)--> IDLE + resp pulse
  typedef enum logic [2:0] {S_IDLE, S_AR, S_R, S_W, S_B} state_e;
  state_e state;

  logic [31:0]             addr_q;      // beat-aligned address
  logic [HBM_DATA_W-1:0]   wdata_q;
  logic [BYTES-1:0]        wstrb_q;
  logic                    aw_done, w_done;   // which write channels finished

  assign req_ready = (state == S_IDLE);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      addr_q     <= '0;
      wdata_q    <= '0;
      wstrb_q    <= '0;
      aw_done    <= 1'b0;
      w_done     <= 1'b0;
      resp_valid <= 1'b0;
      resp_rdata <= '0;
      resp_err   <= 1'b0;
    end else begin
      resp_valid <= 1'b0;                      // a pulse unless set below

      unique case (state)
        S_IDLE: begin
          if (req_valid) begin
            addr_q  <= {req_addr[31:OFF_W], {OFF_W{1'b0}}};
            wdata_q <= req_wdata;
            wstrb_q <= req_wstrb;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            state   <= req_write ? S_W : S_AR;
          end
        end

        // ---- read ----
        S_AR: if (m_axi_arready) state <= S_R;

        S_R: begin
          if (m_axi_rvalid) begin               // single beat, so this is RLAST
            resp_valid <= 1'b1;
            resp_rdata <= m_axi_rdata;
            resp_err   <= (m_axi_rresp != AXI_RESP_OKAY);
            state      <= S_IDLE;
          end
        end

        // ---- write: AW and W may be accepted in different cycles ----
        S_W: begin
          if (m_axi_awready) aw_done <= 1'b1;
          if (m_axi_wready)  w_done  <= 1'b1;
          if ((aw_done || m_axi_awready) && (w_done || m_axi_wready))
            state <= S_B;
        end

        S_B: begin
          if (m_axi_bvalid) begin
            resp_valid <= 1'b1;
            resp_err   <= (m_axi_bresp != AXI_RESP_OKAY);
            state      <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
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
  assign m_axi_arlen   = 8'd0;                  // 1 beat
  assign m_axi_arsize  = SIZE;
  assign m_axi_arburst = AXI_BURST_INCR;
  assign m_axi_arvalid = (state == S_AR);
  assign m_axi_rready  = (state == S_R);

  // Write address + data (both offered at once, each until accepted)
  assign m_axi_awid    = HBM_ID_W'(ID_VALUE);
  assign m_axi_awaddr  = HBM_ADDR_W'(addr_q);
  assign m_axi_awlen   = 8'd0;
  assign m_axi_awsize  = SIZE;
  assign m_axi_awburst = AXI_BURST_INCR;
  assign m_axi_awvalid = (state == S_W) && !aw_done;
  assign m_axi_wdata   = wdata_q;
  assign m_axi_wstrb   = wstrb_q;
  assign m_axi_wlast   = 1'b1;                  // the only beat is the last
  assign m_axi_wvalid  = (state == S_W) && !w_done;
  assign m_axi_bready  = (state == S_B);

endmodule : accel_axi_master