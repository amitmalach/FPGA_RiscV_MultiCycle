#!/usr/bin/env python3
"""Render signals from a VCD file as a waveform figure, a vector PDF, for the final report.

    docs/design/scripts/vcd_wave.py <in.vcd> <spec> <out.pdf> [--start <path>=<hex>,...]
                                    [--cycles <n>] [--width <pt>]
    docs/design/scripts/vcd_wave.py --selftest

<spec> is a text file, one signal per line, drawn top to bottom in that order:

    <path> <label> <format> [<colour>]

    path    the signal's hierarchical name, or any suffix of it that names one signal
            (cpu.control.state); the dot separates levels, and a bit range is not written
    label   the name drawn in the left column, or - for the path's last component
    format  clock   the clock: a grey grid line at each of its rising edges, numbered from 0
            grid    the clock as above, but its own row is not drawn
            bit     one line, high or low
            hex     a bus, its value in hex with the leading zeros dropped
            dec     a bus, its value in decimal
            <n>=<name>,...   a bus drawn with a name for each of its values (an FSM's states),
                    n in decimal; a value without a name is drawn in decimal
    colour  RRGGBB for the label, optional (the report's module colours)

Blank lines and lines starting with # are skipped. The figure spans the whole VCD unless
--start names signal values: it then begins at the first time at which every named signal
holds its value, after all the changes of that time, and --cycles <n> ends it n clock
periods later (the period is the spacing of the clock's rising edges). In a long window the
cycle numbers and grid lines thin out to every 2nd, 5th, 10th, ... cycle, so they stay
legible. Values of x or z are drawn as x. Nothing in the output records a date, so an
unchanged VCD renders byte-identical. Needs only Python 3.
"""
import bisect
import re
import sys
import zlib

# Helvetica's glyph widths for the printable ASCII characters, in thousandths of the font
# size, from the Adobe font metrics: the figure needs them to know whether a value fits.
HELVETICA = dict(zip(
    range(32, 127),
    [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
     556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
     1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
     667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
     333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
     556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]))


def text_width(text, size):
    return sum(HELVETICA.get(ord(c), 556) for c in text) * size / 1000


# ---- VCD -------------------------------------------------------------------------------

class Signal:
    def __init__(self, width):
        self.width = width
        self.times, self.values = [], []    # one entry per change, times ascending

    def add(self, time, value):
        if self.times and self.times[-1] == time:
            self.times.pop()                 # several changes at one time: the last one holds
            self.values.pop()
        if not self.values or self.values[-1] != value:
            self.times.append(time)
            self.values.append(value)


