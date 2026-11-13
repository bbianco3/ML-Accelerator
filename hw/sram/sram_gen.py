#!/usr/bin/env python3
"""sram_gen.py -- SRAM macro generator for the ASAP7 predictive 7 nm PDK.

For every requested size DEPTHxWIDTH this writes

    <out>/lib/sram1rw_<D>x<W>_<CORNER>.lib   Liberty timing/power/area model (DC, OpenSTA)
    <out>/verilog/sram1rw_<D>x<W>.v          behavioral model for simulation
    <out>/datasheet_<CORNER>.md              one table with every macro's numbers

Like bsg_fakeram / OpenRAM "fake" macros, these are *models*, not layouts: the
numbers come from a small analytical model of a 6T SRAM array (below), which
is tuned to published 7 nm-class figures. They are meant to make area, timing
and power trade-offs visible and roughly right in synthesis, which they do
much better than ignoring SRAM or modelling it with flip-flops. They are not
sign-off data. See docs/sram.md.

Macro interface (single port, synchronous, one access per cycle):

    clk                 rising-edge clock
    ce_in               chip enable: 1 = access this cycle
    we_in               1 = write, 0 = read
    addr_in[AW-1:0]     word address
    wd_in[W-1:0]        write data
    w_mask_in[W-1:0]    per-bit write enable (1 = write this bit)
    rd_out[W-1:0]       read data, valid after the clock edge of a read and
                        held until the next read (writes leave it unchanged)

Usage:
    sram_gen.py --out DIR                       # the default catalog (see CATALOG)
    sram_gen.py --wrapper accel_sram_1rw.sv     # the RTL wrapper that tiles the macros
    sram_gen.py --out DIR --size 512x128 --size 64x32
    sram_gen.py --out DIR --corner SS
    sram_gen.py --print 512x128                 # just print the model numbers
"""

import argparse
import math
import os
import sys

# ---------------------------------------------------------------------------
# Default catalog: the macro sizes accel_sram_1rw.sv knows how to tile with.
# If you add sizes here, add the matching generate branch in accel_sram_1rw.sv.
# ---------------------------------------------------------------------------
CATALOG_DEPTHS = [64, 128, 256, 512]
CATALOG_WIDTHS = [32, 64, 128]
CATALOG = [(d, w) for d in CATALOG_DEPTHS for w in CATALOG_WIDTHS]

# ---------------------------------------------------------------------------
# Technology model (ASAP7-like 7 nm FinFET, 0.7 V, 25 C, typical corner).
# All lengths in um, times in ps, energies in fJ, leakage in pW, caps in fF.
# ---------------------------------------------------------------------------
BITCELL_W = 0.216          # um, bitcell pitch along the word line (one column)
BITCELL_H = 0.125          # um, bitcell pitch along the bit line (one row)
                           # -> 0.027 um^2, a 7 nm-class high-density 6T cell

# Periphery
DEC_W0, DEC_W_PER_LVL = 3.0, 0.40     # row decoder + WL drivers strip width (um)
COL_H0, COL_H_PER_MUX = 4.0, 0.60     # precharge/colmux/sense/write/IO strip height (um)

# Timing (clk -> rd_out at small load, typical corner)
T_CLK2DEC = 25.0           # clock buffering + address latch
T_DEC_PER_LVL = 9.0        # per address bit decoded (log2 rows)
T_WL_PER_COL = 0.12        # word-line RC per physical column
T_BL_PER_ROW = 0.30        # bit-line discharge per physical row (to sense margin)
T_SENSE = 25.0             # sense amplifier
T_MUX_PER_LVL = 8.0        # column mux per level
T_OUT = 20.0               # output latch + driver
R_OUT = 1.2                # ps per fF of output load
T_PRECHARGE0, T_PRECHARGE_PER_ROW = 30.0, 0.20
T_SETUP_CTRL0, T_SETUP_CTRL_PER_LVL = 30.0, 4.0   # addr/ce/we setup
T_SETUP_DATA = 30.0        # wd/w_mask setup
T_HOLD = 15.0

