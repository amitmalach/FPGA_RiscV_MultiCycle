#!/usr/bin/env python3
"""Render the board captures as figures for the final report, and print the numbers it quotes.

    docs/design/scripts/board_figures.py <captures_dir> <figures_dir>
    (make figures runs it as board_figures.py captures figures, in docs/design/)

Reads the captures that board_capture.sh recorded, <demo>_<boot>.bin and .times, and writes:

    board_mandelbrot.pdf      mandelbrot's complete frames, a page each, BRAM boot: the colours
                              step by one each frame, and page 1 is the frame the report checks
    board_mandelbrot.gif      the same frames for the README, each shown as long as it took
    board_riscv_logo.pdf      riscv_logo's first 64 frames, one rotation, a page each, BRAM boot
    board_riscv_logo.gif      the same frames for the README, each shown as long as it took
    board_tinyraytracer.pdf   tinyraytracer's picture after each of its rows, a page each, flash
                              boot: the last complete run in the capture, which starts when
                              CPU RESET is pressed after the load
    board_tinyraytracer.gif   the same pages for the README, RAYTRACER_SPEEDUP times faster
    board_sieve.tex           sieve's text screens, a terminal SIEVE_ROWS rows high after
                              SIEVE_LINES lines of the first round, as LaTeX macros
    board_sieve.gif           the first two rounds for the README, a frame a line, in DejaVu
                              Sans Mono, SIEVE_SLOWDOWN times slower than the board sent them
    board_st_niccc.pdf        ST_NICCC's screen at NICCC_FIGURE seconds, a page each, BRAM boot
                              with the scene data in the flash
    board_st_niccc.gif        its screen every NICCC_STEP seconds for the README, in real time

It prints BOARD lines with the measurements chapter 1 quotes, and exits 1 unless mandelbrot's
first frame is byte for byte the UART bytes of the golden trace, sim/golden/mandelbrot_bram.txt,
every sieve round captured ends in its checksum's OK, the tinyraytracer capture holds a complete
run, and ST_NICCC's output begins with its greeting.
The PDFs are vector drawings, and no figure records a date, so unchanged captures regenerate
byte-identical figures. Needs Pillow, and FONT for the sieve GIF.

The demos draw with ANSI escape sequences, every pixel two spaces on a coloured background.
Terminal replays what they send:

    ESC [ H               cursor to the top left corner
    ESC [ <r> ; <c> H     cursor to row <r>, column <c>, both counted from 1
    ESC [ 2 J             erase the screen to the current background
    ESC [ <p> ; ... m     background colour (SGR): 0 and 49 the default, black; 40-47 and
                          100-107 the 16 colours, in xterm's palette; 48;5;<n> xterm's 256
                          colours; 48;2;<r>;<g>;<b> 24-bit colour
    LF                    the next line's first column: the firmware sends no CR, and the
                          terminal maps LF to CR LF (picocom --imap lfcrlf)
    space                 one cell in the current background

A printable character takes a cell as a space does, and Terminal keeps it as a glyph, which
only the text writers draw. Anything else is an error. A frame is what mandelbrot or riscv_logo
sends from one ESC [ H to the next, which is how both redraw the screen. A row or column of 0
in ESC [ <r> ; <c> H is the first, as in xterm: ST_NICCC sends both. A terminal cell is twice
as tall as it is wide, so their pixel, two cells, is square; tinyraytracer's and ST_NICCC's
pixel is one cell. tinyraytracer ends with a line of text below its picture,
which is checked and not drawn.
"""
import bisect
import os
import re
import sys
import zlib

from PIL import Image

sys.dont_write_bytecode = True    # no __pycache__/ beside the sources (lint rule 1)
from pdf_objects import write_pdf_objects

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
GOLDEN = os.path.join(ROOT, "sim", "golden", "mandelbrot_bram.txt")
DEFINES = os.path.join(ROOT, "rtl", "defines.vh")

