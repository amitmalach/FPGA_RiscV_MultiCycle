#!/usr/bin/env python3
"""Render the board captures as figures for the final report, and print the numbers it quotes.

    docs/design/scripts/board_figures.py <captures_dir> <figures_dir>
    (make figures runs it as board_figures.py captures figures, in docs/design/)

Reads the captures that board_capture.sh recorded, <demo>_<boot>.bin and .times, and writes:

    board_mandelbrot.pdf      mandelbrot's first frame, BRAM boot
    board_riscv_logo.pdf      riscv_logo's first 64 frames, one rotation, a page each, BRAM boot
    board_riscv_logo.gif      the same frames for the README, each shown as long as it took
    board_tinyraytracer.pdf   tinyraytracer's picture, flash boot: the last complete run in the
                              capture, which starts when CPU RESET is pressed after the load

It prints BOARD lines with the measurements chapter 11 quotes, sieve's included, and exits 1
unless mandelbrot's first frame is byte for byte the UART bytes of the golden trace,
sim/golden/mandelbrot_bram.txt, every sieve round captured ends in its checksum's OK, and the
tinyraytracer capture holds a complete run.
The PDFs are vector drawings; no figure records a date, so unchanged captures regenerate
byte-identical figures. Needs Pillow.

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

Anything else is an error, a printable glyph included: Terminal draws no font. A frame is what
mandelbrot or riscv_logo sends from one ESC [ H to the next, which is how both redraw the
screen. A terminal cell is twice as tall as it is wide, so their pixel, two cells, is square;
tinyraytracer's pixel is one cell. tinyraytracer ends with a line of text below its picture,
which is checked and not drawn.
"""
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


# ---- captures ----------------------------------------------------------------

class Capture:
    """A capture: its bytes, the host time each arrived, and design_start, the offset of the
    loaded design's first byte."""

    def __init__(self, base):
        self.name = os.path.basename(base)
        with open(base + ".bin", "rb") as f:
            self.data = f.read()
        self.reads = []     # (time, offset of the read's first byte)
        offset = 0
        for line in open(base + ".times"):
            fields = line.split()
            if fields[0] == "PROGRAM_START":
                program_start = float(fields[1])
            elif fields[0] == "PROGRAM_END":
                program_end = float(fields[1])
            elif fields[0] == "READ":
                self.reads.append((float(fields[1]), offset))
                offset += int(fields[2])
        if offset != len(self.data):
            sys.exit(f"{base}.times counts {offset} bytes, {base}.bin holds {len(self.data)}")
        self.design_start = self._design_start(program_start, program_end)

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
    """The screen a terminal shows, as background colours: what the demos send, nothing more."""

    def __init__(self):
        self.cells = {}
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
                i += 1
            elif data[i] == 0x20:
                self.cells[self.row, self.col] = self.bg
                self.col += 1
                i += 1
            else:
                raise ValueError(f"unsupported byte {data[i]:#04x}: Terminal draws no glyphs")

    def _csi(self, params, final):
        if final == b"H":
            row, col = (int(p) for p in params.split(b";")) if params else (1, 1)
            self.row, self.col = row - 1, col - 1
        elif final == b"J" and params == b"2":
            self.cells, self.blank = {}, self.bg
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

    def screen(self):
        """The screen as rows of colours, as far as the demo has drawn."""
        rows = 1 + max(r for r, _ in self.cells)
        cols = 1 + max(c for _, c in self.cells)
        return [[self.cells.get((r, c), self.blank) for c in range(cols)] for r in range(rows)]


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
    write_pdf(os.path.join(figures, "board_mandelbrot.pdf"), screens(capture, [(start, end)]))


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


def sieve(captures):
    capture = Capture(os.path.join(captures, "sieve_bram"))
    data = capture.data[capture.design_start:]
    verdicts = re.findall(rb"checksum:\n   [0-9A-F]{8} (OK|ERROR)\n", data)
    starts = [capture.design_start + m.start() for m in re.finditer(rb" 1st prime: 2\n", data)]
    if not verdicts or verdicts.count(b"OK") != len(verdicts):
        sys.exit(f"BOARD sieve: {verdicts.count(b'OK')} of {len(verdicts)} checksums OK")
    period = (capture.time(starts[-1]) - capture.time(starts[0])) / (len(starts) - 1)
    print(f"BOARD sieve: {len(verdicts)} complete rounds in {capture.name}.bin, every checksum OK, "
          f"a round every {1e3 * period:.0f} ms")


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
    terminal = Terminal()
    terminal.feed(capture.data[start:end.start()])
    screen = terminal.screen()
    took = capture.time(end.start()) - capture.time(start)
    print(f"BOARD tinyraytracer: the last complete run is bytes {start} to {end.end() - 1} of "
          f"{capture.name}.bin, {end.end() - start} bytes; the picture, {len(screen[0])} by "
          f"{len(screen)} cells, took {took:.1f} s from the run's first byte to the closing text, "
          f"{1e3 * took / (len(screen[0]) * len(screen)):.0f} ms a pixel")
    write_pdf(os.path.join(figures, "board_tinyraytracer.pdf"), [screen])


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    captures, figures = sys.argv[1:]
    mandelbrot(captures, figures)
    riscv_logo(captures, figures)
    sieve(captures)
    tinyraytracer(captures, figures)


if __name__ == "__main__":
    main()