# Energy per access
E_FIXED = 150.0            # control, clock tree, decoder
E_COL = 4.0                # per physical column: WL + BL precharge, x (1 + rows/128)
E_RD_BIT = 6.0             # per output bit: sense amp + latch + driver
E_WR_BIT = 12.0            # per written bit: full-swing write driver
E_IDLE = 10.0              # clock edge with ce_in = 0

# Leakage
L_BIT = 20.0               # pW per bitcell
L_COL = 40.0               # pW per physical column of periphery
L_ROW = 25.0               # pW per physical row (WL driver)
L_FIXED = 2000.0           # pW control

# Pin capacitance (fF)
C_CLK0, C_CLK_PER_COL = 1.5, 0.004
C_CTRL = 0.8               # addr, ce, we
C_DATA = 0.6               # wd, w_mask
MAX_OUT_CAP = 46.08        # fF, same as the largest ASAP7 table index

# Process corners: delay, energy and leakage scale factors relative to TT, and
# the operating condition names used by the ASAP7 standard-cell libraries.
CORNERS = {
    "TT": dict(delay=1.00, energy=1.00, leak=1.0, opc="PVT_0P7V_25C", v=0.70, t=25),
    "SS": dict(delay=1.45, energy=0.82, leak=4.0, opc="PVT_0P63V_100C", v=0.63, t=100),
    "FF": dict(delay=0.78, energy=1.21, leak=2.0, opc="PVT_0P77V_0C", v=0.77, t=0),
}

SLEW_IDX = (5.0, 320.0)          # ps
LOAD_IDX = (1.44, MAX_OUT_CAP)   # fF


def clog2(n):
    return max(1, int(math.ceil(math.log2(n))))