HOME = b"\x1b[H"
CSI = re.compile(rb"\x1b\[([0-9;]*)([A-Za-z])")
BLACK = (0, 0, 0)
# xterm's 16 colours: SGR 40-47 select the first eight as background, 100-107 the bright ones.
XTERM = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205),
         (0, 205, 205), (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0),
         (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
LOGO_FRAMES = 64    # riscv_logo turns once in 64 frames: its sine table has 64 entries
# tinyraytracer's graphics_init(): black background, screen erased; and graphics_terminate():
# cursor below the picture, colours reset, a line of text.
RAYTRACER_START = b"\x1b[48;5;16m\x1b[2J"
RAYTRACER_END = re.compile(rb"\x1b\[\d+;1H\x1b\[0m\nDone\.\n")
RAYTRACER_ROWS, RAYTRACER_COLS = 24, 48    # graphics_height and graphics_width
RAYTRACER_SPEEDUP = 20                     # the GIF plays the picture's drawing this much faster
# sieve prints text: its figure is a terminal of SIEVE_ROWS rows, after each of SIEVE_LINES
# lines of the first round (a round is 31 primes and two lines of checksum), and its GIF plays
# the first two rounds line by line, SIEVE_SLOWDOWN times slower than the board sent them.
SIEVE_ROWS, SIEVE_COLS = 12, 16
SIEVE_LINES = (6, 12, 18, 24, 33)
SIEVE_SLOWDOWN = 50
BAUD = 115200
# ST_NICCC draws each frame's polygons over the last one and marks no frame in its output: its
# figure is the screen, NICCC_ROWS by NICCC_COLS cells, at NICCC_FIGURE seconds after its first
# byte, and its GIF the screen every NICCC_STEP seconds, in real time, from NICCC_GIF_FROM on.
NICCC_ROWS, NICCC_COLS = 50, 128     # the scene's 256 by 200 points, x halved and y quartered
NICCC_FIGURE = (76, 97, 118, 139, 145)
NICCC_STEP = 0.5
NICCC_GIF_FROM = 70
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"


# ---- captures ----------------------------------------------------------------

class Capture:
    """A capture: its bytes, the host time each arrived, the JTAG load's start and end
    (program_start, program_end), and design_start, the offset of the loaded design's first
    byte."""

    def __init__(self, base):
        self.name = os.path.basename(base)
        with open(base + ".bin", "rb") as f:
            self.data = f.read()
        self.reads = []     # (time, offset of the read's first byte)
        offset = 0
        for line in open(base + ".times"):
            fields = line.split()
            if fields[0] == "PROGRAM_START":
                self.program_start = float(fields[1])
            elif fields[0] == "PROGRAM_END":
                self.program_end = float(fields[1])
            elif fields[0] == "READ":
                self.reads.append((float(fields[1]), offset))
                offset += int(fields[2])
        if offset != len(self.data):
            sys.exit(f"{base}.times counts {offset} bytes, {base}.bin holds {len(self.data)}")
        self.design_start = self._design_start(self.program_start, self.program_end)

    def _design_start(self, program_start, program_end):
        # While the FPGA is configured it runs nothing, for seconds: the longest silence on
        # the UART during the JTAG load. Before it, the previous design was writing.
        silence, start, last = -1.0, None, program_start
        for t, offset in self.reads:
            if t - last > silence:
                silence, start = t - last, offset
            if t > program_end:
                break
            last = t
        if start is None:
            sys.exit(f"{self.name}: no bytes after the JTAG load")
        return start

    def time(self, offset):
        """Host time of the read that brought byte <offset>."""
        lo, hi = 0, len(self.reads) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.reads[mid][1] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return self.reads[lo][0]

    def frames(self):
        """Byte ranges of the loaded design's complete frames: each ends where the next begins."""
        starts = [m.start() for m in re.finditer(re.escape(HOME), self.data)
                  if m.start() >= self.design_start]
        if not starts or starts[0] != self.design_start:
            sys.exit(f"{self.name}: the loaded design's output does not begin with ESC [ H")
        return list(zip(starts, starts[1:]))


# ---- terminal ----------------------------------------------------------------

class Terminal:
    """The screen a terminal shows: each cell's background colour and the glyph printed in it,
    if any. Without <rows> the screen grows downwards as far as the demo writes; with it, a line
    feed on the last row scrolls the screen up by one row, as a terminal of that height does."""

    def __init__(self, rows=None):
        self.cells = {}
        self.glyphs = {}
        self.rows = rows
        self.row = self.col = 0
        self.bg = self.blank = BLACK

    def feed(self, data):
        i = 0
        while i < len(data):
            if data[i] == 0x1B:
                m = CSI.match(data, i)
                if not m:
                    raise ValueError(f"unsupported escape sequence {data[i:i + 12]!r}")
                self._csi(m.group(1), m.group(2))
                i = m.end()
            elif data[i] == 0x0A:
                self.row, self.col = self.row + 1, 0
                if self.rows is not None and self.row == self.rows:
                    self._scroll()
                i += 1
            elif 0x20 <= data[i] <= 0x7E:
                self.cells[self.row, self.col] = self.bg
                if data[i] == 0x20:
                    self.glyphs.pop((self.row, self.col), None)
                else:
                    self.glyphs[self.row, self.col] = chr(data[i])
                self.col += 1
                i += 1
            else:
                raise ValueError(f"unsupported byte {data[i]:#04x}")

    def _scroll(self):
        self.row -= 1
        self.cells = {(r - 1, c): v for (r, c), v in self.cells.items() if r > 0}
        self.glyphs = {(r - 1, c): v for (r, c), v in self.glyphs.items() if r > 0}

    def _csi(self, params, final):
        if final == b"H":
            # A row or column of 0, or none, is the first, as in xterm.
            row, col = ((max(1, int(p or 1)) for p in params.split(b";")) if params
                        else (1, 1))
            self.row, self.col = row - 1, col - 1
        elif final == b"J" and params == b"2":
            self.cells, self.glyphs, self.blank = {}, {}, self.bg
        elif final == b"m":
            self._sgr([int(p) for p in params.split(b";")])
        else:
            raise ValueError(f"unsupported escape sequence ESC [ {(params + final).decode()}")

    def _sgr(self, params):
        if params in ([0], [49]):
            self.bg = BLACK
        elif len(params) == 1 and (40 <= params[0] <= 47 or 100 <= params[0] <= 107):
            self.bg = XTERM[params[0] - 40 if params[0] < 100 else params[0] - 92]
        elif len(params) == 3 and params[:2] == [48, 5]:
            self.bg = xterm256(params[2])
        elif len(params) == 5 and params[:2] == [48, 2]:
            self.bg = tuple(params[2:])
        else:
            raise ValueError(f"unsupported SGR {params}")

    def screen(self, rows=None, cols=None):
        """The screen as rows of colours: <rows> by <cols>, or as far as the demo has drawn."""
        rows = rows or 1 + max(r for r, _ in self.cells)
        cols = cols or 1 + max(c for _, c in self.cells)
        return [[self.cells.get((r, c), self.blank) for c in range(cols)] for r in range(rows)]

    def text(self, rows, cols):
        """The screen's glyphs as <rows> strings of <cols> characters, a space where none is."""
        return ["".join(self.glyphs.get((r, c), " ") for c in range(cols)) for r in range(rows)]


def xterm256(n):
    """xterm's 256-colour palette: the 16 colours, a 6 by 6 by 6 colour cube, 24 greys."""
    if n < 16:
        return XTERM[n]
    if n < 232:
        level = [0, 95, 135, 175, 215, 255]
        return (level[(n - 16) // 36], level[(n - 16) // 6 % 6], level[(n - 16) % 6])
    return (8 + 10 * (n - 232),) * 3


def screens(capture, frames):
    """The screen after each frame, replayed in order from the loaded design's first byte."""
    terminal = Terminal()
    for start, end in frames:
        terminal.feed(capture.data[start:end])
        yield terminal.screen()


# ---- writers -----------------------------------------------------------------

def runs(row):
    """(first column, width, colour) of each run of one colour in a row."""
    out, first = [], 0
    for c in range(1, len(row) + 1):
        if c == len(row) or row[c] != row[first]:
            out.append((first, c - first, row[first]))
            first = c
    return out


def write_pdf(path, pages, cell_w=4.0):
    """A PDF with one page per screen, each cell a rectangle cell_w points wide and twice as tall.
    Each rectangle reaches a quarter cell into its right and lower neighbours, which are drawn
    after it: rectangles that only touched would leave hairline seams in most viewers."""
    cell_h, over = 2 * cell_w, cell_w / 4
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", None]
    kids = []
    for screen in pages:
        width, height = len(screen[0]) * cell_w, len(screen) * cell_h
        ops, colour = [], None
        for r, row in enumerate(screen):
            for c, n, rgb in runs(row):
                if rgb != colour:
                    ops.append("%.4g %.4g %.4g rg" % tuple(v / 255 for v in rgb))
                    colour = rgb
                ops.append("%g %g %g %g re f" % (c * cell_w, height - (r + 1) * cell_h - over,
                                                 n * cell_w + over, cell_h + over))
        stream = zlib.compress("\n".join(ops).encode(), 9)
        kids.append(f"{len(objects) + 1} 0 R")
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width:g} {height:g}] "
                       f"/Resources << >> /Contents {len(objects) + 2} 0 R >>".encode())
        objects.append(f"<< /Length {len(stream)} /Filter /FlateDecode >>\nstream\n".encode()
                       + stream + b"\nendstream")
    objects[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(kids)} >>".encode()

    write_pdf_objects(path, objects)