class Vcd:
    """The signals of a VCD file and their changes, times in the file's timescale units."""

    def __init__(self, text):
        self.timescale_ps = 1
        self.signals = {}
        self.end = 0
        codes, scope, now = {}, [], 0
        tokens = iter(text.split())
        for token in tokens:
            if token == "$timescale":
                unit = "".join(iter(tokens.__next__, "$end"))
                number, suffix = re.fullmatch(r"(\d+)(s|ms|us|ns|ps|fs)", unit).groups()
                self.timescale_ps = int(number) * {"s": 10**12, "ms": 10**9, "us": 10**6,
                                                   "ns": 1000, "ps": 1, "fs": 0.001}[suffix]
            elif token == "$scope":
                next(tokens)                                   # the scope's kind
                scope.append(next(tokens))
                assert next(tokens) == "$end"
            elif token == "$upscope":
                scope.pop()
                assert next(tokens) == "$end"
            elif token == "$var":
                next(tokens)                                   # the variable's kind
                width, code, name = int(next(tokens)), next(tokens), next(tokens)
                for _ in iter(tokens.__next__, "$end"):        # a bit range, if any
                    pass
                full = ".".join(scope + [name])
                if full not in self.signals:
                    self.signals[full] = Signal(width)
                codes.setdefault(code, []).append(self.signals[full])
            elif token in ("$date", "$version", "$comment", "$enddefinitions"):
                for _ in iter(tokens.__next__, "$end"):
                    pass
            elif token in ("$dumpvars", "$dumpall", "$dumpon", "$dumpoff", "$end"):
                pass                                           # the values follow as changes
            elif token[0] == "#":
                now = int(token[1:])
                self.end = max(self.end, now)
            elif token[0] in "01xXzZ":
                for signal in codes[token[1:]]:
                    signal.add(now, token[0].lower())
            elif token[0] in "bB":
                value = next(tokens)
                for signal in codes[value]:
                    signal.add(now, token[1:].lower())
            elif token[0] in "rR":
                next(tokens)                                   # a real: not drawn
            else:
                raise ValueError(f"unexpected VCD token {token!r}")

    def resolve(self, path):
        """The one signal whose name is path or ends in '.' + path."""
        found = [n for n in self.signals if n == path or n.endswith("." + path)]
        if len(found) != 1:
            raise KeyError(f"{path}: {len(found)} signals match" if found
                           else f"{path}: no such signal")
        return found[0]

    def changes(self, name):
        signal = self.signals[name]
        return list(zip(signal.times, signal.values))

    def value_at(self, name, time):
        signal = self.signals[name]
        i = bisect.bisect_right(signal.times, time) - 1
        return signal.values[i] if i >= 0 else "x"

    def rising_edges(self, name):
        signal = self.signals[name]
        return [t for t, v, prev in zip(signal.times, signal.values, ["x"] + signal.values)
                if v == "1" and prev == "0"]

    def trigger(self, wanted):
        """The first time at which every signal in wanted holds its value, or None."""
        times = sorted({t for name in wanted for t in self.signals[name].times})
        for t in times:
            if all(as_int(self.value_at(name, t)) == value for name, value in wanted.items()):
                return t
        return None


def as_int(bits):
    return None if set(bits) - set("01") else int(bits, 2)


# ---- spec ------------------------------------------------------------------------------

def format_value(bits, fmt):
    """A bus value as the spec's format draws it; any x or z bit makes the value x."""
    number = as_int(bits)
    if number is None:
        return "x"
    if fmt == "hex":
        return f"{number:x}"
    if fmt == "dec":
        return str(number)
    return fmt.get(number, str(number))


def parse_spec(text):
    """[(path, label, format, colour)] from the spec file's text."""
    rows = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) not in (3, 4):
            raise ValueError(f"spec line needs path, label, format [colour]: {line!r}")
        path, label, fmt = fields[:3]
        if label == "-":
            label = path.split(".")[-1]
        if fmt not in ("clock", "grid", "bit", "hex", "dec"):
            fmt = {int(n): name for n, name in (item.split("=") for item in fmt.split(","))}
        colour = None
        if len(fields) == 4:
            rgb = int(fields[3], 16)
            colour = (rgb >> 16, rgb >> 8 & 255, rgb & 255)
        rows.append((path, label, fmt, colour))
    return rows


# ---- drawing ---------------------------------------------------------------------------

LABEL_SIZE, VALUE_SIZE, RULER_SIZE = 7.0, 6.0, 6.0
ROW, GAP = 11.0, 4.0            # a signal's height, and the space between signals
RULER = 10.0                    # the cycle numbers above the signals
SLOPE = 1.2                     # half-width of a bus transition's slanted ends
MARGIN = 3.0