class Macro:
    """Analytical model of one DEPTH x WIDTH single-port SRAM macro."""

    def __init__(self, depth, width, corner="TT"):
        if depth < 16 or depth & (depth - 1):
            raise ValueError(f"depth {depth} must be a power of two >= 16")
        if width < 1:
            raise ValueError(f"width {width} must be >= 1")
        self.depth, self.width, self.corner = depth, width, corner
        self.name = f"sram1rw_{depth}x{width}"
        self.aw = clog2(depth)
        k = CORNERS[corner]

        # Column muxing: fold the array to the most square shape (rows >= 16).
        best = None
        for mux in (1, 2, 4, 8):
            rows = depth // mux
            if rows < 16 or depth % mux:
                continue
            w_arr = width * mux * BITCELL_W
            h_arr = rows * BITCELL_H
            score = abs(math.log(w_arr / h_arr))
            if best is None or score < best[0]:
                best = (score, mux)
        self.mux = best[1]
        self.rows = depth // self.mux
        self.cols = width * self.mux

        # Geometry
        self.w_array = self.cols * BITCELL_W
        self.h_array = self.rows * BITCELL_H
        self.w_dec = DEC_W0 + DEC_W_PER_LVL * math.log2(self.rows)
        self.h_col = COL_H0 + COL_H_PER_MUX * math.log2(self.mux)
        self.w_total = self.w_array + self.w_dec
        self.h_total = self.h_array + self.h_col
        self.area = self.w_total * self.h_total
        self.bits = depth * width
        self.array_eff = self.bits * BITCELL_W * BITCELL_H / self.area

        # Timing
        d = k["delay"]
        self.t_access = d * (T_CLK2DEC + T_DEC_PER_LVL * math.log2(self.rows)
                             + T_WL_PER_COL * self.cols + T_BL_PER_ROW * self.rows
                             + T_SENSE + T_MUX_PER_LVL * math.log2(self.mux) + T_OUT)
        self.t_cycle = self.t_access + d * (T_PRECHARGE0 + T_PRECHARGE_PER_ROW * self.rows)
        self.t_setup_ctrl = d * (T_SETUP_CTRL0 + T_SETUP_CTRL_PER_LVL * math.log2(self.rows))
        self.t_setup_data = d * T_SETUP_DATA
        self.t_hold = d * T_HOLD

        # Energy per access (fJ)
        e = k["energy"]
        col_e = E_COL * self.cols * (1.0 + self.rows / 128.0)
        self.e_read = e * (E_FIXED + col_e + E_RD_BIT * width)
        self.e_write = e * (E_FIXED + col_e + E_WR_BIT * width)
        self.e_idle = e * E_IDLE

        # Leakage (pW)
        self.leak = k["leak"] * (L_BIT * self.bits + L_COL * self.cols
                                 + L_ROW * self.rows + L_FIXED)

        # Pin caps
        self.c_clk = C_CLK0 + C_CLK_PER_COL * self.cols

    # -----------------------------------------------------------------------
    def summary_row(self):
        return (f"| {self.name} | {self.depth} x {self.width} | {self.mux} | "
                f"{self.w_total:.1f} x {self.h_total:.1f} | {self.area:.1f} | "
                f"{self.area / self.bits:.4f} | {self.t_access:.0f} | {self.t_cycle:.0f} | "
                f"{self.e_read / 1000:.2f} | {self.e_write / 1000:.2f} | "
                f"{self.leak / 1e6:.3f} |")

    # -----------------------------------------------------------------------
    def liberty(self):
        k = CORNERS[self.corner]
        n, w, aw = self.name, self.width, self.aw
        lib = f"{n}_{self.corner}"
        s0, s1 = SLEW_IDX
        l0, l1 = LOAD_IDX

        def tbl2(v00, v01, v10, v11):
            return (f'values ( \\\n          "{v00:.2f}, {v01:.2f}", \\\n'
                    f'          "{v10:.2f}, {v11:.2f}" \\\n        );')

        def delay_tbl(t0):
            # delay grows with load and a little with clock slew
            return tbl2(t0 + 0.1 * s0 + R_OUT * l0, t0 + 0.1 * s0 + R_OUT * l1,
                        t0 + 0.1 * s1 + R_OUT * l0, t0 + 0.1 * s1 + R_OUT * l1)

        def tran_tbl():
            return tbl2(12 + 1.8 * l0, 12 + 1.8 * l1, 12 + 1.8 * l0, 12 + 1.8 * l1)

        def constraint(kind, val):
            return f"""      timing () {{
        related_pin : "clk";
        timing_type : {kind}_rising;
        rise_constraint (constraint_2x2) {{
          index_1 ("{s0}, {s1}");
          index_2 ("{s0}, {s1}");
          {tbl2(val, val, val, val)}
        }}
        fall_constraint (constraint_2x2) {{
          index_1 ("{s0}, {s1}");
          index_2 ("{s0}, {s1}");
          {tbl2(val, val, val, val)}
        }}
      }}"""

        def in_pin(kind, pname, cap, setup, is_bus):
            grp = f'bus ({pname}) {{\n      bus_type : {n}_{"ADDR" if pname == "addr_in" else "DATA"};' \
                if is_bus else f"pin ({pname}) {{"
            return f"""    {grp}
      direction : input;
      capacitance : {cap:.3f};
{constraint("setup", setup)}
{constraint("hold", self.t_hold)}
    }}"""

        e = k["energy"]
        return f"""/*
 * {n} -- {self.depth} words x {self.width} bits, single-port SRAM macro model
 * for ASAP7 ({self.corner}, {k['v']} V, {k['t']} C). Generated by hw/sram/sram_gen.py.
 *
 * This is an analytical model (bitcell + periphery), not a characterized
 * layout. See docs/sram.md.
 *   column mux {self.mux}, array {self.rows} rows x {self.cols} columns
 *   size {self.w_total:.2f} x {self.h_total:.2f} um = {self.area:.2f} um^2
 *     ({self.area / self.bits:.4f} um^2/bit, array efficiency {100 * self.array_eff:.0f} %)
 *   access {self.t_access:.1f} ps, min cycle {self.t_cycle:.1f} ps
 *   read {self.e_read:.1f} fJ, write {self.e_write:.1f} fJ, leakage {self.leak / 1000:.1f} nW
 */
library ({lib}) {{
  technology (cmos);
  delay_model : table_lookup;
  revision : "1.0";
  comment : "ASAP7 SRAM macro model, hw/sram/sram_gen.py";
  capacitive_load_unit (1,ff);
  current_unit : "1mA";
  leakage_power_unit : "1pW";
  pulling_resistance_unit : "1kohm";
  time_unit : "1ps";
  voltage_unit : "1V";
  default_cell_leakage_power : 0;
  default_fanout_load : 1;
  default_max_transition : 320;
  default_output_pin_cap : 0;
  default_inout_pin_cap : 0;
  default_input_pin_cap : 0;
  default_leakage_power_density : 0;
  input_threshold_pct_fall : 50;
  input_threshold_pct_rise : 50;
  output_threshold_pct_fall : 50;
  output_threshold_pct_rise : 50;
  slew_derate_from_library : 1;
  slew_lower_threshold_pct_fall : 10;
  slew_lower_threshold_pct_rise : 10;
  slew_upper_threshold_pct_fall : 90;
  slew_upper_threshold_pct_rise : 90;
  nom_process : 1;
  nom_temperature : {k['t']};
  nom_voltage : {k['v']};
  operating_conditions ({k['opc']}) {{
    process : 1;
    temperature : {k['t']};
    voltage : {k['v']};
  }}
  default_operating_conditions : {k['opc']};
  char_config () {{
    internal_power_calculation : exclude_switching_on_rise;
  }}

  lu_table_template (delay_2x2) {{
    variable_1 : input_net_transition;
    variable_2 : total_output_net_capacitance;
    index_1 ("{s0}, {s1}");
    index_2 ("{l0}, {l1}");
  }}
  lu_table_template (tran_2x2) {{
    variable_1 : input_net_transition;
    variable_2 : total_output_net_capacitance;
    index_1 ("{s0}, {s1}");
    index_2 ("{l0}, {l1}");
  }}
  lu_table_template (constraint_2x2) {{
    variable_1 : related_pin_transition;
    variable_2 : constrained_pin_transition;
    index_1 ("{s0}, {s1}");
    index_2 ("{s0}, {s1}");
  }}
  power_lut_template (energy_1) {{
    variable_1 : input_transition_time;
    index_1 ("{s0}, {s1}");
  }}

  type ({n}_DATA) {{
    base_type : array;
    data_type : bit;
    bit_width : {w};
    bit_from : {w - 1};
    bit_to : 0;
    downto : true;
  }}
  type ({n}_ADDR) {{
    base_type : array;
    data_type : bit;
    bit_width : {aw};
    bit_from : {aw - 1};
    bit_to : 0;
    downto : true;
  }}

  cell ({n}) {{
    area : {self.area:.4f};
    dont_use : true;
    dont_touch : true;
    interface_timing : true;
    is_macro_cell : true;
    is_memory_cell : true;
    cell_leakage_power : {self.leak:.2f};

    pin (clk) {{
      direction : input;
      clock : true;
      capacitance : {self.c_clk:.3f};
      min_period : {self.t_cycle:.2f};
      min_pulse_width_high : {self.t_cycle * 0.4:.2f};
      min_pulse_width_low : {self.t_cycle * 0.4:.2f};
      internal_power () {{
        when : "ce_in & !we_in";
        rise_power (energy_1) {{
          index_1 ("{s0}, {s1}");
          values ("{self.e_read:.2f}, {self.e_read:.2f}");
        }}
        fall_power (energy_1) {{
          index_1 ("{s0}, {s1}");
          values ("0, 0");
        }}
      }}
      internal_power () {{
        when : "ce_in & we_in";
        rise_power (energy_1) {{
          index_1 ("{s0}, {s1}");
          values ("{self.e_write:.2f}, {self.e_write:.2f}");
        }}
        fall_power (energy_1) {{
          index_1 ("{s0}, {s1}");
          values ("0, 0");
        }}
      }}
      internal_power () {{
        when : "!ce_in";
        rise_power (energy_1) {{
          index_1 ("{s0}, {s1}");
          values ("{self.e_idle:.2f}, {self.e_idle:.2f}");
        }}
        fall_power (energy_1) {{
          index_1 ("{s0}, {s1}");
          values ("0, 0");
        }}
      }}
    }}

{in_pin("ctrl", "ce_in", C_CTRL, self.t_setup_ctrl, False)}

{in_pin("ctrl", "we_in", C_CTRL, self.t_setup_ctrl, False)}

{in_pin("ctrl", "addr_in", C_CTRL, self.t_setup_ctrl, True)}

    bus (wd_in) {{
      bus_type : {n}_DATA;
      direction : input;
      capacitance : {C_DATA:.3f};
{constraint("setup", self.t_setup_data)}
{constraint("hold", self.t_hold)}
    }}

{in_pin("data", "w_mask_in", C_DATA, self.t_setup_data, True)}

    bus (rd_out) {{
      bus_type : {n}_DATA;
      direction : output;
      max_capacitance : {MAX_OUT_CAP};
      timing () {{
        related_pin : "clk";
        timing_type : rising_edge;
        timing_sense : non_unate;
        cell_rise (delay_2x2) {{
          {delay_tbl(self.t_access)}
        }}
        cell_fall (delay_2x2) {{
          {delay_tbl(self.t_access)}
        }}
        rise_transition (tran_2x2) {{
          {tran_tbl()}
        }}
        fall_transition (tran_2x2) {{
          {tran_tbl()}
        }}
      }}
    }}
  }}
}}
"""

    # -----------------------------------------------------------------------
    def verilog(self):
        n, w, aw, d = self.name, self.width, self.aw, self.depth
        return f"""// {n} -- behavioral model of a {d} x {w} single-port SRAM macro.
// Generated by hw/sram/sram_gen.py. Used in simulation when the RTL is built
// with ACCEL_SRAM_MACROS (make ... SIM_SRAM=macro); synthesis uses the .lib.
//
// One access per cycle when ce_in = 1. A read updates rd_out after the clock
// edge and rd_out holds until the next read. A write updates the bits whose
// w_mask_in bit is 1 and leaves rd_out unchanged.
`ifndef SYNTHESIS
module {n} (
  input  logic          clk,
  input  logic          ce_in,
  input  logic          we_in,
  input  logic [{aw - 1}:0]   addr_in,
  input  logic [{w - 1}:0]  wd_in,
  input  logic [{w - 1}:0]  w_mask_in,
  output logic [{w - 1}:0]  rd_out
);
  logic [{w - 1}:0] mem [{d}];

  always_ff @(posedge clk) begin
    if (ce_in) begin
      if (we_in) mem[addr_in] <= (wd_in & w_mask_in) | (mem[addr_in] & ~w_mask_in);
      else       rd_out       <= mem[addr_in];
    end
  end
endmodule
`endif
"""


