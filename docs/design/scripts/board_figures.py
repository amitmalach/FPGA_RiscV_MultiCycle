#!/usr/bin/env python3
"""Render the board captures as figures for the final report, and print the numbers it quotes.

    docs/design/scripts/board_figures.py <captures_dir> <figures_dir>
    (make figures runs it as board_figures.py captures figures, in docs/design/)

Reads the captures that board_capture.sh recorded, <demo>_bram.bin and .times, and writes:

    board_mandelbrot.pdf   mandelbrot's first frame
    board_riscv_logo.pdf   riscv_logo's first 64 frames, one rotation, a page each
    board_riscv_logo.gif   the same frames for the README, each shown as long as it took

It prints BOARD lines with the measurements chapter 11 quotes, and exits 1 unless mandelbrot's
first frame is byte for byte the UART bytes of the golden trace, sim/golden/mandelbrot_bram.txt.
The PDFs are vector drawings; no figure records a date, so unchanged captures regenerate
byte-identical figures. Needs Pillow.

The demos draw with ANSI escape sequences, every pixel two spaces on a coloured background.
Terminal replays what they send:

    ESC [ H               cursor to the top left corner
    ESC [ <p> ; ... m     background colour (SGR): 49 the default, black; 40-47 and 100-107
                          the 16 colours, in xterm's palette; 48;2;<r>;<g>;<b> 24-bit colour
    LF                    the next line's first column: the firmware sends no CR, and the
                          terminal maps LF to CR LF (picocom --imap lfcrlf)
    space                 one cell in the current background

Anything else is an error, a printable glyph included: Terminal draws no font. A frame is what
a demo sends from one ESC [ H to the next, which is how both demos redraw the screen. A
terminal cell is twice as tall as it is wide, so a demo's pixel, two cells, is square.
"""
import os
import re
import sys
import zlib

from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
GOLDEN = os.path.join(ROOT, "sim", "golden", "mandelbrot_bram.txt")
DEFINES = os.path.join(ROOT, "rtl", "defines.vh")

HOME = b"\x1b[H"
BLACK = (0, 0, 0)
# xterm's 16 colours: SGR 40-47 select the first eight as background, 100-107 the bright ones.
XTERM = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205),
         (0, 205, 205), (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0),
         (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
LOGO_FRAMES = 64    # riscv_logo turns once in 64 frames: its sine table has 64 entries


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
        self.bg = BLACK

    def feed(self, data):
        i = 0
        while i < len(data):
            if data.startswith(HOME, i):
                self.row = self.col = 0
                i += len(HOME)
            elif data.startswith(b"\x1b[", i):
                m = re.compile(rb"\x1b\[([0-9;]*)m").match(data, i)
                if not m:
                    raise ValueError(f"unsupported escape sequence {data[i:i + 12]!r}")
                self._sgr([int(p) for p in m.group(1).split(b";")])
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

    def _sgr(self, params):
        if params == [49]:
            self.bg = BLACK
        elif len(params) == 1 and (40 <= params[0] <= 47 or 100 <= params[0] <= 107):
            self.bg = XTERM[params[0] - 40 if params[0] < 100 else params[0] - 92]
        elif len(params) == 5 and params[:2] == [48, 2]:
            self.bg = tuple(params[2:])
        else:
            raise ValueError(f"unsupported SGR {params}")

    def screen(self):
        """The screen as rows of colours, as far as the demo has drawn."""
        rows = 1 + max(r for r, _ in self.cells)
        cols = 1 + max(c for _, c in self.cells)
        return [[self.cells.get((r, c), BLACK) for c in range(cols)] for r in range(rows)]


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

    pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf += f"{number} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(pdf)
    pdf += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    pdf += b"".join(f"{o:010d} 00000 n \n".encode() for o in offsets)
    pdf += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    with open(path, "wb") as f:
        f.write(pdf)


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


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    captures, figures = sys.argv[1:]
    mandelbrot(captures, figures)
    riscv_logo(captures, figures)


if __name__ == "__main__":
    main()