def write_gif(path, pages, durations_ms, cell_px=4):
    """An animated GIF, each cell cell_px pixels wide and twice as tall, looping forever."""
    colours = sorted({rgb for screen in pages for row in screen for rgb in row})
    index = {rgb: i for i, rgb in enumerate(colours)}
    images = []
    for screen in pages:
        image = Image.new("P", (len(screen[0]), len(screen)))
        image.putpalette([v for rgb in colours for v in rgb])
        image.putdata([index[rgb] for row in screen for rgb in row])
        images.append(image.resize((image.width * cell_px, image.height * 2 * cell_px),
                                   Image.NEAREST))
    images[0].save(path, save_all=True, append_images=images[1:], duration=durations_ms,
                   loop=0, optimize=False)


def tex_line(line):
    """A line of the screen as LaTeX for a typewriter font: a space is ~, which there is as
    wide as a glyph, and the characters TeX treats specially are escaped."""
    special = {"~": r"\textasciitilde{}", "^": r"\textasciicircum{}", "\\": r"\textbackslash{}",
               " ": "~"}
    return "".join(special.get(ch, "\\" + ch if ch in "#$%&_{}" else ch) for ch in line)


def write_text_tex(path, name, frames, what):
    """LaTeX macros \\<name>i, \\<name>ii, ...: each frame's lines, separated by \\\\ for a
    one-column tabular in a typewriter font."""
    out = [f"% Generated by docs/design/scripts/board_figures.py; do not edit.",
           f"% {what}."]
    for i, frame in enumerate(frames, 1):
        roman = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"][i - 1]
        body = " \\\\\n  ".join(tex_line(line) for line in frame)
        out.append(f"\\newcommand{{\\{name}{roman}}}{{%\n  {body}}}")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")