# ---------------------------------------------------------------------------
# The RTL wrapper: one module that turns any DEPTH x WIDTH into catalog macros
# ---------------------------------------------------------------------------
def wrapper_sv():
    """SystemVerilog source of accel_sram_1rw, generated from the catalog."""
    mw_max, md_max = max(CATALOG_WIDTHS), max(CATALOG_DEPTHS)
    w_ok = " || ".join(f"MW == {w}" for w in CATALOG_WIDTHS)
    d_ok = " || ".join(f"MD == {d}" for d in CATALOG_DEPTHS)
    chain = []
    for i, (d, w) in enumerate(CATALOG):
        last = i == len(CATALOG) - 1
        cond = "else" if last else f"{'if' if i == 0 else 'else if'} (MD == {d} && MW == {w})"
        chain.append(f"        {cond:<32} begin : g_m `ACCEL_SRAM_MACRO(sram1rw_{d}x{w}); end")
    chain = "\n".join(chain)
    return f"""//-----------------------------------------------------------------------------
// accel_sram_1rw.sv -- GENERATED by hw/sram/sram_gen.py --wrapper. Do not edit:
// change the generator (CATALOG, wrapper_sv) and rebuild.
//-----------------------------------------------------------------------------
// Single-port synchronous SRAM of DEPTH words x WIDTH bits. Instantiate this
// for every memory in your design, never a macro directly. The build adds
// this file to simulation and synthesis automatically.
//
//   * one access per cycle when ce = 1: we = 1 writes, we = 0 reads
//   * writes update only the bits whose wmask bit is 1
//   * read data appears on rdata in the cycle AFTER the read and is valid
//     only in that cycle (do not rely on it holding)
//   * no reset: contents are undefined until written
//
// Two implementations, chosen at compile time:
//
//   default                 behavioral array (simulation, or flip-flops if
//                           synthesized -- big and slow, see docs/sram.md)
//   +define+ACCEL_SRAM_MACROS
//                           tile the memory out of the generated ASAP7 SRAM
//                           macros sram1rw_<D>x<W>. make synth sets this;
//                           make ... SIM_SRAM=macro simulates the same
//                           structure with the macros' Verilog models.
//
// Macro tiling: macro width MW = min(WIDTH, {mw_max}) and depth MD = min(DEPTH, {md_max})
// must be in the catalog (widths {CATALOG_WIDTHS}, depths {CATALOG_DEPTHS}).
// WIDTH/MW macros sit side by side, DEPTH/MD banks are selected by the top
// address bits. Sizes that do not fit fall back to the behavioral array.
//-----------------------------------------------------------------------------

module accel_sram_1rw #(
  parameter int DEPTH = 512,
  parameter int WIDTH = 256,
  localparam int AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
  input  logic             clk,
  input  logic             ce,
  input  logic             we,
  input  logic [AW-1:0]    addr,
  input  logic [WIDTH-1:0] wdata,
  input  logic [WIDTH-1:0] wmask,
  output logic [WIDTH-1:0] rdata
);

  localparam int MW = (WIDTH >= {mw_max}) ? {mw_max} : WIDTH;
  localparam int MD = (DEPTH >= {md_max}) ? {md_max} : DEPTH;
`ifdef ACCEL_SRAM_MACROS
  localparam bit USE_MACROS = ({w_ok}) &&
                              ({d_ok}) &&
                              (WIDTH % MW == 0) && (DEPTH % MD == 0);
`else
  localparam bit USE_MACROS = 1'b0;
`endif

  if (!USE_MACROS) begin : g_behav
    //-------------------------------------------------------------------------
    // Behavioral model
    //-------------------------------------------------------------------------
    logic [WIDTH-1:0] mem [DEPTH];
    always_ff @(posedge clk) begin
      if (ce) begin
        if (we) mem[addr] <= (wdata & wmask) | (mem[addr] & ~wmask);
        else    rdata     <= mem[addr];
      end
    end

  end else begin : g_macro
`ifdef ACCEL_SRAM_MACROS
    //-------------------------------------------------------------------------
    // Array of SRAM macros: NBANK banks (by address) x NCOL macros (by bits)
    //-------------------------------------------------------------------------
    localparam int NCOL  = WIDTH / MW;
    localparam int NBANK = DEPTH / MD;
    localparam int MAW   = $clog2(MD);
    localparam int BW    = (NBANK > 1) ? $clog2(NBANK) : 1;

    logic [BW-1:0]    bank;
    logic [WIDTH-1:0] bank_rd [NBANK];

    if (NBANK > 1) begin : g_bank_sel
      // Remember which bank was read so its data can be selected next cycle.
      logic [BW-1:0] bank_q;
      assign bank = addr[AW-1:MAW];
      always_ff @(posedge clk) if (ce && !we) bank_q <= bank;
      assign rdata = bank_rd[bank_q];
    end else begin : g_one_bank
      assign bank  = '0;
      assign rdata = bank_rd[0];
    end

    for (genvar b = 0; b < NBANK; b++) begin : g_bank
      logic ce_b;
      assign ce_b = ce && (bank == BW'(b));
      for (genvar c = 0; c < NCOL; c++) begin : g_col
        // The macro cell name encodes its size, so pick the instance by size.
`define ACCEL_SRAM_MACRO(NAME) \\
        NAME u_mem (.clk (clk), .ce_in (ce_b), .we_in (we), .addr_in (addr[MAW-1:0]), \\
                    .wd_in (wdata[c*MW +: MW]), .w_mask_in (wmask[c*MW +: MW]), \\
                    .rd_out (bank_rd[b][c*MW +: MW]))
{chain}
`undef ACCEL_SRAM_MACRO
      end
    end
`endif
  end

endmodule : accel_sram_1rw
"""


