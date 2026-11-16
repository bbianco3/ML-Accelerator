//-----------------------------------------------------------------------------
// accel_top.sv 
//-----------------------------------------------------------------------------
// Top level of the ML accelerator. THIS IS AN EMPTY SHELL: it has the ports
// the testbench and the synthesis flow expect and drives every output to its
// idle value. The accelerator itself is yours to design.
//
// As it stands every test fails with a timeout, because the host never gets
// an answer on the control port. A sensible first milestone is `make run
// TEST=hello`, which only needs the AXI4-Lite registers ID and CFG0..CFG3
// (docs/memory-map.md).
//
// What is fixed and what is not
//   * The module name, the ports below and their protocols are fixed: the
//     testbench (sim/tb) and the synthesis script (hw/synth) connect to them.
//   * The parameters are the knobs the Makefile passes down (`make help`).
//     Use them, ignore them or add your own (docs/parameters.md describes
//     what they mean in the reference architecture).
//   * Everything inside is free: add modules in this directory and list them
//     in filelist.f (compile order, packages first).
//
// External interfaces
//   clk, rst_n     single clock domain, synchronous active-low reset
//   s_axil_*       AXI4-Lite slave  -- host CPU control/status registers
//   irq            level interrupt to the host (done or error, if enabled)
//   m_axi_*        AXI4 master      -- HBM (or any memory) port, for
//                                      instruction fetch and all data traffic
//
// Memories: instantiate accel_sram_1rw #(.DEPTH, .WIDTH) for anything bigger
// than a few registers. The module is generated from the SRAM macro catalog
// (hw/sram/sram_gen.py --wrapper -> build/gen/accel_sram_1rw.sv) and is added
// to simulation and synthesis for you, so its area, timing and power are
// those of real SRAM macros (docs/sram.md).
//
// accel_pkg.sv holds the instruction encodings, register offsets and error
// codes that the software in sw/ uses; accel_fp_pkg.sv holds the bf16 / fp32
// arithmetic functions that match the software reference model (bf16.h).
//-----------------------------------------------------------------------------

module accel_top
  import accel_pkg::*;
