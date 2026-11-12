//-----------------------------------------------------------------------------
// tb_top.sv
//-----------------------------------------------------------------------------
// System-level testbench:
//
//      +-----------------+   AXI4-Lite    +-------------+   AXI4    +-----------+
//      | host_bfm        |--------------->| accel_top   |---------->| hbm_model |
//      | (RV64G ISS/DPI) |<---- irq ------| (DUT)       |           | (DPI mem) |
//      +-----------------+                +-------------+           +-----------+
//              |  zero-time functional access to the same HBM storage   |
//              +--------------------------------------------------------+
//
// Hardware parameters are compile-time macros (set by sim/sim.mk):
//   +define+VLEN=.. MAT_DIM=.. NUM_TREGS=.. NUM_ACCS=.. MXU_ROWS=..
//           HBM_DATA_W=.. ICACHE_LINES=.. NUM_CORES=.. SPAD_KB=..
//           NUM_VPUS=.. NUM_MXUS=.. FP_PIPE=..
// Runtime plusargs are documented in docs/simulation.md. The test result is
// the host program's exit code: 0 prints "TEST PASSED", anything else
// (or a timeout / fatal error) prints "TEST FAILED".
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef VLEN
  `define VLEN 256
`endif
`ifndef MAT_DIM
  `define MAT_DIM 16
`endif
`ifndef NUM_TREGS
  `define NUM_TREGS 4
`endif
`ifndef NUM_ACCS
  `define NUM_ACCS 2
`endif
`ifndef MXU_ROWS
  `define MXU_ROWS 4
`endif
`ifndef HBM_DATA_W
  `define HBM_DATA_W 256
`endif
`ifndef ICACHE_LINES
  `define ICACHE_LINES 16
`endif
`ifndef NUM_CORES
  `define NUM_CORES 2
`endif
`ifndef SPAD_KB
  `define SPAD_KB 16
`endif
`ifndef NUM_VPUS
  `define NUM_VPUS `NUM_CORES
`endif
`ifndef NUM_MXUS
  `define NUM_MXUS `NUM_CORES
`endif
`ifndef FP_PIPE
  `define FP_PIPE 1