def write_text_gif(path, frames, durations_ms, cell_px=(8, 16)):
    """An animated GIF of text screens: each glyph in xterm's white on black, in DejaVu Sans
    Mono, a cell cell_px pixels wide and high, looping forever."""
    from PIL import ImageDraw, ImageFont
    font = ImageFont.truetype(FONT, 13)
    w, h = cell_px
    images = []
    for lines in frames:
        image = Image.new("L", (w * len(lines[0]), h * len(lines)), 0)
        draw = ImageDraw.Draw(image)
        for r, line in enumerate(lines):
            draw.text((0, r * h + 1), line, fill=229, font=font)
        images.append(image)
    images[0].save(path, save_all=True, append_images=images[1:], duration=durations_ms,
                   loop=0, optimize=False)


# ---- figures -----------------------------------------------------------------

def golden():
    """The UART bytes of the golden trace, and the cycles it simulated."""
    data, cycles = bytearray(), None
    for line in open(GOLDEN):
        if line.startswith("UART "):
            data.append(int(line.split()[1], 16))
        elif line.startswith("END "):
            cycles = int(re.search(r"cycles=(\d+)", line).group(1))
    return bytes(data), cycles


def clock_hz():
    return int(re.search(r"^`define\s+CLK_HZ\s+(\d+)", open(DEFINES).read(), re.M).group(1))