class Page:
    """A PDF content stream: lines, filled rectangles and Helvetica text."""

    def __init__(self):
        self.ops = []

    def line(self, points, width=0.6, grey=0.0):
        self.ops.append("%.3g G %.3g w" % (grey, width))
        self.ops.append(" ".join("%.4g %.4g %s" % (x, y, "m" if i == 0 else "l")
                                 for i, (x, y) in enumerate(points)) + " S")

    def text(self, x, y, string, size, rgb=(0, 0, 0)):
        escaped = string.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        self.ops.append("BT %.4g %.4g %.4g rg /F1 %.4g Tf %.4g %.4g Td (%s) Tj ET"
                        % (rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, size, x, y, escaped))

    def write(self, path, width, height):
        stream = zlib.compress("\n".join(self.ops).encode(), 9)
        objects = [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:.4g} {height:.4g}] "
            f"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".encode(),
            f"<< /Length {len(stream)} /Filter /FlateDecode >>\nstream\n".encode() + stream
            + b"\nendstream",
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for number, body in enumerate(objects, 1):
            offsets.append(len(pdf))
            pdf += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
        xref = len(pdf)
        pdf += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
        pdf += b"".join(f"{o:010d} 00000 n \n".encode() for o in offsets)
        pdf += (f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n"
                f"%%EOF\n").encode()
        with open(path, "wb") as f:
            f.write(pdf)


def draw(vcd, rows, out, start, end, edges, width):
    """The figure: rows top to bottom, time left to right from start to end, grid at edges."""
    label_w = max(text_width(label, LABEL_SIZE) for _, label, _, _ in rows) + 2 * MARGIN
    x0, x1 = label_w, width - MARGIN
    scale = (x1 - x0) / (end - start)
    height = RULER + len(rows) * (ROW + GAP) + MARGIN
    page = Page()

    def x_of(t):
        return x0 + (t - start) * scale

    # The cycle grid and its numbers, thinned out when a cycle is narrower than a number.
    top, bottom = height - RULER, MARGIN
    cycle_w = x_of(edges[1]) - x_of(edges[0]) if len(edges) > 1 else x1 - x0
    step = next(s for s in (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 10**9)
                if s * cycle_w >= 16)
    for n, (a, b) in enumerate(zip(edges, edges[1:] + [None])):
        if n % step:
            continue
        page.line([(x_of(a), top), (x_of(a), bottom)], width=0.4, grey=0.8)
        b = end if b is None else b
        if b <= end:
            label = str(n)
            page.text((x_of(a) + x_of(b) - text_width(label, RULER_SIZE)) / 2,
                      height - RULER_SIZE - 1, label, RULER_SIZE, (90, 90, 90))

    for i, (name, label, fmt, colour) in enumerate(rows):
        y_low = height - RULER - (i + 1) * (ROW + GAP) + GAP
        y_high = y_low + ROW
        page.text(MARGIN, y_low + (ROW - LABEL_SIZE) / 2 + 1, label, LABEL_SIZE,
                  colour or (0, 0, 0))
        signal = vcd.signals[name]
        # The value holding at start, then every change inside the window.
        i0 = max(bisect.bisect_right(signal.times, start) - 1, 0)
        segments = [(start, signal.values[i0])]
        for t, v in zip(signal.times[i0 + 1:], signal.values[i0 + 1:]):
            if t >= end:
                break
            if t > start:
                segments.append((t, v))
        times = [t for t, _ in segments] + [end]
        if fmt in ("clock", "bit"):
            points = []
            for (t, v), t_next in zip(segments, times[1:]):
                y = y_high if v == "1" else y_low if v == "0" else (y_low + y_high) / 2
                points += [(x_of(t), y), (x_of(t_next), y)]
            page.line(points)
        else:
            for (t, v), t_next in zip(segments, times[1:]):
                xa, xb = x_of(t), x_of(t_next)
                sa = SLOPE if t > start else 0
                sb = SLOPE if t_next < end else 0
                y_mid = (y_low + y_high) / 2
                page.line([(xa, y_mid), (xa + sa, y_high), (xb - sb, y_high), (xb, y_mid),
                           (xb - sb, y_low), (xa + sa, y_low), (xa, y_mid)])
                string = format_value(v, fmt)
                w = text_width(string, VALUE_SIZE)
                if w <= xb - xa - 2 * SLOPE - 2:
                    page.text((xa + xb - w) / 2, y_low + (ROW - VALUE_SIZE) / 2 + 1, string,
                              VALUE_SIZE)
    page.write(out, width, height)


