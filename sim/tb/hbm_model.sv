//-----------------------------------------------------------------------------
// hbm_model.sv
//-----------------------------------------------------------------------------
// Behavioral AXI4 slave standing in for an HBM pseudo-channel. Storage lives
// in C (sim/csrc/platform.c) so the host ISS sees the same bytes.
//
// Timing model (runtime plusargs, see docs/simulation.md):
//   +hbm_rd_latency_ns=T  time from AR handshake to the first R beat (100 ns)
//   +hbm_wr_latency_ns=T  time from the last W beat to the B response (50 ns)
//                         Both are converted to cycles with +clk_period_ns
//                         (2.5 ns: 40 and 20 cycles), rounding up, so memory
//                         does not get faster when the accelerator clock does.
//   +hbm_rd_latency=N     the same in cycles; overrides the _ns form
//   +hbm_wr_latency=N
//   +hbm_max_outstanding=N  read/write requests accepted before back-pressure (8)
//   +hbm_stall_pct=P    probability (0-100) of de-asserting a ready/valid in
//                       any cycle -- random back-pressure for robustness (0)
//   +hbm_trace          print every AXI transaction
// Bandwidth: at most one DATA_W-bit beat per cycle on each of R and W.
//
// Checks: only INCR bursts with full-width AxSIZE are supported; bursts that
// cross a 4 KiB boundary are flagged. Accesses outside the HBM window return
// DECERR.
//-----------------------------------------------------------------------------

