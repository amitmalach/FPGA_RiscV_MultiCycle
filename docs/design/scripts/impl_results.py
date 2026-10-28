#!/usr/bin/env python3
"""Write the numbers, the table and the chart data of chapter 10 of the final report.

    docs/design/scripts/impl_results.py <reports_dir> <baseline.md> <out.tex>
    (make impl runs it as impl_results.py build/impl/reports ../baseline.md
    figures/impl_results.tex, in docs/design/, after impl_reports.tcl wrote the reports)

Reads, from <reports_dir>, what impl_reports.tcl writes from the routed checkpoint:
utilization.rpt (report_utilization -hierarchical), power.rpt (report_power), worst_path.txt,
endpoints.txt and summary.txt. Writes <out.tex>: one \\newcommand per number the chapter
quotes, the rows of the per-module utilization table, the coordinates of the slack histogram
and of the logic-level chart (pgfplots), and the slices of the power pie (pgf-pie).

Exits 1 unless the routed design is the one docs/baseline.md describes: WNS, WHS, the setup
and hold endpoint counts, Fmax, Slice LUTs, Slice registers, block RAM tiles, DSPs and bonded
IOBs must all equal its table. Exits 1 too unless the reports agree with each other: the worst
path's slack and the smallest endpoint slack are the WNS, and the path's logic levels are its
cells between the two registers. Nothing in the output records a date, so unchanged reports write a
byte-identical file. Needs Python 3 only.
"""
import os
import re
import sys
from collections import Counter

BIN_NS = 0.25       # width of a slack histogram bin

# The rows of the utilization table: instance in the hierarchical report, the name the table
# gives it, and its depth under SOC.
UTIL_ROWS = [
    ("SOC", "SOC, the whole design", 0),
    ("cpu", "\\texttt{Processor}, the core", 1),
    ("(cpu)", "its own logic: pc, instruction, address adders", 2),
    ("control", "\\texttt{Control}, the FSM", 2),
    ("alu", "\\texttt{ALU}", 2),
    ("register_file", "\\texttt{RegisterFile}", 2),
    ("ram", "\\texttt{Memory}, the RAM", 1),
    ("bus", "\\texttt{IOBus}, the LED register", 1),
    ("uart", "\\texttt{UartTx}", 1),
    ("spiflash", "\\texttt{SPIFlash}", 1),
]

# The slices of the power pie: the report's on-chip components, in the order drawn.
POWER_ROWS = ["Static Power", "Block RAM", "Signals", "Slice Logic", "I/O", "Clocks"]


def fail(message):
    sys.exit(f"impl_results.py: {message}")


def read(path):
    with open(path) as f:
        return f.read()


def search(pattern, text, where):
    """The groups of pattern's first match in text; fails naming where it looked."""
    match = re.search(pattern, text, re.M)
    if not match:
        fail(f"no match for {pattern!r} in {where}")
    return match.groups() if len(match.groups()) > 1 else match.group(1)


def key_values(path):
    """The "<name> <value>" lines of a file written by impl_reports.tcl; CELL lines in order."""
    values, cells = {}, []
    for line in read(path).splitlines():
        name, _, value = line.partition(" ")
        if name == "CELL":
            cells.append(value.split())
        elif name:
            values[name] = value
    return values, cells


def table_rows(text, header):
    """The rows of the report table whose header row starts with header, as lists of cells."""
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(rf"\|\s*{re.escape(header)}\s*\|", l)),
                 None)
    if start is None:
        fail(f"no table headed {header!r}")
    rows = []
    for line in lines[start + 2:]:      # past the header row and the rule below it
        if not line.startswith("|"):
            break
        rows.append([c.strip() for c in line.strip().strip("|").split("|")])
    return rows


def utilization(path):
    """Instance name -> (LUTs, LUTRAMs, FFs, block RAM tiles, DSPs) from the hierarchical
    report."""
    rows = table_rows(read(path), "Instance")
    util = {}
    for instance, _module, luts, _logic, lutram, _srl, ffs, ramb36, ramb18, dsp in rows:
        util[instance] = (int(luts), int(lutram), int(ffs), int(ramb36) + int(ramb18) / 2,
                          int(dsp))
    return util


def power(path):
    """Component -> watts, for the on-chip components of the power report; '<0.001' is 0."""
    text = read(path)
    rows = table_rows(text, "On-Chip")
    watts = {row[0]: 0.0 if row[1].startswith("<") else float(row[1]) for row in rows}
    used = {row[0]: row[2] for row in rows}
    dynamic = float(search(r"^\|\s*Dynamic \(W\)\s*\|\s*([\d.]+)", text, path))
    junction = search(r"^\|\s*Junction Temperature \(C\)\s*\|\s*([\d.]+)", text, path)
    return watts, used, dynamic, junction


