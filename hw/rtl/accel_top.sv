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

  // Run status from the cores. No cores yet (milestone 1): never busy,
  // never finishes.
  logic             busy;
  logic             end_valid, end_error;
  logic [7:0]       end_cause, end_core;
  logic [31:0]      end_pc, end_insn;
  logic [63:0]      instret;

  assign busy      = 1'b0;
  assign end_valid = 1'b0;
  assign end_error = 1'b0;
  assign end_cause = ERR_NONE;
  assign end_core  = '0;
  assign end_pc    = '0;
  assign end_insn  = '0;
  assign instret   = '0;

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

  // HBM port: no requests.
  assign m_axi_awid    = '0;
  assign m_axi_awaddr  = '0;
  assign m_axi_awlen   = '0;
  assign m_axi_awsize  = '0;
  assign m_axi_awburst = 2'b01;   // INCR
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata   = '0;
  assign m_axi_wstrb   = '0;
  assign m_axi_wlast   = 1'b0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_bready  = 1'b0;
  assign m_axi_arid    = '0;
  assign m_axi_araddr  = '0;
  assign m_axi_arlen   = '0;
  assign m_axi_arsize  = '0;
  assign m_axi_arburst = 2'b01;   // INCR
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready  = 1'b0;

endmodule : accel_top