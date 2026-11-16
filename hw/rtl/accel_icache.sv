//-----------------------------------------------------------------------------
// accel_icache.sv
//-----------------------------------------------------------------------------
// One core's instruction cache: direct-mapped, read-only, LINES lines of one
// HBM beat (HBM_DATA_W bits = HBM_DATA_W/32 instructions) each, flushed at
// every launch (docs/architecture.md, "Instruction cache").
//
// Address split (defaults: 16 lines x 32-byte lines):
//
//    31            IDX_LO+IDX_W   IDX_LO          2  1 0
//   +-----------------+---------------+-------------+---+
//   |       tag       |     index     |    word     | 00|
//   +-----------------+---------------+-------------+---+
//      TAG_W bits        IDX_W bits     WORD_W bits
//
//   index : which line the address can live in (direct-mapped: only one)
//   tag   : which of the many addresses with that index the line holds
//   word  : which instruction inside the line
//
// Interface:
//   lookup  pc -> hit, insn          combinational: the core checks in FETCH
//   fill    fill_en, fill_pc, data   the beat that came back on a miss
//   flush   clear every valid bit    on each launch (start)
//
// There is no write path: kernels never modify their own code, so a line is
// only ever written by a fill and nothing ever needs writing back.
//-----------------------------------------------------------------------------

module accel_icache #(
  parameter int LINES      = 16,
  parameter int HBM_DATA_W = 256
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  flush,

  // lookup (combinational)
  input  logic [31:0]           pc,
  output logic                  hit,
  output logic [31:0]           insn,

  // fill after a miss
  input  logic                  fill_en,
  input  logic [31:0]           fill_pc,
  input  logic [HBM_DATA_W-1:0] fill_data
);

  localparam int WORDS  = HBM_DATA_W / 32;          // instructions per line
  localparam int WORD_W = $clog2(WORDS);
  localparam int IDX_LO = 2 + WORD_W;               // first index bit
  localparam int IDX_W  = $clog2(LINES);
  localparam int TAG_LO = IDX_LO + IDX_W;           // first tag bit
  localparam int TAG_W  = 32 - TAG_LO;

  // synopsys translate_off
  initial begin
    if (LINES < 2 || (1 << IDX_W) != LINES)
      $fatal(1, "accel_icache: ICACHE_LINES (%0d) must be a power of 2, >= 2", LINES);
  end
  // synopsys translate_on

  logic [HBM_DATA_W-1:0] data  [LINES];
  logic [TAG_W-1:0]      tag   [LINES];
  logic [LINES-1:0]      valid;

  //---------------------------------------------------------------------------
  // Lookup
  //---------------------------------------------------------------------------
  logic [IDX_W-1:0]  idx;
  logic [WORD_W-1:0] word;

  assign idx  = pc[IDX_LO +: IDX_W];
  assign word = pc[2 +: WORD_W];
  assign hit  = valid[idx] && (tag[idx] == pc[TAG_LO +: TAG_W]);
  assign insn = data[idx][32*word +: 32];

  //---------------------------------------------------------------------------
  // Fill and flush
  //---------------------------------------------------------------------------
  logic [IDX_W-1:0] fill_idx;
  assign fill_idx = fill_pc[IDX_LO +: IDX_W];

  // valid bits: reset, flush on launch, set by a fill
  always_ff @(posedge clk) begin
    if (!rst_n || flush) valid <= '0;
    else if (fill_en)    valid[fill_idx] <= 1'b1;
  end

  // data and tags need no reset: a line is only read once its valid bit is set
  always_ff @(posedge clk) begin
    if (fill_en) begin
      data[fill_idx] <= fill_data;
      tag[fill_idx]  <= fill_pc[TAG_LO +: TAG_W];
    end
  end

endmodule : accel_icache