def mandelbrot(captures, figures):
    capture = Capture(os.path.join(captures, "mandelbrot_bram"))
    frames = capture.frames()
    if len(frames) < 2:
        sys.exit(f"BOARD mandelbrot: {len(frames)} complete frames, want 2")
    (start, end), (next_start, _) = frames[:2]
    frame = capture.data[start:end]
    golden_bytes, cycles = golden()
    rel = os.path.relpath(GOLDEN, ROOT)
    if frame != golden_bytes:
        differ = next((i for i, (a, b) in enumerate(zip(frame, golden_bytes)) if a != b),
                      min(len(frame), len(golden_bytes)))
        sys.exit(f"BOARD mandelbrot: frame 0 ({len(frame)} bytes) differs from the UART bytes "
                 f"of {rel} ({len(golden_bytes)} bytes) at byte {differ}")
    print(f"BOARD mandelbrot: frame 0, bytes {start} to {end - 1} of {capture.name}.bin, "
          f"is the {len(frame)} UART bytes of {rel}, byte for byte")
    measured = capture.time(next_start) - capture.time(start)
    print(f"BOARD mandelbrot: frame 0 took {1e3 * measured:.1f} ms, first byte to the next "
          f"frame's first byte; simulated: {cycles} cycles at {clock_hz() // 10**6} MHz = "
          f"{1e3 * cycles / clock_hz():.2f} ms")
    # Every complete frame, a page each; the last frame ends where the incomplete one begins.
    times = [capture.time(s) for s, _ in frames] + [capture.time(frames[-1][1])]
    durations = [round(1e3 * (b - a)) for a, b in zip(times, times[1:])]
    print(f"BOARD mandelbrot: {len(frames)} complete frames in {capture.name}.bin, "
          f"{min(durations)} to {max(durations)} ms each")
    pages = list(screens(capture, frames))
    write_pdf(os.path.join(figures, "board_mandelbrot.pdf"), pages)
    write_gif(os.path.join(figures, "board_mandelbrot.gif"), pages,
              [10 * round(d / 10) for d in durations])


def riscv_logo(captures, figures):
    capture = Capture(os.path.join(captures, "riscv_logo_bram"))
    frames = capture.frames()
    if len(frames) < LOGO_FRAMES + 1:
        sys.exit(f"BOARD riscv_logo: {len(frames)} complete frames, want {LOGO_FRAMES + 1}")
    times = [capture.time(start) for start, _ in frames[:LOGO_FRAMES + 1]]
    durations = [round(1e3 * (b - a)) for a, b in zip(times, times[1:])]
    sizes = [end - start for start, end in frames[:LOGO_FRAMES]]
    rotation = times[-1] - times[0]
    print(f"BOARD riscv_logo: the loaded design's output begins at byte {capture.design_start} of "
          f"{capture.name}.bin, with {len(frames)} complete frames; frames 0 to {LOGO_FRAMES - 1}, "
          f"one rotation, took {rotation:.2f} s, {1e3 * rotation / LOGO_FRAMES:.0f} ms a frame "
          f"({min(durations)} to {max(durations)} ms, {min(sizes)} to {max(sizes)} bytes), "
          f"{LOGO_FRAMES / rotation:.2f} frames/s")
    pages = list(screens(capture, frames[:LOGO_FRAMES]))
    write_pdf(os.path.join(figures, "board_riscv_logo.pdf"), pages)
    # A GIF counts time in hundredths of a second.
    write_gif(os.path.join(figures, "board_riscv_logo.gif"), pages,
              [10 * round(d / 10) for d in durations])