def render(vcd_path, spec_path, out, start_spec=None, cycles=None, width=455.0):
    vcd = Vcd(open(vcd_path).read())
    rows = [(vcd.resolve(path), label, fmt, colour)
            for path, label, fmt, colour in parse_spec(open(spec_path).read())]
    clocks = [name for name, _, fmt, _ in rows if fmt in ("clock", "grid")]
    if len(clocks) != 1:
        sys.exit(f"{spec_path}: exactly one signal must have the format clock or grid, "
                 f"{len(clocks)} do")
    rows = [row for row in rows if row[2] != "grid"]
    edges = vcd.rising_edges(clocks[0])
    start = 0
    if start_spec:
        wanted = {vcd.resolve(item.split("=")[0]): int(item.split("=")[1], 16)
                  for item in start_spec.split(",")}
        start = vcd.trigger(wanted)
        if start is None:
            sys.exit(f"{vcd_path}: the --start values never hold together")
    end = vcd.end
    edges = [t for t in edges if t >= start]
    if cycles is not None:
        if len(edges) < 2:
            sys.exit(f"{vcd_path}: fewer than two clock edges after the start")
        end = start + cycles * (edges[1] - edges[0])
    edges = [t for t in edges if t < end]
    if end <= start:
        sys.exit(f"{vcd_path}: the window is empty")
    draw(vcd, rows, out, start, end, edges, width)
    unit = start * vcd.timescale_ps / 1000
    print(f"WAVE {out}: {len(rows)} signals from {unit:g} ns, {len(edges)} clock edges, "
          f"{(end - start) * vcd.timescale_ps / 1000:g} ns")


# ---- self-test -------------------------------------------------------------------------

SELFTEST_VCD = """\
$date today $end
$version Icarus Verilog $end
$timescale
\t1ps
$end
$scope module top $end
$var wire 1 ! clk $end
$scope module cpu $end
$var reg 3 " state [2:0] $end
$upscope $end
$var wire 8 # bus [7:0] $end
$upscope $end
$enddefinitions $end
#0
$dumpvars
0!
b101 "
bx #
$end
#5000
1!
b0 "
b1010 #
#10000
0!
#15000
1!
b1 "
b11111111 #
#20000
0!
"""


# A second VCD, for what the first cannot show: a 10 ns timescale, an x clock that becomes 1
# (no rising edge), two changes of one signal at one time, a value repeated, upper-case X,
# names that are suffixes or substrings of each other, and a trigger met at a time only its
# second signal changes.
SELFTEST_VCD_2 = """\
$timescale 10ns $end
$scope module top $end
$var wire 1 ! clk $end
$var wire 8 " abus [7:0] $end
$scope module cpu $end
$var reg 3 # state [2:0] $end
$var wire 8 $ bus [7:0] $end
$upscope $end
$scope module io $end
$var wire 8 % bus [7:0] $end
$upscope $end
$scope module xcpu $end
$var wire 8 & bus [7:0] $end
$upscope $end
$upscope $end
$enddefinitions $end
#0
X!
bXX "
b0 #
b0 $
b0 %
b0 &
#5
1!
b1 #
b0 #
#10
0!
#15
1!
b1 #
#20
0!
b0 #
#22
b11111111 $
#25
1!
b1 #
b1 #
"""