def baseline(path):
    """The numbers of docs/baseline.md's synthesis and implementation table."""
    text = read(path)
    where = os.path.basename(path)
    setup, hold = search(r"^\| Timing \| met \(0 failing endpoints of (\d+) setup / (\d+) hold\)",
                         text, where)
    return {
        "WNS": search(r"^\| WNS \| ([\d.]+) ns", text, where),
        "WHS": search(r"^\| WHS \| ([\d.]+) ns", text, where),
        "Fmax": search(r"^\| Fmax [^|]*\| ([\d.]+) MHz", text, where),
        "SETUP_ENDPOINTS": setup,
        "HOLD_ENDPOINTS": hold,
        "LUT": search(r"^\| Slice LUTs \| (\d+) of", text, where),
        "FF": search(r"^\| Slice registers \| (\d+) of", text, where),
        "BRAM": search(r"^\| Block RAM tiles \| (\d+) of", text, where),
        "DSP": search(r"^\| DSPs \| (\d+)", text, where),
        "IOB": search(r"^\| Bonded IOBs \| (\d+)", text, where),
    }


def histogram(values, width):
    """Bins of the given width, from the one holding the smallest value to the one holding the
    largest: a list of (lower edge, count), empty bins included."""
    counts = Counter(int(v // width) for v in values)
    return [(k * width, counts.get(k, 0)) for k in range(min(counts), max(counts) + 1)]


def tex(s):
    return re.sub(r"([_#%&$])", r"\\\1", s)


def fmt(value, digits=3):
    return f"{value:.{digits}f}"


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.split("\n\n")[1])
    reports, baseline_md, out = sys.argv[1:]
    summary, _ = key_values(os.path.join(reports, "summary.txt"))
    worst, cells = key_values(os.path.join(reports, "worst_path.txt"))
    util = utilization(os.path.join(reports, "utilization.rpt"))
    watts, used, dynamic, junction = power(os.path.join(reports, "power.rpt"))
    endpoints = [line.split() for line in read(os.path.join(reports, "endpoints.txt")).split("\n")
                 if line]
    slacks = [float(s) for s, _ in endpoints]
    levels = [int(n) for _, n in endpoints]

    period, wns, whs = float(summary["PERIOD"]), float(summary["WNS"]), float(summary["WHS"])
    fmax = 1000.0 / (period - wns)
    luts, _, ffs, bram, dsp = util["SOC"]

    # The routed design must be the baseline's.
    want = baseline(baseline_md)
    got = {
        "WNS": fmt(wns), "WHS": fmt(whs), "Fmax": fmt(fmax, 1),
        "SETUP_ENDPOINTS": summary["SETUP_ENDPOINTS"], "HOLD_ENDPOINTS": summary["HOLD_ENDPOINTS"],
        "LUT": str(luts), "FF": str(ffs), "BRAM": f"{bram:g}", "DSP": str(dsp),
        "IOB": used["I/O"],
    }
    wrong = [f"{k} {got[k]} (baseline {want[k]})" for k in want if got[k] != want[k]]
    if wrong:
        fail("the routed design is not the baseline's: " + ", ".join(wrong))
    if len(endpoints) != int(summary["SETUP_ENDPOINTS"]):
        fail(f"{len(endpoints)} endpoints in endpoints.txt, {summary['SETUP_ENDPOINTS']} timed")
    if float(worst["SLACK"]) != wns or min(slacks) != wns:
        fail(f"WNS {wns}, but the worst path's slack is {worst['SLACK']} and the smallest "
             f"endpoint slack {min(slacks)}")
    if int(worst["LOGIC_LEVELS"]) != len(cells) - 2:
        fail(f"the worst path has {worst['LOGIC_LEVELS']} logic levels but "
             f"{len(cells) - 2} cells between its registers")

    macros = {}
    macros["implVivado"] = summary["VIVADO"]
    macros["implPeriod"] = fmt(period)
    macros["implWNS"] = fmt(wns)
    macros["implWHS"] = fmt(whs)
    macros["implFmax"] = fmt(fmax, 1)
    macros["implEndpoints"] = summary["SETUP_ENDPOINTS"]
    macros["implLUTs"] = str(luts)
    macros["implFFs"] = str(ffs)

    data, logic, net = (float(worst[k]) for k in
                        ("DATAPATH_DELAY", "DATAPATH_LOGIC_DELAY", "DATAPATH_NET_DELAY"))
    macros["implPathLevels"] = worst["LOGIC_LEVELS"]
    macros["implPathDelay"] = fmt(data)
    macros["implPathLogic"] = fmt(logic)
    macros["implPathNet"] = fmt(net)
    macros["implPathNetPct"] = f"{100 * net / data:.0f}"
    macros["implPathSkew"] = fmt(float(worst["SKEW"]))
    macros["implPathStart"] = tex(worst["STARTPOINT_PIN"])
    macros["implPathStartCell"] = tex(cells[0][0])
    macros["implPathEnd"] = tex(worst["ENDPOINT_PIN"])
    between = [ref for _, ref in cells[1:-1]]       # between the two registers
    kinds = Counter(between)
    macros["implPathCells"] = ", ".join(f"{n}~\\texttt{{{ref}}}" for ref, n in
                                        sorted(kinds.items(), key=lambda kv: (-kv[1], kv[0])))
    # The path's shape: LUTs, then a carry chain, then LUTs.
    carry = [i for i, ref in enumerate(between) if ref == "CARRY4"]
    if not carry or carry != list(range(carry[0], carry[-1] + 1)):
        fail("the worst path has no single carry chain: chapter 10's description of it is stale")
    macros["implPathHead"] = str(carry[0])
    macros["implPathCarry"] = str(len(carry))
    macros["implPathTail"] = str(len(between) - carry[-1] - 1)

    under = sum(1 for s in slacks if s < 1.0)
    macros["implUnderOneNs"] = str(under)
    macros["implUnderOneNsPct"] = f"{100 * under / len(slacks):.0f}"
    deepest = max(levels)
    macros["implDeepestCount"] = str(levels.count(deepest))
    macros["implDeepest"] = str(deepest)
    macros["implNoLogic"] = str(levels.count(0))
    macros["implRegfileRAM"] = str(util["register_file"][1])
    macros["implAluLUTs"] = str(util["alu"][0])
    macros["implBusFFs"] = str(util["bus"][2])

    rows = []
    for instance, label, depth in UTIL_ROWS:
        if instance not in util:
            fail(f"no instance {instance} in utilization.rpt")
        luts, lutram, ffs, bram, _ = util[instance]
        name = f"\\hspace*{{{depth}em}}{label}" if depth else f"\\textbf{{{label}}}"
        rows.append(f"{name} & {luts} & {lutram} & {ffs} & {bram:g} \\\\")
    macros["implUtilRows"] = "\n  ".join(rows)

    bins = histogram(slacks, BIN_NS)
    # ybar interval draws a bar from each x to the next: one closing point past the last bin.
    bins.append((bins[-1][0] + BIN_NS, bins[-1][1]))
    macros["implSlackCoords"] = " ".join(f"({x:.2f},{n})" for x, n in bins)
    macros["implSlackMax"] = fmt(max(slacks))
    level_counts = Counter(levels)
    macros["implLevelCoords"] = " ".join(f"({n},{level_counts.get(n, 0)})"
                                         for n in range(deepest + 1))

    for name in POWER_ROWS:
        if name not in watts:
            fail(f"no on-chip component {name} in power.rpt")
    # pgf-pie splits a slice at its first slash: the label is braced, for I/O. The milliwatts
    # go in the legend, since the small slices have no room for them.
    slices = [(round(1000 * watts[name]), "Static" if name == "Static Power" else name)
              for name in POWER_ROWS]
    macros["implPowerPie"] = ", ".join(f"{mw}/{{{label}, {mw}~mW}}" for mw, label in slices)
    macros["implPowerTotal"] = f"{round(1000 * watts['Total'])}"
    macros["implPowerStatic"] = f"{round(1000 * watts['Static Power'])}"
    macros["implPowerDynamic"] = f"{round(1000 * dynamic)}"
    dynamic_mw = [mw for mw, label in slices if label != "Static"]
    macros["implPowerDynMin"] = str(min(dynamic_mw))
    macros["implPowerDynMax"] = str(max(dynamic_mw))
    macros["implJunction"] = junction

    with open(out, "w") as f:
        f.write("% Generated by docs/design/scripts/impl_results.py (make impl, in docs/design/)\n"
                "% from the reports of the routed design; do not edit.\n\n")
        for name, value in macros.items():
            f.write(f"\\newcommand{{\\{name}}}{{%\n  {value}}}\n")
    print(f"IMPL WNS {macros['implWNS']} ns, {macros['implPathLevels']} levels, "
          f"{macros['implLUTs']} LUTs, {macros['implPowerTotal']} mW: {out}")


if __name__ == "__main__":
    main()