def parse_size(s):
    try:
        d, w = s.lower().split("x")
        return int(d), int(w)
    except ValueError:
        raise argparse.ArgumentTypeError(f"bad size '{s}', expected DEPTHxWIDTH like 512x128")


DATASHEET_HDR = """| Macro | Words x bits | Col mux | W x H (um) | Area (um^2) | um^2/bit | Access (ps) | Min cycle (ps) | Read (pJ) | Write (pJ) | Leakage (uW) |
|---|---|---|---|---|---|---|---|---|---|---|"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", help="output directory (lib/, verilog/, datasheet)")
    ap.add_argument("--size", action="append", type=parse_size, default=None,
                    help="DEPTHxWIDTH, repeatable (default: the built-in catalog)")
    ap.add_argument("--corner", default="TT", choices=sorted(CORNERS))
    ap.add_argument("--wrapper", metavar="FILE",
                    help="write the RTL wrapper accel_sram_1rw.sv (tiles any size out of the catalog) and exit")
    ap.add_argument("--print", dest="print_sizes", action="append", type=parse_size,
                    help="print the model numbers for DEPTHxWIDTH and exit")
    args = ap.parse_args()

    if args.print_sizes:
        print(DATASHEET_HDR)
        for d, w in args.print_sizes:
            print(Macro(d, w, args.corner).summary_row())
        return 0

    if args.wrapper:
        os.makedirs(os.path.dirname(os.path.abspath(args.wrapper)), exist_ok=True)
        with open(args.wrapper, "w") as f:
            f.write(wrapper_sv())
        print(f"sram_gen: wrote {args.wrapper}")
        return 0

    if not args.out:
        ap.error("--out is required (or use --print / --wrapper)")

    sizes = args.size or CATALOG
    lib_dir = os.path.join(args.out, "lib")
    v_dir = os.path.join(args.out, "verilog")
    os.makedirs(lib_dir, exist_ok=True)
    os.makedirs(v_dir, exist_ok=True)

    rows = []
    for d, w in sizes:
        m = Macro(d, w, args.corner)
        with open(os.path.join(lib_dir, f"{m.name}_{args.corner}.lib"), "w") as f:
            f.write(m.liberty())
        with open(os.path.join(v_dir, f"{m.name}.v"), "w") as f:
            f.write(m.verilog())
        rows.append(m.summary_row())

    k = CORNERS[args.corner]
    with open(os.path.join(args.out, f"datasheet_{args.corner}.md"), "w") as f:
        f.write(f"# ASAP7 SRAM macros ({args.corner}, {k['v']} V, {k['t']} C)\n\n")
        f.write("Generated by hw/sram/sram_gen.py -- analytical model, see docs/sram.md.\n\n")
        f.write(DATASHEET_HDR + "\n" + "\n".join(rows) + "\n")
    print(f"sram_gen: wrote {len(sizes)} macros ({args.corner}) to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