module hbm_model #(
  parameter int ADDR_W = 32,
  parameter int DATA_W = 256,
  parameter int ID_W   = 4
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic [ID_W-1:0]   awid,
  input  logic [ADDR_W-1:0] awaddr,
  input  logic [7:0]        awlen,
  input  logic [2:0]        awsize,
  input  logic [1:0]        awburst,
  input  logic              awvalid,
  output logic              awready,
  input  logic [DATA_W-1:0] wdata,
  input  logic [DATA_W/8-1:0] wstrb,
  input  logic              wlast,
  input  logic              wvalid,
  output logic              wready,
  output logic [ID_W-1:0]   bid,
  output logic [1:0]        bresp,
  output logic              bvalid,
  input  logic              bready,
  input  logic [ID_W-1:0]   arid,
  input  logic [ADDR_W-1:0] araddr,
  input  logic [7:0]        arlen,
  input  logic [2:0]        arsize,
  input  logic [1:0]        arburst,
  input  logic              arvalid,
  output logic              arready,
  output logic [ID_W-1:0]   rid,
  output logic [DATA_W-1:0] rdata,
  output logic [1:0]        rresp,
  output logic              rlast,
  output logic              rvalid,
  input  logic              rready
);

  import "DPI-C" function int  hbm_addr_ok(input int addr, input int bytes);
  import "DPI-C" function int  hbm_read32(input int addr);
  import "DPI-C" function void hbm_write32(input int addr, input int data, input int strb);

  localparam int BYTES = DATA_W / 8;
  localparam int WORDS = DATA_W / 32;

  typedef struct {
    logic [ID_W-1:0]   id;
    logic [ADDR_W-1:0] addr;
    int                len;      // beats - 1
    logic [1:0]        resp;
    longint            ready_at;
  } txn_t;

  txn_t   rq[$];      // accepted reads
  txn_t   wq[$];      // accepted writes waiting for data
  txn_t   bq[$];      // writes waiting to send B
  int     rbeat, wbeat;
  longint now;

  int  rd_lat, wr_lat, max_out, stall_pct;
  real clk_ns, rd_ns, wr_ns;
  bit trace;

  // statistics
  longint n_rd_txn, n_wr_txn, n_rd_beats, n_wr_beats, first_cycle, last_cycle;

  initial begin
    if (!$value$plusargs("clk_period_ns=%f", clk_ns) || clk_ns <= 0.0) clk_ns = 2.5;
    if (!$value$plusargs("hbm_rd_latency_ns=%f", rd_ns))     rd_ns     = 100.0;
    if (!$value$plusargs("hbm_wr_latency_ns=%f", wr_ns))     wr_ns     = 50.0;
    if (!$value$plusargs("hbm_rd_latency=%d", rd_lat))       rd_lat    = int'($ceil(rd_ns / clk_ns - 1e-9));
    if (!$value$plusargs("hbm_wr_latency=%d", wr_lat))       wr_lat    = int'($ceil(wr_ns / clk_ns - 1e-9));
    $display("[hbm] latency: read %0d cycles, write %0d cycles (clock %0.3f ns)", rd_lat, wr_lat, clk_ns);
    if (!$value$plusargs("hbm_max_outstanding=%d", max_out)) max_out   = 8;
    if (!$value$plusargs("hbm_stall_pct=%d", stall_pct))     stall_pct = 0;
    trace = $test$plusargs("hbm_trace");
    if (DATA_W < 32 || (DATA_W % 32) != 0) $fatal(1, "hbm_model: DATA_W must be a multiple of 32");
  end

  function automatic bit stall();
    return (stall_pct > 0) && (($urandom % 100) < stall_pct);
  endfunction

  function automatic logic [1:0] check_req(string kind, logic [ADDR_W-1:0] addr, int len,
                                           logic [2:0] size, logic [1:0] burst);
    int bytes = (len + 1) * BYTES;
    if (burst != 2'b01) begin
      $error("hbm_model: %s burst type %0d not supported (INCR only)", kind, burst);
      return 2'b10;
    end
    if (int'(size) != $clog2(BYTES)) begin
      $error("hbm_model: %s AxSIZE=%0d but bus is %0d bytes wide", kind, size, BYTES);
      return 2'b10;
    end
    if ((addr % BYTES) != 0)
      $error("hbm_model: %s address %08h not aligned to the bus width", kind, addr);
    if ((addr / 4096) != ((addr + bytes - 1) / 4096))
      $error("hbm_model: %s burst %08h+%0d crosses a 4 KiB boundary", kind, addr, bytes);
    if (hbm_addr_ok(int'(addr), bytes) == 0) return 2'b11;   // DECERR
    return 2'b00;
  endfunction

  function automatic logic [DATA_W-1:0] read_beat(logic [ADDR_W-1:0] addr);
    logic [DATA_W-1:0] d;
    for (int w = 0; w < WORDS; w++) d[32*w +: 32] = hbm_read32(int'(addr) + 4 * w);
    return d;
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; arready <= 1'b0; rvalid <= 1'b0;
      rlast <= 1'b0; rdata <= '0; rresp <= '0; rid <= '0; bid <= '0; bresp <= '0;
      rq.delete(); wq.delete(); bq.delete();
      rbeat = 0; wbeat = 0; now = 0;
      n_rd_txn = 0; n_wr_txn = 0; n_rd_beats = 0; n_wr_beats = 0;
      first_cycle = -1; last_cycle = 0;
    end else begin
      txn_t t;
      now++;

      //---------------- address channels ----------------
      if (arvalid && arready) begin
        t.id = arid; t.addr = araddr; t.len = arlen;
        t.resp = check_req("read", araddr, arlen, arsize, arburst);
        t.ready_at = now + rd_lat - 1;
        rq.push_back(t);
        n_rd_txn++;
        if (first_cycle < 0) first_cycle = now;
        if (trace) $display("[hbm] %t AR addr=%08h len=%0d resp=%0d", $time, araddr, arlen, t.resp);
      end
      if (awvalid && awready) begin
        t.id = awid; t.addr = awaddr; t.len = awlen;
        t.resp = check_req("write", awaddr, awlen, awsize, awburst);
        t.ready_at = 0;
        wq.push_back(t);
        n_wr_txn++;
        if (first_cycle < 0) first_cycle = now;
        if (trace) $display("[hbm] %t AW addr=%08h len=%0d resp=%0d", $time, awaddr, awlen, t.resp);
      end

      //---------------- write data ----------------
      if (wvalid && wready) begin
        logic [ADDR_W-1:0] a;
        a = wq[0].addr + wbeat * BYTES;
        if (wq[0].resp == 2'b00)
          for (int w = 0; w < WORDS; w++)
            hbm_write32(int'(a) + 4 * w, wdata[32*w +: 32], int'(wstrb[4*w +: 4]));
        n_wr_beats++;
        last_cycle = now;
        if (wlast != (wbeat == wq[0].len))
          $error("hbm_model: WLAST mismatch on beat %0d of %0d", wbeat, wq[0].len + 1);
        if (wbeat == wq[0].len) begin
          t = wq.pop_front();
          t.ready_at = now + wr_lat;
          bq.push_back(t);
          wbeat = 0;
        end else begin
          wbeat++;
        end
      end

      //---------------- write response ----------------
      if (bvalid && bready) bvalid <= 1'b0;
      if ((!bvalid || bready) && bq.size() > 0 && bq[0].ready_at <= now && !stall()) begin
        t = bq.pop_front();
        bvalid <= 1'b1;
        bid    <= t.id;
        bresp  <= t.resp;
      end

      //---------------- read data ----------------
      if (rvalid && rready) begin
        n_rd_beats++;
        last_cycle = now;
        if (rbeat == rq[0].len) begin
          void'(rq.pop_front());
          rbeat = 0;
        end else begin
          rbeat++;
        end
      end
      if (!rvalid || rready) begin
        if (rq.size() > 0 && rq[0].ready_at <= now && !stall()) begin
          rvalid <= 1'b1;
          rid    <= rq[0].id;
          rresp  <= rq[0].resp;
          rlast  <= (rbeat == rq[0].len);
          rdata  <= (rq[0].resp == 2'b00) ? read_beat(rq[0].addr + rbeat * BYTES) : '0;
        end else begin
          rvalid <= 1'b0;
          rlast  <= 1'b0;
        end
      end

      //---------------- ready signals for the next cycle ----------------
      arready <= (rq.size() < max_out) && !stall();
      awready <= (wq.size() + bq.size() < max_out) && !stall();
      wready  <= (wq.size() > 0) && !stall();
    end
  end

  // Report once at the end of simulation.
  final begin
    longint span;
    span = (first_cycle < 0) ? 0 : (last_cycle - first_cycle + 1);
    $display("[hbm] stats: %0d read txns (%0d beats), %0d write txns (%0d beats), %0d bytes total",
             n_rd_txn, n_rd_beats, n_wr_txn, n_wr_beats, (n_rd_beats + n_wr_beats) * BYTES);
    if (span > 0)
      $display("[hbm] stats: active span %0d cycles, average %.2f bytes/cycle (peak %0d)",
               span, real'((n_rd_beats + n_wr_beats) * BYTES) / real'(span), BYTES);
  end

endmodule : hbm_model
