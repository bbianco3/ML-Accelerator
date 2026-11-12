//-----------------------------------------------------------------------------
// host_bfm.sv
//-----------------------------------------------------------------------------
// Host CPU bus-functional model. Wraps the RV64G instruction-set simulator
// (sim/csrc/rv64_iss.c, via DPI-C) and turns its accesses to the accelerator
// CSR window into real AXI4-Lite transactions on the DUT's s_axil port.
//
// Timing model (see docs/host-model.md):
//   * Outside the region of interest the ISS retires up to +host_ipc=N
//     instructions per clock (default 1), with no time or energy accounting.
//   * Inside the region of interest (roi_begin()/roi_end()) the host is a
//     2 GHz core: every clock it gets +clk_period_ns of time, and every
//     instruction costs time and energy (sim/csrc/host_model.c).
//   * The host and the accelerator are connected by a link with a one-way
//     latency of +link_delay_ns (default 5 ns): a register access waits that
//     long before it reaches the accelerator and again before the response
//     reaches the host, and the irq line is delayed by the same amount.
//   * HBM accesses by the host cost what any host memory access costs
//     (cache model inside the region of interest, nothing outside).
//-----------------------------------------------------------------------------

module host_bfm (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        irq,
  input  longint      cycle,

  output logic [11:0] awaddr,
  output logic        awvalid,
  input  logic        awready,
  output logic [31:0] wdata,
  output logic [3:0]  wstrb,
  output logic        wvalid,
  input  logic        wready,
  input  logic [1:0]  bresp,
  input  logic        bvalid,
  output logic        bready,
  output logic [11:0] araddr,
  output logic        arvalid,
  input  logic        arready,
  input  logic [31:0] rdata,
  input  logic [1:0]  rresp,
  input  logic        rvalid,
  output logic        rready,

  output logic        done,
  output int          exit_code
);

  import "DPI-C" function int  host_init(input string elf_path, input int trace);
  import "DPI-C" function void host_config(input int accel_clk_ps);
  import "DPI-C" function int  host_step(input int max_instr, input int irq, input longint cycle);
  import "DPI-C" function void host_mmio_req(output int addr, output int wdata, output int is_write);
  import "DPI-C" function void host_mmio_resp(input int rdata, input int err);
  import "DPI-C" function int  host_exit_code();

  typedef enum {H_RUN, H_LINK_REQ, H_WRITE, H_BRESP, H_READ, H_RRESP, H_LINK_RESP, H_DONE} state_e;
  state_e state;

  int    ipc;
  string elf;
  int    st, maddr, mdata, mwrite;

  // Link latency in clock cycles (one way), and the delayed copy of irq.
  real   clk_period_ns, link_delay_ns;
  int    link_cycles, link_cnt, irq_cnt;
  int    resp_data, resp_err;
  logic  irq_host;

  initial begin
    if (!$value$plusargs("elf=%s", elf))
      $fatal(1, "host_bfm: no program given; run with +elf=<path/to/program.elf>");
    if (!$value$plusargs("host_ipc=%d", ipc)) ipc = 1;
    if (ipc < 1) ipc = 1;
    if (!$value$plusargs("clk_period_ns=%f", clk_period_ns)) clk_period_ns = 2.5;
    if (!$value$plusargs("link_delay_ns=%f", link_delay_ns)) link_delay_ns = 5.0;
    if (clk_period_ns <= 0.0 || link_delay_ns < 0.0)
      $fatal(1, "host_bfm: bad +clk_period_ns / +link_delay_ns");
    link_cycles = int'($ceil(link_delay_ns / clk_period_ns - 1e-9));
    host_config(int'(clk_period_ns * 1000.0));
    $display("[tb] accelerator clock %0.3f ns, host link delay %0.1f ns one way = %0d cycles",
             clk_period_ns, link_delay_ns, link_cycles);
    if (host_init(elf, int'($test$plusargs("host_trace"))) != 0)
      $fatal(1, "host_bfm: failed to load %s", elf);
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      state     <= H_RUN;
      awvalid   <= 1'b0;
      wvalid    <= 1'b0;
      bready    <= 1'b0;
      arvalid   <= 1'b0;
      rready    <= 1'b0;
      awaddr    <= '0;
      araddr    <= '0;
      wdata     <= '0;
      wstrb     <= 4'hF;
      done      <= 1'b0;
      exit_code <= 0;
      irq_host  <= 1'b0;
      irq_cnt   <= 0;
      link_cnt  <= 0;
    end else begin
      // irq as seen by the host: the level, link_cycles later
      if (irq == irq_host)              irq_cnt <= 0;
      else if (irq_cnt >= link_cycles) begin irq_host <= irq; irq_cnt <= 0; end
      else                              irq_cnt <= irq_cnt + 1;

      unique case (state)
        H_RUN: begin
          st = host_step(ipc, int'(irq_host), cycle);
          if (st == 1) begin
            host_mmio_req(maddr, mdata, mwrite);
            link_cnt <= link_cycles;
            state    <= H_LINK_REQ;
          end else if (st == 2 || st == 4) begin
            done      <= 1'b1;
            exit_code <= host_exit_code();
            state     <= H_DONE;
          end
        end

        // request travelling to the accelerator
        H_LINK_REQ: begin
          if (link_cnt > 0) link_cnt <= link_cnt - 1;
          else begin
            if (mwrite != 0) begin
              awaddr  <= maddr[11:0];
              wdata   <= mdata;
              wstrb   <= 4'hF;
              awvalid <= 1'b1;
              wvalid  <= 1'b1;
              state   <= H_WRITE;
            end else begin
              araddr  <= maddr[11:0];
              arvalid <= 1'b1;
              state   <= H_READ;
            end
          end
        end

        H_WRITE: begin
          // AW and W may complete in different cycles
          if (awvalid && awready) awvalid <= 1'b0;
          if (wvalid && wready)   wvalid  <= 1'b0;
          if ((!awvalid || awready) && (!wvalid || wready)) begin
            bready <= 1'b1;
            state  <= H_BRESP;
          end
        end

        H_BRESP: begin
          if (bvalid) begin
            bready    <= 1'b0;
            resp_data <= 0;
            resp_err  <= int'(bresp != 2'b00);
            link_cnt  <= link_cycles;
            state     <= H_LINK_RESP;
          end
        end

        H_READ: begin
          if (arready) begin
            arvalid <= 1'b0;
            rready  <= 1'b1;
            state   <= H_RRESP;
          end
        end

        H_RRESP: begin
          if (rvalid) begin
            rready    <= 1'b0;
            resp_data <= rdata;
            resp_err  <= int'(rresp != 2'b00);
            link_cnt  <= link_cycles;
            state     <= H_LINK_RESP;
          end
        end

        // response travelling back to the host
        H_LINK_RESP: begin
          if (link_cnt > 0) link_cnt <= link_cnt - 1;
          else begin
            host_mmio_resp(resp_data, resp_err);
            state <= H_RUN;
          end
        end

        H_DONE: ;
      endcase
    end
  end

endmodule : host_bfm
