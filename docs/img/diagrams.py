#!/usr/bin/env python3
"""diagrams.py -- generates the SVG diagrams used by the documentation.

    python3 docs/img/diagrams.py          # rewrites docs/img/*.svg

The diagrams are plain SVG built from a few helpers, so they can be edited
here and regenerated; no drawing tool is needed. Each diagram is a function
`d_<name>()` that returns (width, height, body) and is written to
docs/img/<name>.svg.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = "Helvetica, Arial, sans-serif"

# Colours by kind of block: (fill, stroke)
STYLE = {
    "acc":   ("#e3eefc", "#3b6fb6"),   # accelerator blocks
    "unit":  ("#d4e4fa", "#3b6fb6"),   # units inside a core
    "outer": ("#f7faff", "#3b6fb6"),   # enclosing accelerator boxes
    "host":  ("#eceff3", "#5a6472"),   # host CPU / testbench
    "mem":   ("#e3f3e6", "#3a8a4a"),   # memories
    "ctl":   ("#fdf0dc", "#b87a1e"),   # control / state machine
    "term":  ("#ffffff", "#8a94a3"),   # terminals, notes
    "pe":    ("#e3eefc", "#3b6fb6"),
}
INK = "#1f2933"
LINE = "#2f3b4a"
MUTED = "#5a6472"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=13, anchor="middle", weight="normal", color=INK, italic=False):
    st = ' font-style="italic"' if italic else ""
    return (f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" '
            f'font-weight="{weight}" fill="{color}"{st}>{esc(s)}</text>')


def box(x, y, w, h, kind="acc", lines=(), title=None, rx=6, dashed=False, size=13, title_size=13,
        align="middle"):
    """A rectangle with an optional bold title and centred lines of text."""
    fill, stroke = STYLE[kind]
    da = ' stroke-dasharray="5 4"' if dashed else ""
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" '
           f'stroke="{stroke}" stroke-width="1.4"{da}/>']
    rows = ([(title, "bold", title_size)] if title else []) + [(l, "normal", size) for l in lines]
    if rows:
        lh = 17
        y0 = y + h / 2 - (len(rows) - 1) * lh / 2 + 4.5
        tx = x + w / 2 if align == "middle" else x + 10
        for i, (s, wgt, sz) in enumerate(rows):
            out.append(text(tx, y0 + i * lh, s, size=sz, weight=wgt, anchor=align))
    return "\n".join(out)


def titled(x, y, w, h, title, kind="outer", size=13):
    """A container box with its title in the top-left corner."""
    fill, stroke = STYLE[kind]
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" '
            f'stroke="{stroke}" stroke-width="1.6"/>\n'
            + text(x + 12, y + 20, title, size=size, anchor="start", weight="bold"))


def arrow(pts, label=None, lx=None, ly=None, both=False, dashed=False, anchor="middle",
          color=LINE, label_size=12):
    d = " ".join(f"{'M' if i == 0 else 'L'}{x},{y}" for i, (x, y) in enumerate(pts))
    da = ' stroke-dasharray="6 4"' if dashed else ""
    ms = ' marker-start="url(#as)"' if both else ""
    out = [f'<path d="{d}" fill="none" stroke="{color}" stroke-width="1.5"{da} '
           f'marker-end="url(#ah)"{ms}/>']
    if label:
        if lx is None:
            (x1, y1), (x2, y2) = pts[0], pts[-1]
            lx, ly = (x1 + x2) / 2, (y1 + y2) / 2 - 7
        out.append(text(lx, ly, label, size=label_size, anchor=anchor, color=MUTED))
    return "\n".join(out)


def line(pts, dashed=False, color=LINE, width=1.5):
    d = " ".join(f"{'M' if i == 0 else 'L'}{x},{y}" for i, (x, y) in enumerate(pts))
    da = ' stroke-dasharray="6 4"' if dashed else ""
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{da}/>'


def dot(x, y, r=3):
    return f'<circle cx="{x}" cy="{y}" r="{r}" fill="{LINE}"/>'


def op(x, y, sym, r=15, kind="unit"):
    fill, stroke = STYLE[kind]
    return (f'<circle cx="{x}" cy="{y}" r="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1.4"/>\n'
            + text(x, y + 5.5, sym, size=17, weight="bold"))


def stack(x, y, w, h, n=2, step=7, kind="acc"):
    """Shadow boxes behind a box at (x, y): 'several of these'."""
    fill, stroke = STYLE[kind]
    return "\n".join(f'<rect x="{x + k * step}" y="{y + k * step}" width="{w}" height="{h}" rx="6" '
                     f'fill="{fill}" stroke="{stroke}" stroke-width="1.2"/>' for k in range(n, 0, -1))


def svg(w, h, body, title):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">
<title>{esc(title)}</title>
<defs>
  <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto">
    <path d="M0,0 L10,5 L0,10 z" fill="{LINE}"/>
  </marker>
  <marker id="as" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto">
    <path d="M10,0 L0,5 L10,10 z" fill="{LINE}"/>
  </marker>
</defs>
<rect x="0" y="0" width="{w}" height="{h}" rx="10" fill="#ffffff"/>
{body}
</svg>
'''


# =============================================================================
# README: the system at a glance
# =============================================================================
def d_overview():
    b = []
    b.append(box(20, 85, 180, 120, "host", title="Host CPU",
                 lines=["RV64G, 2 GHz", "main.c: prepare data,", "launch, check results"]))
    b.append(titled(290, 25, 320, 245, "accel_top (your design)"))
    b.append(box(305, 55, 290, 34, "acc", lines=["host registers (AXI4-Lite)"]))
    b.append(stack(305, 105, 270, 145, n=2, step=7))
    b.append(box(305, 105, 270, 145, "acc", lines=[]))
    b.append(text(440, 126, "compute core 0 .. NUM_CORES-1", weight="bold"))
    b.append(box(315, 138, 122, 44, "unit", lines=["control core"]))
    b.append(box(443, 138, 122, 44, "unit", lines=["VPU (VLEN)"]))
    b.append(box(315, 192, 122, 44, "unit", lines=["MXU (MAT_DIM²)"]))
    b.append(box(443, 192, 122, 44, "mem", lines=["scratchpad SRAM"]))
    b.append(box(710, 110, 130, 75, "mem", title="HBM", lines=["kernels + data"]))
    b.append(arrow([(200, 112), (290, 112)], "AXI4-Lite"))
    b.append(arrow([(290, 170), (200, 170)], "irq"))
    b.append(arrow([(610, 147), (710, 147)], "AXI4"))
    b.append(arrow([(110, 205), (110, 300), (775, 300), (775, 185)], both=True, dashed=True))
    b.append(text(442, 293, "shared memory: the host CPU reads and writes HBM directly", size=12, color=MUTED))
    return 860, 320, "\n".join(b)


# =============================================================================
# architecture.md: block diagram of the reference design
# =============================================================================
def d_architecture():
    b = []
    b.append(box(10, 55, 90, 70, "host", title="Host CPU"))
    b.append(titled(170, 20, 700, 525, "accel_top"))
    b.append(box(190, 52, 660, 52, "acc", title="accel_csr: host registers",
                 lines=["START_PC, ARG0..7, CORES, CTRL, STATUS; run status of all cores; irq"]))
    b.append(arrow([(100, 73), (190, 73)], "AXI4-Lite", lx=104, ly=66, anchor="start"))
    b.append(arrow([(190, 100), (100, 100)], "irq", lx=104, ly=117, anchor="start"))

    # core 0
    b.append(titled(190, 140, 430, 175, "core 0: accel_core (control core)", kind="acc"))
    b.append(text(405, 178, "fetch → execute state machine, x0..x31, pc, vl", size=12, color=MUTED))
    b.append(box(205, 195, 125, 100, "unit", title="I-cache", lines=["accel_icache", "kernel code"]))
    b.append(box(343, 195, 125, 100, "unit", title="vector unit", lines=["accel_vpu", "v0..v31"]))
    b.append(box(481, 195, 125, 100, "unit", title="matrix unit", lines=["accel_mxu", "tr*, acc*"]))
    b.append(arrow([(300, 104), (300, 140)], "start", lx=307, ly=126, anchor="start"))
    b.append(arrow([(560, 140), (560, 104)], "done / error", lx=567, ly=126, anchor="start"))

    # scratchpad / router
    b.append(box(190, 355, 430, 82, "mem", title="accel_spad: address router",
                 lines=["0x2000_0000 …  →  accel_sram_1rw (scratchpad SRAM)",
                        "anything else  →  accel_axi_master (AXI4 bursts)"]))
    b.append(arrow([(405, 315), (405, 355)], "requests / responses", both=True, lx=413, ly=340, anchor="start"))

    # other cores and barrier
    b.append(stack(690, 140, 150, 100, n=2, step=6))
    b.append(box(690, 140, 150, 100, "acc", title="core 1 .. N-1",
                 lines=["same as core 0:", "control core, units,", "scratchpad, AXI master"], size=12))
    b.append(arrow([(770, 104), (770, 140)]))
    b.append(box(655, 275, 120, 52, "ctl", title="barrier /", lines=["abort"]))
    b.append(arrow([(620, 300), (655, 300)], both=True))
    b.append(arrow([(715, 252), (715, 275)], both=True))

    # arbiter and HBM
    b.append(box(190, 470, 660, 46, "acc", title="accel_axi_arbiter",
                 lines=["N → 1, round robin; responses routed back by AXI ID"], size=12))
    b.append(arrow([(405, 437), (405, 470)], "AXI4, ID = core index", lx=413, ly=458, anchor="start"))
    b.append(arrow([(830, 252), (830, 470)], "AXI4", lx=822, ly=420, anchor="end"))
    b.append(box(430, 585, 180, 48, "mem", title="HBM"))
    b.append(arrow([(520, 516), (520, 585)], "AXI4 (HBM_DATA_W bits)", lx=528, ly=567, anchor="start"))
    return 890, 650, "\n".join(b)


# =============================================================================
# architecture.md: the control core's state machine
# =============================================================================
def d_core_fsm():
    b = []
    W, H = 104, 32

    def st(x, y, name, kind="ctl"):
        return box(x, y, W, H, kind, lines=[name], size=12)

    b.append(st(20, 30, "IDLE"))
    b.append(st(170, 30, "FETCH"))
    b.append(st(320, 30, "EXEC"))
    b.append(arrow([(124, 46), (170, 46)], "start"))
    b.append(arrow([(274, 46), (320, 46)], "hit"))
    b.append(st(170, 130, "IFILL"))
    b.append(st(170, 210, "IFILL_WAIT"))
    b.append(arrow([(200, 62), (200, 130)], "miss", lx=192, ly=100, anchor="end"))
    b.append(arrow([(200, 162), (200, 210)]))
    b.append(arrow([(274, 226), (298, 226), (298, 90), (250, 90), (250, 62)]))
    b.append(text(304, 160, "line filled", size=11, anchor="start", color=MUTED))

    bus = 460
    rows = [
        (None, None, "scalar ALU, branch, csrr, vsetvl"),
        ("MEM", "MEM_WAIT", "lw / sw, vle16 / vse16"),
        ("VPU_WAIT", None, "vector arithmetic"),
        ("MX_ROW", "MX_ROW_WAIT", "mld / mst / msta: MAT_DIM rows"),
        ("MXU_WAIT", None, "mzero / mmacc"),
        ("BARRIER", None, "barrier"),
    ]
    b.append(line([(424, 46), (bus, 46), (bus, 46 + 60 * len(rows))]))
    x1, x2, xf = 490, 625, 760
    for i, (a, c, note) in enumerate(rows):
        y = 30 + 60 * i
        yc = y + H / 2
        if i:
            b.append(dot(bus, yc))
        if a is None:
            b.append(arrow([(bus, yc), (xf, yc)]))
        else:
            b.append(arrow([(bus, yc), (x1, yc)]))
            b.append(st(x1, y, a))
            if c:
                b.append(arrow([(x1 + W, yc), (x2, yc)]))
                b.append(st(x2, y, c))
                b.append(arrow([(x2 + W, yc), (xf, yc)]))
            else:
                b.append(arrow([(x1 + W, yc), (xf, yc)]))
        b.append(box(xf, y, 80, H, "term", lines=["→ FETCH"], size=12, dashed=True))
        b.append(text(xf + 95, yc + 4, note, size=12, anchor="start", color=MUTED))
        if a == "MX_ROW":
            b.append(arrow([(x2 + W / 2, y + H), (x2 + W / 2, y + H + 14), (x1 + W / 2, y + H + 14),
                            (x1 + W / 2, y + H)]))
            b.append(text((x1 + x2 + W) / 2, y + H + 26, "next row", size=11, color=MUTED))
    y = 30 + 60 * len(rows)
    b.append(dot(bus, y + H / 2))
    b.append(arrow([(bus, y + H / 2), (x1, y + H / 2)]))
    b.append(st(x1, y, "IDLE"))
    b.append(text(x1 + W + 15, y + H / 2 + 4, "ecall (done) or fault", size=12, anchor="start", color=MUTED))
    return 1090, y + 60, "\n".join(b)


# =============================================================================
# host-model.md: platform
# =============================================================================
def d_platform():
    b = []
    b.append(box(20, 30, 230, 110, "host", title="Host CPU",
                 lines=["RV64G, 2 GHz", "time + energy:", "sim/csrc/host_model.c"]))
    b.append(box(590, 30, 230, 110, "acc", title="Accelerator",
                 lines=["clock: CLK_PERIOD", "time: RTL simulation", "power: make synth"]))
    b.append(arrow([(250, 72), (590, 72)], "link: LINK_DELAY_NS each way", both=True, ly=62))
    b.append(text(420, 95, "host registers (AXI4-Lite), irq", size=12, color=MUTED))
    b.append(box(320, 190, 200, 50, "mem", title="HBM", lines=["shared memory"], size=12))
    b.append(arrow([(135, 140), (135, 215), (320, 215)], both=True))
    b.append(arrow([(705, 140), (705, 215), (520, 215)], both=True))
    b.append(text(140, 232, "loads / stores (cache model)", size=11, anchor="start", color=MUTED))
    b.append(text(700, 232, "AXI4", size=11, anchor="end", color=MUTED))
    return 840, 260, "\n".join(b)


# =============================================================================
# simulation.md: the simulated system
# =============================================================================
def d_simulation():
    b = []
    b.append(box(20, 30, 220, 90, "host", title="host_bfm.sv",
                 lines=["RV64G ISS (C, via DPI)", "+ time / energy model"]))
    b.append(box(370, 30, 180, 90, "acc", title="accel_top", lines=["RTL, the DUT"]))
    b.append(box(680, 30, 160, 90, "mem", title="hbm_model.sv", lines=["AXI4 slave, timed"]))
    b.append(arrow([(240, 60), (370, 60)], "AXI4-Lite + link delay"))
    b.append(arrow([(370, 95), (240, 95)], "irq", ly=110))
    b.append(arrow([(550, 75), (680, 75)], "AXI4 (timed)"))
    b.append(box(220, 175, 440, 56, "host", title="platform.c",
                 lines=["host RAM, HBM storage, ELF loader, console"], size=12))
    b.append(arrow([(130, 120), (130, 203), (220, 203)], both=True))
    b.append(arrow([(760, 120), (760, 203), (660, 203)], both=True))
    b.append(text(135, 252, "functional access (cache model inside the region of interest)",
                  size=11, anchor="start", color=MUTED))
    b.append(text(755, 252, "storage behind the AXI model", size=11, anchor="end", color=MUTED))
    return 860, 270, "\n".join(b)


# =============================================================================
# matrix-engines.md
# =============================================================================
def d_tiled_accumulator():
    b = []
    cols = [200, 320, 440, None, 600]
    labels = ["B[k][0]", "B[k][1]", "B[k][2]", None, "B[k][T-1]"]
    yb, ym, ya, yacc = 30, 120, 185, 235
    b.append(box(20, ym - 18, 100, 36, "acc", lines=["A[i][k]"]))
    b.append(line([(120, ym), (600, ym)]))
    for x, lab in zip(cols, labels):
        if x is None:
            b.append(text(520, ym + 50, "…", size=20))
            continue
        b.append(box(x - 45, yb, 90, 30, "acc", lines=[lab], size=12))
        b.append(arrow([(x, yb + 30), (x, ym - 15)]))
        b.append(op(x, ym, "×"))
        b.append(arrow([(x, ym + 15), (x, ya - 15)]))
        b.append(op(x, ya, "+"))
        b.append(arrow([(x, ya + 15), (x, yacc)]))
        b.append(box(x - 45, yacc, 90, 32, "mem", lines=[f"acc[i][{lab[5:-1]}]"], size=12))
        b.append(arrow([(x + 45, yacc + 16), (x + 55, yacc + 16), (x + 55, ya), (x + 15, ya)]))
    b.append(text(660, yb + 20, "one row of B, broadcast down", size=12, anchor="start", color=MUTED))
    b.append(text(660, ym + 4, "one element of A, broadcast across", size=12, anchor="start", color=MUTED))
    b.append(text(660, ya + 4, "fp32 add (feedback loop)", size=12, anchor="start", color=MUTED))
    b.append(text(660, yacc + 20, "accumulator row i (fp32 registers)", size=12, anchor="start", color=MUTED))
    b.append(text(450, 305, "MXU_ROWS output rows i at once, then the next MXU_ROWS rows, then k + 1",
                  size=12, italic=True, color=MUTED))
    return 900, 325, "\n".join(b)


def d_dot_product():
    b = []
    xs = [90, 230, 370, 510]
    for k, x in enumerate(xs):
        b.append(box(x - 60, 25, 120, 30, "acc", lines=[f"A[i][{k}]  B[{k}][j]"], size=12))
        b.append(arrow([(x, 55), (x, 90)]))
        b.append(op(x, 105, "×"))
    for x, (l, r) in zip([160, 440], [(90, 230), (370, 510)]):
        b.append(arrow([(l, 120), (l, 150), (x - 12, 165)]))
        b.append(arrow([(r, 120), (r, 150), (x + 12, 165)]))
        b.append(op(x, 178, "+"))
    b.append(arrow([(160, 193), (160, 225), (288, 240)]))
    b.append(arrow([(440, 193), (440, 225), (312, 240)]))
    b.append(op(300, 252, "+"))
    b.append(arrow([(300, 267), (300, 300)]))
    b.append(op(300, 315, "+"))
    b.append(box(380, 297, 120, 36, "mem", lines=["C[i][j]"], size=12))
    b.append(arrow([(380, 315), (315, 315)]))
    b.append(arrow([(300, 330), (300, 360), (440, 360), (440, 333)]))
    for y in (140, 212):
        b.append(line([(30, y), (570, y)], dashed=True, color="#b87a1e", width=1.2))
    b.append(text(580, 144, "pipeline register (optional)", size=11, anchor="start", color="#b87a1e"))
    b.append(text(580, 216, "pipeline register (optional)", size=11, anchor="start", color="#b87a1e"))
    b.append(text(580, 230, "no feedback in the tree: add as many as you like", size=11, anchor="start", color="#b87a1e"))
    b.append(text(580, 109, "T multipliers (T = 4 here)", size=12, anchor="start", color=MUTED))
    b.append(text(580, 182, "adder tree: log2(T) levels", size=12, anchor="start", color=MUTED))
    b.append(text(580, 319, "C[i][j] = C[i][j] + dot", size=12, anchor="start", color=MUTED))
    return 860, 380, "\n".join(b)


def _grid(stationary_b):
    b = []
    n, x0, y0, dx, dy, w, h = 3, 170, 85, 150, 105, 100, 56
    for i in range(n):
        for j in range(n):
            x, y = x0 + j * dx, y0 + i * dy
            if stationary_b:
                b.append(box(x, y, w, h, "pe", title=f"B[{i}][{j}]", lines=["stored"], size=11))
            else:
                b.append(box(x, y, w, h, "pe", title=f"PE {i},{j}", lines=["acc"], size=11))
            if j < n - 1:
                b.append(arrow([(x + w, y + h / 2), (x + dx, y + h / 2)]))
            if i < n - 1 or stationary_b:
                nxt = y + dy if i < n - 1 else y + h + 40
                b.append(arrow([(x + w / 2, y + h), (x + w / 2, nxt)]))
        lab = f"A[*][{i}]" if stationary_b else f"A[{i}][*]"
        b.append(box(20, y0 + i * dy + h / 2 - 15, 95, 30, "acc", lines=[lab], size=12))
        b.append(arrow([(115, y0 + i * dy + h / 2), (x0, y0 + i * dy + h / 2)]))
        if not stationary_b and i:
            b.append(text(142, y0 + i * dy + h / 2 - 8, f"+{i}", size=11, color="#b87a1e"))
    for j in range(n):
        x = x0 + j * dx + w / 2
        if stationary_b:
            b.append(box(x - 40, 20, 80, 28, "term", lines=["0"], size=12))
            b.append(box(x - 45, y0 + n * dy - dy + h + 40, 90, 30, "mem", lines=[f"C[*][{j}]"], size=12))
        else:
            b.append(box(x - 45, 20, 90, 28, "acc", lines=[f"B[*][{j}]"], size=12))
            if j:
                b.append(text(x + 12, 68, f"+{j}", size=11, anchor="start", color="#b87a1e"))
        b.append(arrow([(x, 48), (x, y0)]))
    return b


def d_systolic_os():
    b = _grid(False)
    tx = 640
    for k, s in enumerate(["B columns enter at the top,", "column j delayed j cycles (+j)", "",
                           "A rows enter at the left,", "row i delayed i cycles (+i)", "",
                           "each PE keeps one C[i][j]", "in its accumulator"]):
        b.append(text(tx, 100 + 18 * k, s, size=12, anchor="start", color=MUTED))
    b.append(box(170, 375, 400, 34, "term",
                 lines=["each PE, every cycle:  acc += a·b;  pass a right, b down"], size=12))
    return 880, 425, "\n".join(b)


def d_systolic_ws():
    b = _grid(True)
    tx = 640
    for k, s in enumerate(["partial sums enter at the top as 0", "(or as the old C, to accumulate)", "",
                           "row k of the grid holds row k of B;", "element k of each A row enters row k", "",
                           "one finished row of C", "leaves the bottom every cycle"]):
        b.append(text(tx, 100 + 18 * k, s, size=12, anchor="start", color=MUTED))
    b.append(box(170, 440, 420, 34, "term",
                 lines=["each PE, every cycle:  sum_out = sum_in + a·b;  pass a right"], size=12))
    return 880, 490, "\n".join(b)


# =============================================================================
# isa.md: instruction formats
# =============================================================================
def _fmt(rows, title):
    """rows: [(name, [(field label, hi bit, lo bit, kind), ...]), ...]"""
    b = []
    px, x0 = 22, 120
    y = 20
    for name, fields in rows:
        b.append(text(x0 - 12, y + 42, name, size=12, anchor="end", weight="bold"))
        for lab, hi, lo, kind in fields:
            x = x0 + (31 - hi) * px
            w = (hi - lo + 1) * px
            b.append(box(x, y + 22, w, 32, kind, lines=[lab], rx=2, size=12))
            b.append(text(x + 3, y + 16, str(hi), size=10, anchor="start", color=MUTED))
            if hi != lo:
                b.append(text(x + w - 3, y + 16, str(lo), size=10, anchor="end", color=MUTED))
        y += 70
    return x0 + 32 * px + 20, y + 5, "\n".join(b)


def d_isa_vmem():
    return _fmt([
        ("I-type", [("imm[11:0]", 31, 20, "acc"), ("rs1", 19, 15, "acc"), ("funct3", 14, 12, "ctl"),
                    ("rd / vd", 11, 7, "acc"), ("0101011", 6, 0, "host")]),
        ("S-type", [("imm[11:5]", 31, 25, "acc"), ("vs3", 24, 20, "acc"), ("rs1", 19, 15, "acc"),
                    ("funct3", 14, 12, "ctl"), ("imm[4:0]", 11, 7, "acc"), ("0101011", 6, 0, "host")]),
    ], "custom-1")


def d_isa_varith():
    return _fmt([
        ("R-type", [("funct7", 31, 25, "ctl"), ("rs2 = vs2", 24, 20, "acc"), ("rs1 = vs1 / x", 19, 15, "acc"),
                    ("funct3", 14, 12, "ctl"), ("rd = vd", 11, 7, "acc"), ("0001011", 6, 0, "host")]),
    ], "custom-0")


def d_isa_matrix():
    return _fmt([
        ("R-type", [("funct7", 31, 25, "ctl"), ("rs2", 24, 20, "acc"), ("rs1", 19, 15, "acc"),
                    ("funct3", 14, 12, "ctl"), ("rd", 11, 7, "acc"), ("1011011", 6, 0, "host")]),
    ], "custom-2")


DIAGRAMS = {
    "overview": ("The system: host CPU, accelerator, HBM", d_overview),
    "architecture": ("Block diagram of the reference design", d_architecture),
    "core-fsm": ("State machine of the reference design's control core", d_core_fsm),
    "platform": ("Host CPU, link and accelerator", d_platform),
    "simulation": ("The simulated system", d_simulation),
    "tiled-accumulator": ("Tiled accumulator", d_tiled_accumulator),
    "dot-product": ("Dot-product engine", d_dot_product),
    "systolic-os": ("Output-stationary systolic array", d_systolic_os),
    "systolic-ws": ("Weight-stationary systolic array", d_systolic_ws),
    "isa-vmem": ("Instruction formats, custom-1", d_isa_vmem),
    "isa-varith": ("Instruction format, custom-0", d_isa_varith),
    "isa-matrix": ("Instruction format, custom-2", d_isa_matrix),
}


def main():
    for name, (title, fn) in DIAGRAMS.items():
        w, h, body = fn()
        with open(os.path.join(HERE, f"{name}.svg"), "w") as f:
            f.write(svg(w, h, body, title))
    print(f"wrote {len(DIAGRAMS)} diagrams to {HERE}")


if __name__ == "__main__":
    main()