`endif

module tb_top;

  localparam int VLEN         = `VLEN;
  localparam int MAT_DIM      = `MAT_DIM;
  localparam int NUM_TREGS    = `NUM_TREGS;
  localparam int NUM_ACCS     = `NUM_ACCS;
  localparam int MXU_ROWS     = `MXU_ROWS;
  localparam int HBM_DATA_W   = `HBM_DATA_W;
  localparam int HBM_ADDR_W   = 32;
  localparam int HBM_ID_W     = 4;
  localparam int ICACHE_LINES = `ICACHE_LINES;
  localparam int NUM_CORES    = `NUM_CORES;
  localparam int SPAD_KB      = `SPAD_KB;
  localparam int NUM_VPUS     = `NUM_VPUS;
  localparam int NUM_MXUS     = `NUM_MXUS;
  localparam int FP_PIPE      = `FP_PIPE;

  //---------------------------------------------------------------------------
  // Clock / reset. One clock period is drawn as 1 ns, so waveform time in ns
  // equals the cycle number. What a cycle is worth in real time (for the host
  // CPU model and the link delay) is +clk_period_ns, see host_bfm.sv.
  //---------------------------------------------------------------------------
  logic   clk = 1'b0;
  logic   rst_n = 1'b0;
  longint cycle = 0;

  always #0.5 clk = ~clk;
  always @(posedge clk) cycle <= cycle + 1;

  //---------------------------------------------------------------------------
  // Wires
  //---------------------------------------------------------------------------
  logic [11:0] s_axil_awaddr, s_axil_araddr;
  logic        s_axil_awvalid, s_axil_awready, s_axil_wvalid, s_axil_wready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0]  s_axil_wstrb;
  logic [1:0]  s_axil_bresp, s_axil_rresp;
  logic        s_axil_bvalid, s_axil_bready, s_axil_arvalid, s_axil_arready;
  logic        s_axil_rvalid, s_axil_rready;
  logic        irq;

  logic [HBM_ID_W-1:0]     awid, bid, arid, rid;
  logic [HBM_ADDR_W-1:0]   awaddr, araddr;
  logic [7:0]              awlen, arlen;
  logic [2:0]              awsize, arsize;
  logic [1:0]              awburst, arburst, bresp, rresp;
  logic                    awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic                    arvalid, arready, rlast, rvalid, rready;
  logic [HBM_DATA_W-1:0]   wdata, rdata;
  logic [HBM_DATA_W/8-1:0] wstrb;

  logic host_done;
  int   host_exit;

  //---------------------------------------------------------------------------
  // DUT
  //---------------------------------------------------------------------------
  accel_top #(
    .VLEN (VLEN), .MAT_DIM (MAT_DIM), .NUM_TREGS (NUM_TREGS), .NUM_ACCS (NUM_ACCS),
    .MXU_ROWS (MXU_ROWS), .HBM_ADDR_W (HBM_ADDR_W), .HBM_DATA_W (HBM_DATA_W),
    .HBM_ID_W (HBM_ID_W), .ICACHE_LINES (ICACHE_LINES),
    .NUM_CORES (NUM_CORES), .NUM_VPUS (NUM_VPUS), .NUM_MXUS (NUM_MXUS),
    .FP_PIPE (FP_PIPE), .SPAD_KB (SPAD_KB)
  ) dut (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .irq,
    .m_axi_awid (awid), .m_axi_awaddr (awaddr), .m_axi_awlen (awlen), .m_axi_awsize (awsize),
    .m_axi_awburst (awburst), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
    .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast),
    .m_axi_wvalid (wvalid), .m_axi_wready (wready),
    .m_axi_bid (bid), .m_axi_bresp (bresp), .m_axi_bvalid (bvalid), .m_axi_bready (bready),
    .m_axi_arid (arid), .m_axi_araddr (araddr), .m_axi_arlen (arlen), .m_axi_arsize (arsize),
    .m_axi_arburst (arburst), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
    .m_axi_rid (rid), .m_axi_rdata (rdata), .m_axi_rresp (rresp), .m_axi_rlast (rlast),
    .m_axi_rvalid (rvalid), .m_axi_rready (rready)
  );

  //---------------------------------------------------------------------------
  // HBM model
  //---------------------------------------------------------------------------
  hbm_model #(.ADDR_W (HBM_ADDR_W), .DATA_W (HBM_DATA_W), .ID_W (HBM_ID_W)) u_hbm (
    .clk, .rst_n,
    .awid, .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bid, .bresp, .bvalid, .bready,
    .arid, .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
    .rid, .rdata, .rresp, .rlast, .rvalid, .rready
  );

  //---------------------------------------------------------------------------
  // Host CPU
  //---------------------------------------------------------------------------
  host_bfm u_host (
    .clk, .rst_n, .irq, .cycle,
    .awaddr (s_axil_awaddr), .awvalid (s_axil_awvalid), .awready (s_axil_awready),
    .wdata (s_axil_wdata), .wstrb (s_axil_wstrb), .wvalid (s_axil_wvalid), .wready (s_axil_wready),
    .bresp (s_axil_bresp), .bvalid (s_axil_bvalid), .bready (s_axil_bready),
    .araddr (s_axil_araddr), .arvalid (s_axil_arvalid), .arready (s_axil_arready),
    .rdata (s_axil_rdata), .rresp (s_axil_rresp), .rvalid (s_axil_rvalid), .rready (s_axil_rready),
    .done (host_done), .exit_code (host_exit)
  );

  //---------------------------------------------------------------------------
  // Run control: reset, waveforms, timeout, end of test
  //---------------------------------------------------------------------------
  longint timeout;

  initial begin
    if (!$value$plusargs("timeout=%d", timeout)) timeout = 50_000_000;
    $timeformat(-9, 0, "", 10);   // %t prints nanoseconds == cycles

    $display("[tb] config: VLEN=%0d MAT_DIM=%0d NUM_TREGS=%0d NUM_ACCS=%0d MXU_ROWS=%0d HBM_DATA_W=%0d ICACHE_LINES=%0d NUM_CORES=%0d NUM_VPUS=%0d NUM_MXUS=%0d FP_PIPE=%0d SPAD_KB=%0d%s",
             VLEN, MAT_DIM, NUM_TREGS, NUM_ACCS, MXU_ROWS, HBM_DATA_W, ICACHE_LINES, NUM_CORES,
             NUM_VPUS, NUM_MXUS, FP_PIPE, SPAD_KB,
`ifdef ACCEL_SRAM_MACROS
             " (SRAM macro models)");
`else
             "");
`endif

`ifdef WAVES
    $fsdbDumpfile("waves.fsdb");
    $fsdbDumpvars(0, tb_top, "+all");
`endif
    if ($test$plusargs("vcd")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, tb_top);
    end

    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n <= 1'b1;
  end

  always @(posedge clk) begin
    if (host_done) begin
      $display("[tb] host program exited with code %0d at cycle %0d", host_exit, cycle);
      if (host_exit == 0) $display("[tb] *** TEST PASSED ***");
      else                $display("[tb] *** TEST FAILED *** (exit code %0d)", host_exit);
      $finish;
    end
    if (cycle >= timeout) begin
      $display("[tb] *** TEST FAILED *** (timeout after %0d cycles; raise with +timeout=N)", cycle);
      $finish;
    end
  end

endmodule : tb_top