#(
  parameter int VLEN         = 256,   // vector register width in bits
  parameter int MAT_DIM      = 16,    // matrix tile dimension
  parameter int NUM_TREGS    = 4,     // bf16 tile registers
  parameter int NUM_ACCS     = 2,     // fp32 accumulator registers
  parameter int MXU_ROWS     = 4,     // output rows computed per cycle
  parameter int HBM_ADDR_W   = 32,    // AXI address width
  parameter int HBM_DATA_W   = 256,   // AXI data width in bits
  parameter int HBM_ID_W     = 4,     // AXI ID width
  parameter int ICACHE_LINES = 16,    // instruction cache lines
  parameter int NUM_CORES    = 2,     // compute cores
  parameter int NUM_VPUS     = NUM_CORES,   // cores with a vector unit
  parameter int NUM_MXUS     = NUM_CORES,   // cores with a matrix unit
  parameter int FP_PIPE      = 1,     // pipeline stages in the FP datapaths
  parameter int SPAD_KB      = 16     // scratchpad KiB per core
) (
  input  logic                    clk,
  input  logic                    rst_n,

  //---------------- Host control port (AXI4-Lite slave) ----------------
  input  logic [11:0]             s_axil_awaddr,
  input  logic                    s_axil_awvalid,
  output logic                    s_axil_awready,
  input  logic [31:0]             s_axil_wdata,
  input  logic [3:0]              s_axil_wstrb,
  input  logic                    s_axil_wvalid,
  output logic                    s_axil_wready,
  output logic [1:0]              s_axil_bresp,
  output logic                    s_axil_bvalid,
  input  logic                    s_axil_bready,
  input  logic [11:0]             s_axil_araddr,
  input  logic                    s_axil_arvalid,
  output logic                    s_axil_arready,
  output logic [31:0]             s_axil_rdata,
  output logic [1:0]              s_axil_rresp,
  output logic                    s_axil_rvalid,
  input  logic                    s_axil_rready,

  output logic                    irq,

  //---------------- HBM port (AXI4 master) ----------------
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

  //---------------------------------------------------------------------------
  // Host control/status registers (AXI4-Lite slave)
  //---------------------------------------------------------------------------
  logic             start;
  logic [31:0]      start_pc;
  logic [7:0][31:0] args;
  logic [7:0]       cores;

  // Run status from the cores
  logic             busy;
  logic             end_valid, end_error;
  logic [7:0]       end_cause, end_core;
  logic [31:0]      end_pc, end_insn;
  logic [63:0]      instret;

  accel_csr #(
    .VLEN(VLEN), .MAT_DIM(MAT_DIM), .NUM_TREGS(NUM_TREGS), .NUM_ACCS(NUM_ACCS),
    .MXU_ROWS(MXU_ROWS), .HBM_DATA_W(HBM_DATA_W), .ICACHE_LINES(ICACHE_LINES),
    .NUM_CORES(NUM_CORES), .NUM_VPUS(NUM_VPUS), .NUM_MXUS(NUM_MXUS),
    .SPAD_KB(SPAD_KB)
  ) u_csr (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid,  .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid,  .s_axil_rready,
    .irq,
    .start_o(start), .start_pc_o(start_pc), .args_o(args), .cores_o(cores),
    .busy_i(busy),
    .end_valid_i(end_valid), .end_error_i(end_error), .end_cause_i(end_cause),
    .end_pc_i(end_pc), .end_insn_i(end_insn), .end_core_i(end_core),
    .instret_i(instret)
  );

  //===========================================================================
  // Compute cores: NUM_CORES x (core -> scratchpad router -> AXI master)
  //===========================================================================
  localparam int N = NUM_CORES;

  // Per-core run status
  logic [N-1:0]        c_busy, c_end_valid, c_end_error, c_at_barrier;
  logic [N-1:0][7:0]   c_end_cause;
  logic [N-1:0][31:0]  c_end_pc, c_end_insn;
  logic [N-1:0][63:0]  c_instret;
  logic                barrier_go, abort;

  // Per-core AXI masters, merged by the arbiter
  logic [N-1:0][HBM_ID_W-1:0]     a_awid, a_arid, a_bid, a_rid;
  logic [N-1:0][HBM_ADDR_W-1:0]   a_awaddr, a_araddr;
  logic [N-1:0][7:0]              a_awlen, a_arlen;
  logic [N-1:0][2:0]              a_awsize, a_arsize;
  logic [N-1:0][1:0]              a_awburst, a_arburst, a_bresp, a_rresp;
  logic [N-1:0]                   a_awvalid, a_awready, a_wlast, a_wvalid, a_wready;
  logic [N-1:0]                   a_bvalid, a_bready, a_arvalid, a_arready;
  logic [N-1:0]                   a_rlast, a_rvalid, a_rready;
  logic [N-1:0][HBM_DATA_W-1:0]   a_wdata, a_rdata;
  logic [N-1:0][HBM_DATA_W/8-1:0] a_wstrb;

  for (genvar i = 0; i < N; i++) begin : g_core
    // core <-> scratchpad router
    logic                    req_valid, req_ready, req_write;
    logic [31:0]             req_addr;
    logic [HBM_DATA_W-1:0]   req_wdata;
    logic [HBM_DATA_W/8-1:0] req_wstrb;
    logic                    resp_valid, resp_err;
    logic [HBM_DATA_W-1:0]   resp_rdata;
    // scratchpad router <-> AXI master
    logic                    h_req_valid, h_req_ready, h_req_write;
    logic [31:0]             h_req_addr;
    logic [HBM_DATA_W-1:0]   h_req_wdata;
    logic [HBM_DATA_W/8-1:0] h_req_wstrb;
    logic                    h_resp_valid, h_resp_err;
    logic [HBM_DATA_W-1:0]   h_resp_rdata;

    accel_core #(
      .CORE_ID(i), .VLEN(VLEN), .HBM_DATA_W(HBM_DATA_W),
      .NUM_VPUS(NUM_VPUS), .NUM_MXUS(NUM_MXUS),
      .MAT_DIM(MAT_DIM), .NUM_TREGS(NUM_TREGS), .NUM_ACCS(NUM_ACCS), .MXU_ROWS(MXU_ROWS),
      .SPAD_KB(SPAD_KB)
    ) u_core (
      .clk, .rst_n,
      .start, .start_pc, .args, .ncores(cores),
      .at_barrier (c_at_barrier[i]),
      .barrier_go,
      .abort,
      .busy      (c_busy[i]),
      .end_valid (c_end_valid[i]),
      .end_error (c_end_error[i]),
      .end_cause (c_end_cause[i]),
      .end_pc    (c_end_pc[i]),
      .end_insn  (c_end_insn[i]),
      .instret   (c_instret[i]),
      .mem_req_valid (req_valid),  .mem_req_ready (req_ready),
      .mem_req_write (req_write),  .mem_req_addr  (req_addr),
      .mem_req_wdata (req_wdata),  .mem_req_wstrb (req_wstrb),
      .mem_resp_valid(resp_valid), .mem_resp_rdata(resp_rdata),
      .mem_resp_err  (resp_err)
    );

    accel_spad #(.HBM_DATA_W(HBM_DATA_W), .SPAD_KB(SPAD_KB)) u_spad (
      .clk, .rst_n,
      .req_valid, .req_ready, .req_write, .req_addr, .req_wdata, .req_wstrb,
      .resp_valid, .resp_rdata, .resp_err,
      .hbm_req_valid (h_req_valid),  .hbm_req_ready (h_req_ready),
      .hbm_req_write (h_req_write),  .hbm_req_addr  (h_req_addr),
      .hbm_req_wdata (h_req_wdata),  .hbm_req_wstrb (h_req_wstrb),
      .hbm_resp_valid(h_resp_valid), .hbm_resp_rdata(h_resp_rdata),
      .hbm_resp_err  (h_resp_err)
    );

    accel_axi_master #(
      .HBM_ADDR_W(HBM_ADDR_W), .HBM_DATA_W(HBM_DATA_W), .HBM_ID_W(HBM_ID_W), .ID_VALUE(i)
    ) u_axi (
      .clk, .rst_n,
      .req_valid(h_req_valid), .req_ready(h_req_ready), .req_write(h_req_write),
      .req_addr(h_req_addr), .req_wdata(h_req_wdata), .req_wstrb(h_req_wstrb),
      .resp_valid(h_resp_valid), .resp_rdata(h_resp_rdata), .resp_err(h_resp_err),
      .m_axi_awid(a_awid[i]), .m_axi_awaddr(a_awaddr[i]), .m_axi_awlen(a_awlen[i]),
      .m_axi_awsize(a_awsize[i]), .m_axi_awburst(a_awburst[i]),
      .m_axi_awvalid(a_awvalid[i]), .m_axi_awready(a_awready[i]),
      .m_axi_wdata(a_wdata[i]), .m_axi_wstrb(a_wstrb[i]), .m_axi_wlast(a_wlast[i]),
      .m_axi_wvalid(a_wvalid[i]), .m_axi_wready(a_wready[i]),
      .m_axi_bid(a_bid[i]), .m_axi_bresp(a_bresp[i]), .m_axi_bvalid(a_bvalid[i]),
      .m_axi_bready(a_bready[i]),
      .m_axi_arid(a_arid[i]), .m_axi_araddr(a_araddr[i]), .m_axi_arlen(a_arlen[i]),
      .m_axi_arsize(a_arsize[i]), .m_axi_arburst(a_arburst[i]),
      .m_axi_arvalid(a_arvalid[i]), .m_axi_arready(a_arready[i]),
      .m_axi_rid(a_rid[i]), .m_axi_rdata(a_rdata[i]), .m_axi_rresp(a_rresp[i]),
      .m_axi_rlast(a_rlast[i]), .m_axi_rvalid(a_rvalid[i]), .m_axi_rready(a_rready[i])
    );
  end

  //===========================================================================
  // HBM port: round-robin arbiter, responses routed back by AXI ID
  //===========================================================================
  accel_axi_arbiter #(
    .N(N), .HBM_ADDR_W(HBM_ADDR_W), .HBM_DATA_W(HBM_DATA_W), .HBM_ID_W(HBM_ID_W)
  ) u_arb (
    .clk, .rst_n,
    .s_awid(a_awid), .s_awaddr(a_awaddr), .s_awlen(a_awlen), .s_awsize(a_awsize),
    .s_awburst(a_awburst), .s_awvalid(a_awvalid), .s_awready(a_awready),
    .s_wdata(a_wdata), .s_wstrb(a_wstrb), .s_wlast(a_wlast),
    .s_wvalid(a_wvalid), .s_wready(a_wready),
    .s_bid(a_bid), .s_bresp(a_bresp), .s_bvalid(a_bvalid), .s_bready(a_bready),
    .s_arid(a_arid), .s_araddr(a_araddr), .s_arlen(a_arlen), .s_arsize(a_arsize),
    .s_arburst(a_arburst), .s_arvalid(a_arvalid), .s_arready(a_arready),
    .s_rid(a_rid), .s_rdata(a_rdata), .s_rresp(a_rresp), .s_rlast(a_rlast),
    .s_rvalid(a_rvalid), .s_rready(a_rready),
    .m_awid(m_axi_awid), .m_awaddr(m_axi_awaddr), .m_awlen(m_axi_awlen),
    .m_awsize(m_axi_awsize), .m_awburst(m_axi_awburst),
    .m_awvalid(m_axi_awvalid), .m_awready(m_axi_awready),
    .m_wdata(m_axi_wdata), .m_wstrb(m_axi_wstrb), .m_wlast(m_axi_wlast),
    .m_wvalid(m_axi_wvalid), .m_wready(m_axi_wready),
    .m_bid(m_axi_bid), .m_bresp(m_axi_bresp), .m_bvalid(m_axi_bvalid),
    .m_bready(m_axi_bready),
    .m_arid(m_axi_arid), .m_araddr(m_axi_araddr), .m_arlen(m_axi_arlen),
    .m_arsize(m_axi_arsize), .m_arburst(m_axi_arburst),
    .m_arvalid(m_axi_arvalid), .m_arready(m_axi_arready),
    .m_rid(m_axi_rid), .m_rdata(m_axi_rdata), .m_rresp(m_axi_rresp),
    .m_rlast(m_axi_rlast), .m_rvalid(m_axi_rvalid), .m_rready(m_axi_rready)
  );

  //===========================================================================
  // Barrier
  //===========================================================================
  // Release when at least one core waits and EVERY core is either waiting or
  // not running. Cores that were not launched, or have finished, are idle, so
  // they count as arrived. All waiting cores see barrier_go in the same cycle
  // and leave together.
  assign barrier_go = (|c_at_barrier) && (&(c_at_barrier | ~c_busy));

  //===========================================================================
  // Run status: combine the cores for accel_csr
  //===========================================================================
  //   busy     : any core running
  //   end      : one pulse when the last running core stops
  //   error    : the FIRST core to fault (lowest index on a tie) is reported,
  //              and `abort` makes the other cores stop
  //   success  : ERR_PC/ERR_INSN report core 0's final ecall
  //   instret  : sum over all cores
  logic        run_q;                       // a run is in progress
  logic        err_q;                       // ... and a core has faulted
  logic [7:0]  err_cause_q, err_core_q;
  logic [31:0] err_pc_q, err_insn_q;
  logic [31:0] ok_pc_q, ok_insn_q;          // core 0's ecall

  // A fault reported in THIS cycle (lowest core index wins)
  logic        f_any;
  logic [7:0]  f_cause, f_core;
  logic [31:0] f_pc, f_insn;
  always_comb begin
    f_any = 1'b0; f_cause = ERR_NONE; f_core = '0; f_pc = '0; f_insn = '0;
    for (int i = N - 1; i >= 0; i--) begin
      if (c_end_valid[i] && c_end_error[i]) begin
        f_any   = 1'b1;
        f_cause = c_end_cause[i];
        f_core  = 8'(i);
        f_pc    = c_end_pc[i];
        f_insn  = c_end_insn[i];
      end
    end
  end

  logic ok0;                                // core 0 stopped without error now
  assign ok0 = c_end_valid[0] && !c_end_error[0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      run_q <= 1'b0;  err_q <= 1'b0;
      err_cause_q <= ERR_NONE; err_core_q <= '0; err_pc_q <= '0; err_insn_q <= '0;
      ok_pc_q <= '0; ok_insn_q <= '0;
    end else if (start) begin
      run_q <= 1'b1;
      err_q <= 1'b0;
    end else if (run_q) begin
      if (f_any && !err_q) begin
        err_q       <= 1'b1;
        err_cause_q <= f_cause;
        err_core_q  <= f_core;
        err_pc_q    <= f_pc;
        err_insn_q  <= f_insn;
      end
      if (ok0) begin
        ok_pc_q   <= c_end_pc[0];
        ok_insn_q <= c_end_insn[0];
      end
      if (!busy) run_q <= 1'b0;             // every core has stopped
    end
  end

  assign abort     = err_q;
  assign busy      = |c_busy;
  assign end_valid = run_q && !busy;
  assign end_error = err_q || f_any;
  assign end_cause = err_q ? err_cause_q : f_cause;
  assign end_core  = err_q ? err_core_q  : (f_any ? f_core : 8'd0);
  assign end_pc    = err_q ? err_pc_q    : (f_any ? f_pc   : (ok0 ? c_end_pc[0]   : ok_pc_q));
  assign end_insn  = err_q ? err_insn_q  : (f_any ? f_insn : (ok0 ? c_end_insn[0] : ok_insn_q));

  always_comb begin
    instret = '0;
    for (int i = 0; i < N; i++) instret += c_instret[i];
  end

endmodule : accel_top