def sieve(captures, figures):
    capture = Capture(os.path.join(captures, "sieve_bram"))
    data = capture.data[capture.design_start:]
    verdicts = re.findall(rb"checksum:\n   [0-9A-F]{8} (OK|ERROR)\n", data)
    starts = [capture.design_start + m.start() for m in re.finditer(rb" 1st prime: 2\n", data)]
    if not verdicts or verdicts.count(b"OK") != len(verdicts):
        sys.exit(f"BOARD sieve: {verdicts.count(b'OK')} of {len(verdicts)} checksums OK")
    if len(starts) < 3 or starts[0] != capture.design_start:
        sys.exit(f"BOARD sieve: want the loaded design's output to begin with a round, and two "
                 f"complete rounds")
    period = (capture.time(starts[-1]) - capture.time(starts[0])) / (len(starts) - 1)
    print(f"BOARD sieve: {len(verdicts)} complete rounds in {capture.name}.bin, every checksum OK, "
          f"a round every {1e3 * period:.0f} ms")
    # The screen after each line of the first two rounds.
    ends = [starts[0] + m.end() for m in re.finditer(rb"\n", capture.data[starts[0]:starts[2]])]
    terminal, last, texts = Terminal(rows=SIEVE_ROWS), starts[0], []
    for end in ends:
        terminal.feed(capture.data[last:end])
        texts.append(terminal.text(SIEVE_ROWS, SIEVE_COLS))
        last = end
    # Each frame lasts until the next line has arrived: its bytes at the baud rate, ten bits
    # each, or the time measured between the two lines when that is longer by more than the
    # timestamps' accuracy, which is the pause between rounds.
    durations = []
    for a, b in zip(ends, ends[1:] + [starts[2] + (ends[0] - starts[0])]):
        sent = 10 * (b - a) / BAUD
        measured = capture.time(b - 1) - capture.time(a - 1)
        durations.append(measured if measured - sent > 0.005 else sent)
    round_ms = 1e3 * sum(10 * (b - a) for a, b in zip([starts[0]] + ends, ends)
                         if b <= starts[1]) / BAUD
    shown = [1e3 * (capture.time(ends[n - 1] - 1) - capture.time(starts[0])) for n in SIEVE_LINES]
    print(f"BOARD sieve: a round is {starts[1] - starts[0]} bytes, {round_ms:.0f} ms at {BAUD} "
          f"baud; the figure shows the screen after lines {', '.join(map(str, SIEVE_LINES))}, "
          f"{', '.join(f'{t:.0f}' for t in shown)} ms after the round's first byte")
    write_text_tex(os.path.join(figures, "board_sieve.tex"), "sieveframe",
                   [texts[n - 1] for n in SIEVE_LINES], f"{capture.name}: the screen of a "
                   f"terminal {SIEVE_ROWS} rows high after lines "
                   f"{', '.join(map(str, SIEVE_LINES))} of the first round")
    write_text_gif(os.path.join(figures, "board_sieve.gif"), texts,
                   [max(20, 10 * round(SIEVE_SLOWDOWN * 100 * d)) for d in durations])