def selftest():
    vcd = Vcd(SELFTEST_VCD)
    assert vcd.timescale_ps == 1, vcd.timescale_ps
    assert sorted(vcd.signals) == ["top.bus", "top.clk", "top.cpu.state"], sorted(vcd.signals)
    assert vcd.signals["top.cpu.state"].width == 3
    assert vcd.changes("top.cpu.state") == [(0, "101"), (5000, "0"), (15000, "1")]
    assert vcd.changes("top.bus") == [(0, "x"), (5000, "1010"), (15000, "11111111")]
    assert vcd.changes("top.clk") == [(0, "0"), (5000, "1"), (10000, "0"), (15000, "1"),
                                      (20000, "0")]
    assert vcd.end == 20000
    assert vcd.resolve("cpu.state") == "top.cpu.state"
    assert vcd.resolve("state") == "top.cpu.state"
    for bad in ("top", "nothing"):
        try:
            vcd.resolve(bad)
        except KeyError:
            pass
        else:
            raise AssertionError(bad)
    assert vcd.rising_edges("top.clk") == [5000, 15000]
    assert vcd.value_at("top.cpu.state", 0) == "101"
    assert vcd.value_at("top.cpu.state", 7000) == "0"
    assert vcd.value_at("top.cpu.state", 15000) == "1"
    assert vcd.trigger({"top.cpu.state": 0}) == 5000
    assert vcd.trigger({"top.cpu.state": 1, "top.bus": 0xFF}) == 15000
    assert vcd.trigger({"top.cpu.state": 5}) == 0
    assert vcd.trigger({"top.cpu.state": 7}) is None
    assert format_value("1010", "hex") == "a"
    assert format_value("00000000", "hex") == "0"
    assert format_value("1010", "dec") == "10"
    assert format_value("x", "hex") == "x"
    assert format_value("1x", "hex") == "x"
    assert format_value("1", {1: "WAIT_INSTR"}) == "WAIT_INSTR"
    assert format_value("10", {1: "WAIT_INSTR"}) == "2"
    assert format_value("1010", {1: "WAIT_INSTR"}) == "10"
    spec = "cpu.control.state - 0=FETCH_INSTR,1=WAIT_INSTR 0072b2\n# c\n\nclk - clock\n"
    assert parse_spec(spec) == [
        ("cpu.control.state", "state", {0: "FETCH_INSTR", 1: "WAIT_INSTR"}, (0, 114, 178)),
        ("clk", "clk", "clock", None)]
    for bad in ("clk - clock 0072b2 extra\n", "clk clk\n"):
        try:
            parse_spec(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(bad)

    vcd = Vcd(SELFTEST_VCD_2)
    assert vcd.timescale_ps == 10000, vcd.timescale_ps
    assert vcd.changes("top.clk") == [(0, "x"), (5, "1"), (10, "0"), (15, "1"), (20, "0"),
                                      (25, "1")]
    assert vcd.rising_edges("top.clk") == [15, 25], vcd.rising_edges("top.clk")
    assert vcd.changes("top.abus") == [(0, "xx")]
    assert vcd.changes("top.cpu.state") == [(0, "0"), (15, "1"), (20, "0"), (25, "1")]
    assert vcd.trigger({"top.cpu.state": 1}) == 15
    assert vcd.trigger({"top.cpu.state": 0, "top.cpu.bus": 0xFF}) == 22
    assert vcd.resolve("cpu.bus") == "top.cpu.bus"
    assert vcd.resolve("abus") == "top.abus"
    try:
        vcd.resolve("bus")
    except KeyError:
        pass
    else:
        raise AssertionError("bus")
    print("PASS: vcd_wave selftest")


def main():
    args = sys.argv[1:]
    if args == ["--selftest"]:
        selftest()
        return
    options = {"--start": None, "--cycles": None, "--width": "455"}
    positional = []
    while args:
        arg = args.pop(0)
        if arg in options:
            if not args:
                sys.exit(f"{arg} needs a value")
            options[arg] = args.pop(0)
        else:
            positional.append(arg)
    if len(positional) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    render(*positional, start_spec=options["--start"],
           cycles=None if options["--cycles"] is None else int(options["--cycles"]),
           width=float(options["--width"]))


if __name__ == "__main__":
    main()
