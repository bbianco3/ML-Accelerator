#!/usr/bin/env python3
"""competition.py -- the shared settings (competition.json) for make, and scoring.

    competition.py make                      values for the Makefile, in KEYS order
    competition.py get <section>.<key>       one value, e.g. design.clk_period_ns
    competition.py limits <synth-dir>        check a synthesis run against its own targets
    competition.py score  <sim.log> <synth-dir>
                                             score = area x energy x time^2 (lower is better)

competition.json has three sections:

    design    clk_period_ns, max_area_um2            yours to tune
    synth     how hard / how long Design Compiler works   yours to tune
    platform  host link delay, HBM latency, result tolerance   fixed for everyone

Score, for the region of interest (roi_begin()/roi_end()) of one test:

    time   = region time from the simulation                          [ms]
    energy = host CPU energy from the simulation
             + accelerator power from synthesis x time                [mJ]
    area   = accelerator cell area from synthesis (logic + SRAM)      [mm^2]
    score  = area x energy x time^2

A score is valid if the test passed, the simulation ran at the clock period
the design was synthesized for, synthesis met timing at that period, and the
area is within the run's area target.
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES = os.path.join(REPO, "competition.json")

# (section, key, kind); the order is the order of `competition.py make`
KEYS = [
    ("design", "clk_period_ns", "pos"),
    ("design", "max_area_um2", "num"),
    ("synth", "time_limit_min", "num"),
    ("synth", "extra_passes", "int"),
    ("synth", "retime", "bool"),
    ("synth", "clock_gating", "bool"),
    ("synth", "max_fanout", "int"),
    ("synth", "buffer_ports", "bool"),
    ("platform", "link_delay_ns", "num"),
    ("platform", "hbm_rd_latency_ns", "num"),
    ("platform", "hbm_wr_latency_ns", "num"),
    ("platform", "tolerance_rel", "num"),
    ("platform", "tolerance_abs", "num"),
]


def rules():
    try:
        with open(RULES) as f:
            r = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"{RULES}: {e}")
    out = {}
    for sec, key, kind in KEYS:
        v = r.get(sec, {}).get(key) if isinstance(r.get(sec), dict) else None
        name = f"{sec}.{key}"
        if kind == "bool":
            if not isinstance(v, bool):
                sys.exit(f"{RULES}: '{name}' must be true or false")
            v = int(v)
        else:
            if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
                sys.exit(f"{RULES}: '{name}' must be a non-negative number")
            if kind == "int" and v != int(v):
                sys.exit(f"{RULES}: '{name}' must be a whole number")
            if kind == "pos" and v <= 0:
                sys.exit(f"{RULES}: '{name}' must be greater than 0")
        out[name] = v
    return out


def fmt(v):
    return f"{v:g}"


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def synth_results(synth_dir):
    """Results and targets of a synthesis run.

    Returns a dict: area [um^2], slack [library time units], power [mW],
    clk_ns and max_area [um^2] (the targets the run was given; None if the
    run predates reports/settings.rpt).
    """
    qor = read(os.path.join(synth_dir, "reports", "qor.rpt"))
    power = read(os.path.join(synth_dir, "reports", "power.rpt"))
    if qor is None or power is None:
        sys.exit(f"no synthesis reports in {synth_dir}\n"
                 f"run 'make synth' for this configuration first (same parameters, CLK_PERIOD and SYNTH_TAG)")
    area = re.search(r"Design Area:\s+([\d.eE+-]+)", qor)
    slacks = [float(x) for x in re.findall(r"Critical Path Slack:\s+(-?[\d.eE+-]+)", qor)]
    if not area or not slacks:
        sys.exit(f"{synth_dir}/reports/qor.rpt: cannot find area / slack (did synthesis finish?)")
    unit = re.search(r"Dynamic Power Units\s*=\s*1\s*(\w+)", power)
    row = re.search(r"^accel_top\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\S+\s*$", power, re.M)
    if not unit or not row:
        sys.exit(f"{synth_dir}/reports/power.rpt: cannot find the accel_top total power")
    to_mw = {"W": 1e3, "mW": 1.0, "uW": 1e-3, "nW": 1e-6, "pW": 1e-9}[unit.group(1)]
    res = {"area": float(area.group(1)), "slack": min(slacks), "power": float(row.group(4)) * to_mw,
           "clk_ns": None, "max_area": None}
    settings = read(os.path.join(synth_dir, "reports", "settings.rpt")) or ""
    m = re.search(r"clk_period_ns=([\d.eE+-]+)", settings)
    if m:
        res["clk_ns"] = float(m.group(1))
    m = re.search(r"max_area_um2=([\d.eE+-]+)", settings)
    if m:
        res["max_area"] = float(m.group(1))
    if res["clk_ns"] is None:                      # older run: the period is in the directory name
        m = re.search(r"_([\d.]+)ns(?:_[^/]*)?/?$", synth_dir)
        if m:
            res["clk_ns"] = float(m.group(1))
    return res


def check_limits(synth_dir, r):
    s = synth_results(synth_dir)
    target = s["max_area"] if s["max_area"] is not None else r["design.max_area_um2"]
    ok_t = s["slack"] >= 0.0
    ok_a = target <= 0 or s["area"] <= target
    clk = f"{s['clk_ns']:g} ns" if s["clk_ns"] else "its clock period"
    print(f"synthesis result in {synth_dir}")
    print(f"  timing : worst slack {s['slack']:g} at {clk}  -> {'met' if ok_t else 'VIOLATED'}")
    if target > 0:
        print(f"  area   : {s['area']:.0f} um^2, target {target:g} um^2 ({100 * s['area'] / target:.0f} %)"
              f"  -> {'ok' if ok_a else 'OVER THE TARGET'}")
    else:
        print(f"  area   : {s['area']:.0f} um^2 (no target: max_area_um2 = 0)")
    if not ok_t:
        print("  hint   : raise design.clk_period_ns, pipeline the failing path (reports/timing.rpt),"
              " or give synthesis more room (synth.extra_passes, synth.retime)")
    return s, ok_t and ok_a


def score(log_path, synth_dir, r):
    log = read(log_path)
    if log is None:
        sys.exit(f"no simulation log {log_path}")
    passed = "*** TEST PASSED ***" in log
    m = re.search(r"^ROI_STATS time_ns=([\d.]+) .*host_energy_nj=([\d.]+)", log, re.M)
    if not m:
        sys.exit(f"{log_path}: no region of interest. Put roi_begin()/roi_end() around the workload in main.c")
    period = re.search(r"accelerator clock ([\d.]+) ns", log)
    time_ns, host_nj = float(m.group(1)), float(m.group(2))
    s, ok = check_limits(synth_dir, r)

    if period and s["clk_ns"] and abs(float(period.group(1)) - s["clk_ns"]) > 1e-9:
        print(f"  clock  : simulated at {period.group(1)} ns but synthesized for {s['clk_ns']:g} ns"
              f"  -> MISMATCH (use the same CLK_PERIOD for both)")
        ok = False
    time_ms = time_ns * 1e-6
    accel_mj = s["power"] * time_ns * 1e-9        # mW x ns = pJ
    host_mj = host_nj * 1e-6
    energy_mj = host_mj + accel_mj
    area_mm2 = s["area"] * 1e-6
    sc = area_mm2 * energy_mj * time_ms ** 2
    print(f"score for {log_path}")
    print(f"  test   : {'passed' if passed else 'FAILED'}")
    print(f"  time   : {time_ms:.4f} ms")
    print(f"  energy : {energy_mj:.4f} mJ = host {host_mj:.4f} + accelerator {accel_mj:.4f} ({s['power']:.2f} mW x time)")
    print(f"  area   : {area_mm2:.5f} mm^2")
    valid = passed and ok
    print(f"  SCORE  : {sc:.6g}  (area x energy x time^2 in mm^2 mJ ms^2, lower is better)"
          f"{'' if valid else '   ** NOT VALID: see above **'}")
    return 0 if valid else 1


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    r = rules()
    cmd = argv[1]
    if cmd == "make":
        print(" ".join(fmt(r[f"{s}.{k}"]) for s, k, _ in KEYS))
        return 0
    if cmd == "get" and len(argv) == 3 and argv[2] in r:
        print(fmt(r[argv[2]]))
        return 0
    if cmd == "limits" and len(argv) == 3:
        return 0 if check_limits(argv[2], r)[1] else 1
    if cmd == "score" and len(argv) == 4:
        return score(argv[2], argv[3], r)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
