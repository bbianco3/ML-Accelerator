//-----------------------------------------------------------------------------
// accel_csr.sv
//-----------------------------------------------------------------------------
// Host control/status registers behind the AXI4-Lite slave port
// (docs/memory-map.md, "Accelerator register map").
//
// Two halves:
//   1. AXI4-Lite slave protocol: accept one write (AW + W, in either order)
//      or one read (AR) at a time and answer with B or R.
//   2. The register file itself: ID/CFG constants, launch registers that the
//      host writes (START_PC, ARG0-7, CORES, IRQ_EN), and status that the
//      cores report back (BUSY, DONE, ERROR, error info, counters).
//
// Interface to the compute side ("cluster"):
//   start_o            1-cycle pulse: launch cores_o cores at start_pc_o
//   busy_i             at least one launched core is still running
//   end_valid_i        1-cycle pulse: the run ended (all cores stopped)
//   end_error_i        ... with an error (else success)
//   end_cause_i/pc/insn/core   error info, or core 0's final ecall PC
//   instret_i          instructions retired in this run, summed over cores
//-----------------------------------------------------------------------------

module accel_csr
  import accel_pkg::*;
#(
  parameter int VLEN         = 256,
  parameter int MAT_DIM      = 16,
  parameter int NUM_TREGS    = 4,
  parameter int NUM_ACCS     = 2,
  parameter int MXU_ROWS     = 4,
  parameter int HBM_DATA_W   = 256,
  parameter int ICACHE_LINES = 16,
  parameter int NUM_CORES    = 2,
  parameter int NUM_VPUS     = NUM_CORES,
  parameter int NUM_MXUS     = NUM_CORES,
  parameter int SPAD_KB      = 16
) (
  input  logic        clk,
  input  logic        rst_n,

  // AXI4-Lite slave
  input  logic [11:0] s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,     // ignored: whole-word registers
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [11:0] s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,

  output logic        irq,

  // Launch (to the cores)
  output logic        start_o,
  output logic [31:0] start_pc_o,
  output logic [7:0][31:0] args_o,
  output logic [7:0]  cores_o,

  // Run status (from the cores)
  input  logic        busy_i,
  input  logic        end_valid_i,
  input  logic        end_error_i,
  input  logic [7:0]  end_cause_i,
  input  logic [31:0] end_pc_i,
  input  logic [31:0] end_insn_i,
  input  logic [7:0]  end_core_i,
  input  logic [63:0] instret_i
);

  //===========================================================================
  // 1. AXI4-Lite write channel
  //===========================================================================
  // AW and W are independent channels: the master may present them in the
  // same cycle or in different cycles. Latch each one as it arrives, perform
  // the register write once both are held, then answer on B. Stop accepting
  // new AW/W until the B response has been taken (one write in flight).
  logic        aw_held, w_held;
  logic [11:0] aw_addr_q;
  logic [31:0] w_data_q;
  logic        wr_en;           // perform the register write this cycle
  logic [11:0] wr_addr;
  logic [31:0] wr_data;

  assign s_axil_awready = !aw_held && !s_axil_bvalid;
  assign s_axil_wready  = !w_held  && !s_axil_bvalid;
  assign s_axil_bresp   = AXI_RESP_OKAY;

  assign wr_en   = aw_held && w_held;
  assign wr_addr = aw_addr_q;
  assign wr_data = w_data_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_held       <= 1'b0;
      w_held        <= 1'b0;
      aw_addr_q     <= '0;
      w_data_q      <= '0;
      s_axil_bvalid <= 1'b0;
    end else begin
      if (s_axil_awvalid && s_axil_awready) begin
        aw_held   <= 1'b1;
        aw_addr_q <= s_axil_awaddr;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_held   <= 1'b1;
        w_data_q <= s_axil_wdata;
      end
      if (wr_en) begin                       // write happens, respond
        aw_held       <= 1'b0;
        w_held        <= 1'b0;
        s_axil_bvalid <= 1'b1;
      end
      if (s_axil_bvalid && s_axil_bready)
        s_axil_bvalid <= 1'b0;
    end
  end

  //===========================================================================
  // 2. Registers
  //===========================================================================
  logic        done_q, error_q, irq_en_q;
  logic [7:0]  cause_q, err_core_q, cores_q;
  logic [31:0] start_pc_q, err_pc_q, err_insn_q;
  logic [7:0][31:0] args_q;
  logic [63:0] cycles_q;

  // Writes to CTRL.START: launch unless already busy.
  logic start;
  assign start = wr_en && (wr_addr == CSR_CTRL) && wr_data[0] && !busy_i;

  // CORES writes are clamped to 1 .. NUM_CORES.
  function automatic logic [7:0] clamp_cores(input logic [31:0] v);
    if (v == 0)                return 8'd1;
    else if (v > NUM_CORES)    return 8'(NUM_CORES);
    else                       return v[7:0];
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      done_q     <= 1'b0;
      error_q    <= 1'b0;
      irq_en_q   <= 1'b0;
      cause_q    <= ERR_NONE;
      err_core_q <= '0;
      cores_q    <= 8'd1;
      start_pc_q <= '0;
      err_pc_q   <= '0;
      err_insn_q <= '0;
      cycles_q   <= '0;
      for (int i = 0; i < 8; i++) args_q[i] <= '0;
    end else begin
      // ---- host writes ----
      if (wr_en) begin
        unique case (wr_addr)
          CSR_STATUS: begin                         // write-1-to-clear
            if (wr_data[STATUS_DONE])  done_q  <= 1'b0;
            if (wr_data[STATUS_ERROR]) error_q <= 1'b0;
          end
          CSR_IRQ_EN:   irq_en_q   <= wr_data[0];
          CSR_START_PC: start_pc_q <= wr_data;
          CSR_CORES:    cores_q    <= clamp_cores(wr_data);
          default: begin
            // ARG0..ARG7 at 0x080..0x09C
            if (wr_addr[11:5] == CSR_ARG0[11:5])
              args_q[wr_addr[4:2]] <= wr_data;
          end
        endcase
      end

      // ---- launch: clear the previous run's results ----
      if (start) begin
        done_q   <= 1'b0;
        error_q  <= 1'b0;
        cause_q  <= ERR_NONE;
        cycles_q <= '0;
      end else if (busy_i) begin
        cycles_q <= cycles_q + 64'd1;
      end

      // ---- end of run, reported by the cores (wins over a W1C) ----
      if (end_valid_i) begin
        done_q     <= 1'b1;
        error_q    <= end_error_i;
        cause_q    <= end_error_i ? end_cause_i : ERR_NONE;
        err_pc_q   <= end_pc_i;
        err_insn_q <= end_insn_i;
        err_core_q <= end_core_i;
      end
    end
  end

  assign irq        = irq_en_q && (done_q || error_q);
  assign start_o    = start;
  assign start_pc_o = start_pc_q;
  assign args_o     = args_q;
  assign cores_o    = cores_q;

  //===========================================================================
  // 3. AXI4-Lite read channel
  //===========================================================================
  // One read at a time: accept AR when no R is pending, look the register up
  // in the same cycle and hold the value in rdata until the master takes it.
  logic [31:0] rd_val;

  always_comb begin
    rd_val = '0;                                    // unmapped reads return 0
    unique case (s_axil_araddr)
      CSR_ID:         rd_val = ACCEL_ID_VALUE;
      CSR_STATUS:     rd_val = {16'b0, cause_q, 5'b0, error_q, done_q, busy_i};
      CSR_IRQ_EN:     rd_val = {31'b0, irq_en_q};
      CSR_START_PC:   rd_val = start_pc_q;
      CSR_ERR_PC:     rd_val = err_pc_q;
      CSR_ERR_INSN:   rd_val = err_insn_q;
      CSR_CYCLES_LO:  rd_val = cycles_q[31:0];
      CSR_CYCLES_HI:  rd_val = cycles_q[63:32];
      CSR_INSTRET_LO: rd_val = instret_i[31:0];
      CSR_INSTRET_HI: rd_val = instret_i[63:32];
      CSR_CORES:      rd_val = {24'b0, cores_q};
      CSR_ERR_CORE:   rd_val = {24'b0, err_core_q};
      CSR_CFG0:       rd_val = 32'(VLEN);
      CSR_CFG1:       rd_val = {8'(MXU_ROWS), 8'(NUM_ACCS), 8'(NUM_TREGS), 8'(MAT_DIM)};
      CSR_CFG2:       rd_val = {16'(ICACHE_LINES), 16'(HBM_DATA_W)};
      CSR_CFG3:       rd_val = {16'(SPAD_KB), 4'(NUM_MXUS), 4'(NUM_VPUS), 8'(NUM_CORES)};
      default: begin
        if (s_axil_araddr[11:5] == CSR_ARG0[11:5])
          rd_val = args_q[s_axil_araddr[4:2]];
      end
    endcase
  end

  assign s_axil_arready = !s_axil_rvalid;
  assign s_axil_rresp   = AXI_RESP_OKAY;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_axil_rvalid <= 1'b0;
      s_axil_rdata  <= '0;
    end else begin
      if (s_axil_arvalid && s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
        s_axil_rdata  <= rd_val;
      end else if (s_axil_rvalid && s_axil_rready) begin
        s_axil_rvalid <= 1'b0;
      end
    end
  end

endmodule : accel_csr