def tinyraytracer(captures, figures):
    capture = Capture(os.path.join(captures, "tinyraytracer_flash"))
    ends = list(RAYTRACER_END.finditer(capture.data, capture.design_start))
    if not ends:
        sys.exit(f"BOARD tinyraytracer: no run in {capture.name}.bin reaches graphics_terminate()'s "
                 f"text; was CPU RESET pressed after the load, and the capture long enough?")
    end = ends[-1]
    start = capture.data.rfind(RAYTRACER_START, capture.design_start, end.start())
    if start < 0:
        sys.exit(f"BOARD tinyraytracer: the run that ends at byte {end.start()} has no start")
    # The picture is drawn a row at a time, top to bottom, and each row a pixel at a time: a row
    # ends where the next one's first pixel, ESC [ <row> ; 1 H, begins.
    run = capture.data[start:end.start()]
    ends = [start + run.index(b"\x1b[%d;1H" % (r + 2)) for r in range(RAYTRACER_ROWS - 1)]
    ends.append(end.start())
    terminal, last, pages = Terminal(), start, []
    for e in ends:
        terminal.feed(capture.data[last:e])
        pages.append(terminal.screen(RAYTRACER_ROWS, RAYTRACER_COLS))
        last = e
    times = [capture.time(e - 1) - capture.time(start) for e in ends]
    took = capture.time(end.start()) - capture.time(start)
    print(f"BOARD tinyraytracer: the last complete run is bytes {start} to {end.end() - 1} of "
          f"{capture.name}.bin, {end.end() - start} bytes; the picture, {RAYTRACER_COLS} by "
          f"{RAYTRACER_ROWS} cells, took {took:.1f} s from the run's first byte to the closing "
          f"text, {1e3 * took / (RAYTRACER_COLS * RAYTRACER_ROWS):.0f} ms a pixel; rows 6, 12, "
          f"18 and 24 were done after "
          f"{', '.join(f'{times[r - 1]:.0f}' for r in (6, 12, 18, 24))} s")
    write_pdf(os.path.join(figures, "board_tinyraytracer.pdf"), pages)
    # A time-lapse: each row shown RAYTRACER_SPEEDUP times faster than it was drawn, and the
    # finished picture for three seconds.
    rows = [b - a for a, b in zip([0.0] + times, times)]
    write_gif(os.path.join(figures, "board_tinyraytracer.gif"), pages,
              [10 * round(100 * r / RAYTRACER_SPEEDUP) for r in rows[1:]] + [3000],
              cell_px=6)


def st_niccc(captures, figures):
    capture = Capture(os.path.join(captures, "ST_NICCC_bram"))
    data, first = capture.data, capture.design_start
    if not data.startswith(b"starting\n", first):
        sys.exit(f"BOARD ST_NICCC: the loaded design's output does not begin with its greeting")
    t0 = capture.time(first)
    end_time = capture.time(len(data) - 1) - t0

    def cut(seconds):
        # The offset of the first escape sequence the board sent after <seconds>.
        k = bisect.bisect_left([t for t, _ in capture.reads], t0 + seconds)
        offset = capture.reads[k][1] if k < len(capture.reads) else len(data)
        return data.find(b"\x1b", offset) if data.find(b"\x1b", offset) >= 0 else len(data)

    times = sorted(set(NICCC_FIGURE) | {NICCC_GIF_FROM + NICCC_STEP * i for i in
                   range(int((end_time - NICCC_GIF_FROM) / NICCC_STEP) + 1)})
    terminal, last, shots = Terminal(), first, {}
    for t in times:
        offset = cut(t)
        terminal.feed(data[last:offset])
        shots[t] = terminal.screen(NICCC_ROWS, NICCC_COLS)
        last = offset
    print(f"BOARD ST_NICCC: {len(data) - first} bytes in {end_time:.1f} s from its first byte, "
          f"{(len(data) - first) / end_time / 1e3:.1f} kB/s; the figure shows the screen at "
          f"{', '.join(map(str, NICCC_FIGURE))} s")
    write_pdf(os.path.join(figures, "board_st_niccc.pdf"), [shots[t] for t in NICCC_FIGURE],
              cell_w=2.0)
    gif = [shots[t] for t in times if t >= NICCC_GIF_FROM and t not in NICCC_FIGURE
           or t in NICCC_FIGURE and (t - NICCC_GIF_FROM) % NICCC_STEP == 0]
    write_gif(os.path.join(figures, "board_st_niccc.gif"), gif,
              [int(1e3 * NICCC_STEP)] * len(gif), cell_px=2)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    captures, figures = sys.argv[1:]
    mandelbrot(captures, figures)
    riscv_logo(captures, figures)
    sieve(captures, figures)
    tinyraytracer(captures, figures)
    st_niccc(captures, figures)


if __name__ == "__main__":
    main()
