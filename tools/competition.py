#!/usr/bin/env python3
"""competition.py -- the competition rules (competition.json) for make, and scoring.

    competition.py make                      values for the Makefile, in KEYS order
    competition.py get <key>                 one value
    competition.py limits <synth-dir>        check a synthesis run against the limits
    competition.py score  <sim.log> <synth-dir>
                                             score = area x energy x time^2 (lower is better)

Score, for the region of interest (roi_begin()/roi_end()) of one test:

    time   = region time from the simulation                          [ms]
    energy = host CPU energy from the simulation
             + accelerator power from synthesis x time                [mJ]
    area   = accelerator cell area from synthesis (logic + SRAM)      [mm^2]
    score  = area x energy x time^2

A score is only valid if the test passed, the design meets timing at
clk_period_ns and its area is at most max_area_um2.
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES = os.path.join(REPO, "competition.json")
KEYS = ["clk_period_ns", "max_area_um2", "link_delay_ns", "tolerance_rel", "tolerance_abs"]


def rules():
    with open(RULES) as f:
        r = json.load(f)
    for k in KEYS:
        if not isinstance(r.get(k), (int, float)) or isinstance(r.get(k), bool) or r[k] < 0:
            sys.exit(f"{RULES}: '{k}' must be a non-negative number")
    if r["clk_period_ns"] <= 0 or r["max_area_um2"] <= 0:
        sys.exit(f"{RULES}: clk_period_ns and max_area_um2 must be positive")
    return r


def fmt(v):
    return f"{v:g}"


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def synth_results(synth_dir):
    """Area [um^2], worst setup slack [library time units], power [mW] of a synthesis run."""
    qor = read(os.path.join(synth_dir, "reports", "qor.rpt"))
    power = read(os.path.join(synth_dir, "reports", "power.rpt"))
    if qor is None or power is None:
        sys.exit(f"no synthesis reports in {synth_dir}\n"
                 f"run 'make synth' for this configuration first (same parameters and CLK_PERIOD)")
    area = re.search(r"Design Area:\s+([\d.eE+-]+)", qor)
    slacks = [float(x) for x in re.findall(r"Critical Path Slack:\s+(-?[\d.eE+-]+)", qor)]
    if not area or not slacks:
        sys.exit(f"{synth_dir}/reports/qor.rpt: cannot find area / slack (did synthesis finish?)")
    unit = re.search(r"Dynamic Power Units\s*=\s*1\s*(\w+)", power)
    row = re.search(r"^accel_top\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\S+\s*$", power, re.M)
    if not unit or not row:
        sys.exit(f"{synth_dir}/reports/power.rpt: cannot find the accel_top total power")
    to_mw = {"W": 1e3, "mW": 1.0, "uW": 1e-3, "nW": 1e-6, "pW": 1e-9}[unit.group(1)]
    return float(area.group(1)), min(slacks), float(row.group(4)) * to_mw


def check_limits(synth_dir, r):
    area, slack, power = synth_results(synth_dir)
    ok_t = slack >= 0.0
    ok_a = area <= r["max_area_um2"]
    print(f"limits ({os.path.relpath(RULES, os.getcwd())}) for {synth_dir}")
    print(f"  timing : worst slack {slack:g} at the synthesized clock period  -> {'met' if ok_t else 'VIOLATED'}")
    print(f"  area   : {area:.0f} um^2, limit {r['max_area_um2']:g} um^2 ({100 * area / r['max_area_um2']:.0f} %)"
          f"  -> {'ok' if ok_a else 'OVER THE LIMIT'}")
    return area, power, ok_t and ok_a


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
    area, power_mw, ok = check_limits(synth_dir, r)

    if period and abs(float(period.group(1)) - r["clk_period_ns"]) > 1e-9:
        print(f"  note   : simulated and synthesized with CLK_PERIOD={period.group(1)} ns, "
              f"the rules say {r['clk_period_ns']:g} ns")
        ok = False
    time_ms = time_ns * 1e-6
    accel_mj = power_mw * time_ns * 1e-9          # mW x ns = pJ
    host_mj = host_nj * 1e-6
    energy_mj = host_mj + accel_mj
    area_mm2 = area * 1e-6
    s = area_mm2 * energy_mj * time_ms ** 2
    print(f"score for {log_path}")
    print(f"  test   : {'passed' if passed else 'FAILED'}")
    print(f"  time   : {time_ms:.4f} ms")
    print(f"  energy : {energy_mj:.4f} mJ = host {host_mj:.4f} + accelerator {accel_mj:.4f} ({power_mw:.2f} mW x time)")
    print(f"  area   : {area_mm2:.5f} mm^2")
    valid = passed and ok
    print(f"  SCORE  : {s:.6g}  (area x energy x time^2 in mm^2 mJ ms^2, lower is better)"
          f"{'' if valid else '   ** NOT VALID: see above **'}")
    return 0 if valid else 1


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    r = rules()
    cmd = argv[1]
    if cmd == "make":
        print(" ".join(fmt(r[k]) for k in KEYS))
        return 0
    if cmd == "get" and len(argv) == 3 and argv[2] in KEYS:
        print(fmt(r[argv[2]]))
        return 0
    if cmd == "limits" and len(argv) == 3:
        return 0 if check_limits(argv[2], r)[2] else 1
    if cmd == "score" and len(argv) == 4:
        return score(argv[2], argv[3], r)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
