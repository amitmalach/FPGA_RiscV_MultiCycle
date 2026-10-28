#!/usr/bin/env python3
"""Write the excerpts of the C-to-board flow figure of the final report (chapter 8).

    docs/design/scripts/flow_excerpts.py <flow_dir> <captures_dir> <out.tex>
    (make flow runs it as flow_excerpts.py build/flow captures figures/flow_excerpts.tex,
    in docs/design/, after building what it reads)

The figure follows one line of mandelbrot, IO_OUT(IO_LEDS,frame), the frame counter going to
the LEDs, from fw/mandelbrot.c to the board in BRAM boot, and the first instruction of the
flash build from its ELF to the flash in flash boot. Reads, from <flow_dir>:

    fw/mandelbrot.s                 the assembly, make -C fw <BUILD>/mandelbrot.s
    fw/mandelbrot.bram.elf          the BRAM-boot ELF, disassembled with objdump
    bram/firmware.hex               the firmware image built from it
    bram/bram_init.txt, bram/SOC.bit
                                    the block RAMs' contents and the bitstream, from
                                    flow_bram.tcl
    fw/mandelbrot.spiflash.{elf,bin,mcs}
                                    the flash build

and <captures_dir>/mandelbrot_bram.{bin,times}, the board capture, for the JTAG load, the
board and the UART stages. Writes <out.tex>: one \\newcommand per excerpt, its lines joined
by \\\\, set in the figure by design.tex, and one per number or word the chapter quotes. The
excerpt's own line, word or byte is wrapped in \\flowmark{...}, which design.tex defines.

Exits 1 unless every stage agrees with the next: the image is rtl/firmware.hex, its words are
the ELF's instructions, two 18-bit-wide block RAMs of one kind hold the image's low and high
halves, the binary begins with the flash ELF's first instruction, and the MCS holds the binary
at the code offset of rtl/defines.vh. Nothing in the output records a date, so unchanged
inputs write a byte-identical file. Needs Python 3, riscv64-unknown-elf-objdump and, through
board_figures.py, Pillow.
"""
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True    # no __pycache__/ beside the sources (lint rule 1)
from board_figures import Capture, HOME

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(SCRIPTS, "..", "..", ".."))
OBJDUMP = os.environ.get("OBJDUMP", "riscv64-unknown-elf-objdump")
WINDOW = 4          # instructions shown, the LED store and the three before it
HALVES = 4          # 16-bit halves of an INIT string shown


def fail(message):
    sys.exit(f"flow_excerpts.py: {message}")


def read(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def search(pattern, text, where):
    """The first group of pattern's first match in text; fails naming where it looked."""
    match = re.search(pattern, text, re.M)
    if not match:
        fail(f"no {pattern} in {where}")
    return match.group(1)


def define(name):
    """A hex `define of rtl/defines.vh, as an int."""
    value = search(rf"^`define\s+{name}\s+32'h([0-9A-Fa-f_]+)",
                   read(os.path.join(ROOT, "rtl", "defines.vh")), "rtl/defines.vh")
    return int(value.replace("_", ""), 16)


def short(cell):
    """A cell's name without its hierarchy: ram/ram_reg_0 is ram_reg_0."""
    return cell.split("/")[-1]


# ---- LaTeX -------------------------------------------------------------------

TEX_SPECIAL = {"\\": r"\textbackslash{}", "{": r"\{", "}": r"\}", "$": r"\$", "%": r"\%",
               "&": r"\&", "#": r"\#", "_": r"\_", "^": r"\^{}", "~": r"\~{}", " ": "~",
               "-": "-{}", "'": r"\textquotesingle{}", "<": r"\textless{}",
               ">": r"\textgreater{}"}


def tex(text):
    """Text set in typewriter type, spaces kept: a space is a tie, as wide as a character."""
    return "".join(TEX_SPECIAL.get(c, c) for c in text)


def mark(text):
    return r"\flowmark{" + tex(text) + "}"


def lines(*parts):
    return " \\\\\n  ".join(parts)


def thousands(n):
    """n with thin spaces between groups of three digits, as the report writes numbers."""
    return f"{n:,}".replace(",", "\\,")


# ---- the stages --------------------------------------------------------------

def disassemble(elf):
    """objdump -d of the ELF: {function: [(address, word, mnemonic, operands, comment)]}."""
    out = subprocess.run([OBJDUMP, "-d", elf], check=True, capture_output=True, text=True).stdout
    functions, current = {}, None
    insn = re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f]{8})\s*\t(\S+)\t?([^#]*?)\s*(?:#\s*(.*))?$")
    for line in out.splitlines():
        label = re.match(r"^[0-9a-f]+ <(\S+)>:$", line)
        if label:
            current = functions.setdefault(label.group(1), [])
            continue
        fields = insn.match(line)
        if fields and current is not None:
            current.append((int(fields.group(1), 16), int(fields.group(2), 16), fields.group(3),
                            fields.group(4), fields.group(5) or ""))
    return functions


def c_source(src, led_line):
    """The LED line of the C source and the lines either side, numbered."""
    shown = src[led_line - 2:led_line + 1]
    indent = min(len(s) - len(s.lstrip()) for s in shown)
    return [f"{n:2d}  " + s[indent:] for n, s in zip(range(led_line - 1, led_line + 2), shown)]


def led_store(main, io_base, io_leds):
    """Index in main of the store to the LED register: objdump names its address."""
    target = f"<IO_BASE+0x{io_leds:x}>"
    for i, (_, _, op, _, comment) in enumerate(main):
        if (op == "sw" and comment.endswith(target)
                and int(comment.split()[0], 16) == io_base + io_leds):
            if i < WINDOW - 1:
                fail("the LED store is too close to the start of main")
            return i
    fail(f"no store to {target} in main")


def assembly(path, window):
    """The window's lines in gcc -S's output: the line of its last instruction and the three
    instruction lines before it, inside main."""
    body = read(path).splitlines()
    start = body.index("main:")
    insns = [line.strip().split(None, 1) for line in body[start:]
             if line.startswith("\t") and not line.lstrip().startswith(".")]
    want = [window[-1][2], window[-1][3]]
    for end, insn in enumerate(insns):
        if insn == want and end >= WINDOW - 1:
            shown = insns[end - WINDOW + 1:end + 1]
            if shown[0] != [window[0][2], window[0][3]]:
                fail(f"{path}: the instruction before the LED store does not open the window")
            return [f"{op:<6}{args}" for op, args in shown]
    fail(f"{path}: no {' '.join(want)} in main")


def image_words(path):
    return [int(w, 16) for w in read(path).split()]


def init_half(inits, word):
    """The 16 bits of word in a block RAM's INIT strings: INIT_xx holds words 16 * xx to
    16 * xx + 15, the lowest rightmost."""
    pos = word % 16
    return inits[f"INIT_{word // 16:02X}"][60 - 4 * pos:64 - 4 * pos]


def bram_contents(path, image):
    """The block RAMs of bram_init.txt: (primitive, [(cell, {INIT_xx: hex})]), the cell
    holding the low 16 bits of each word first. Fails unless two 18-bit-wide RAMs of one
    primitive hold the image's two halves."""
    cells = []
    for line in read(path).splitlines():
        fields = line.split()
        if fields[0] == "CELL":
            cells.append((fields[1], fields[2], int(fields[3]), {}))
        else:
            cells[-1][3][fields[0]] = fields[1].split("'h")[1]
    if len(cells) != 2 or len({ref for _, ref, _, _ in cells}) != 1:
        fail(f"block RAMs {[(c, r) for c, r, _, _ in cells]}; the figure expects two of a kind")
    found = {}
    for cell, ref, width, inits in cells:
        if width != 18:
            fail(f"{cell} is {ref} {width} bits wide; the figure expects 18-bit-wide RAMs")
        halves = [int(init_half(inits, i), 16) for i in range(len(image))]
        for half in (0, 1):
            if halves == [(w >> 16 * half) & 0xFFFF for w in image]:
                found[half] = (cell, inits)
    if sorted(found) != [0, 1]:
        fail(f"the block RAMs {[c for c, *_ in cells]} do not hold the image's two halves")
    return cells[0][1], [found[0], found[1]]


def bram_line(cell, inits, word):
    """The INIT string of the cell around the word, the halves most significant first, as
    the INIT string writes them."""
    pos, base = word % 16, word - word % 16
    lo = pos // HALVES * HALVES
    parts = [(mark if p == pos else tex)(init_half(inits, base + p))
             for p in range(lo + HALVES - 1, lo - 1, -1)]
    head = tex(f"{short(cell)}  INIT_{word // 16:02X} = ") + ("…" if lo + HALVES < 16 else "")
    return head + "~".join(parts) + ("…" if lo > 0 else "")


def bit_header(path):
    """The fields of a .bit file's header, the length of its configuration data, the file's
    size and the offset of the sync word."""
    data = read(path, "rb")
    n = int.from_bytes(data[0:2], "big")
    pos = 2 + n + 2         # a field of n bytes, then the two bytes 00 01
    fields = {}
    while chr(data[pos]) in "abcd":
        key, n = chr(data[pos]), int.from_bytes(data[pos + 1:pos + 3], "big")
        fields[key] = data[pos + 3:pos + 3 + n].rstrip(b"\0").decode()
        pos += 3 + n
    if chr(data[pos]) != "e":
        fail(f"{path}: no configuration data field")
    length = int.from_bytes(data[pos + 1:pos + 5], "big")
    if pos + 5 + length != len(data):
        fail(f"{path}: the header counts {length} bytes, the file holds {len(data) - pos - 5}")
    sync = data.find(bytes.fromhex("AA995566"), pos + 5)
    return fields, length, len(data), sync


def script_line(name, pattern):
    """The first line of one of these scripts that matches pattern, without its comment."""
    for line in read(os.path.join(SCRIPTS, name)).splitlines():
        if re.search(pattern, line):
            return line.split(";#")[0].strip()
    fail(f"no line matching {pattern} in {name}")


def mcs_records(path):
    """The records of an Intel-hex MCS file: [(type, address, data, line)]."""
    records = []
    for line in read(path).split():
        raw = bytes.fromhex(line[1:])
        if sum(raw) & 0xFF:
            fail(f"{path}: bad checksum in {line}")
        records.append((raw[3], int.from_bytes(raw[1:3], "big"), raw[4:-1], line))
    return records


def uart_text(data):
    out = []
    for b in data:
        out.append(r"\textbackslash{}e" if b == 0x1B else r"\textvisiblespace{}" if b == 0x20
                   else tex(chr(b)))
    return "".join(out)


# ---- main --------------------------------------------------------------------

def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.split("\n\n")[1])
    flow, captures, out = sys.argv[1:]
    fw = os.path.join(flow, "fw")
    io_h = read(os.path.join(ROOT, "fw", "io.h"))
    io_base = int(search(r"#define IO_BASE\s+(0x[0-9A-Fa-f]+)", io_h, "fw/io.h"), 16)
    io_leds = int(search(r"#define IO_LEDS\s+(\d+)", io_h, "fw/io.h"))
    macros = {}

    # C source, assembly, ELF
    src = read(os.path.join(ROOT, "fw", "mandelbrot.c")).splitlines()
    led_line = next((n for n, s in enumerate(src, 1) if "IO_OUT(IO_LEDS" in s), None)
    if led_line is None:
        fail("no IO_OUT(IO_LEDS in fw/mandelbrot.c")
    before, line, after = c_source(src, led_line)
    macros["flowC"] = lines(tex(before), mark(line), tex(after))
    macros["flowLedLine"] = str(led_line)
    main_fn = disassemble(os.path.join(fw, "mandelbrot.bram.elf"))["main"]
    end = led_store(main_fn, io_base, io_leds)
    window = main_fn[end - WINDOW + 1:end + 1]
    asm = assembly(os.path.join(fw, "mandelbrot.s"), window)
    macros["flowAsm"] = lines(*[tex(a) for a in asm[:-1]], mark(asm[-1]))
    elf = [f"{a:4x}:  {w:08x}  {op:<5}{args}" for a, w, op, args, _ in window]
    macros["flowElf"] = lines(*[tex(e) for e in elf[:-1]], mark(elf[-1]))
    store_addr, store_word = window[-1][0], window[-1][1]
    macros["flowStoreAddr"] = f"0x{store_addr:x}"
    macros["flowStoreWord"] = f"0x{store_word:08x}"

    # firmware image
    image = image_words(os.path.join(flow, "bram", "firmware.hex"))
    if image != image_words(os.path.join(ROOT, "rtl", "firmware.hex")):
        fail("the image built in the flow directory is not rtl/firmware.hex")
    for a, w, *_ in window:
        if image[a // 4] != w:
            fail(f"image word {a // 4} is {image[a // 4]:08x}, the ELF's instruction {w:08x}")
    store = store_addr // 4
    hex_lines = read(os.path.join(ROOT, "rtl", "firmware.hex")).splitlines()
    first, last = window[0][0] // 16, store // 4
    shown = []
    for n in range(first, last + 1):
        words = [(mark if 4 * n + i == store else tex)(w)
                 for i, w in enumerate(hex_lines[n].split())]
        shown.append(tex(f"{n + 1:3d}  ") + "~".join(words))
    macros["flowHex"] = lines(*shown)
    macros["flowHexLines"] = f"{first + 1}" if first == last else f"{first + 1}--{last + 1}"
    macros["flowStoreIndex"] = str(store)
    macros["flowStoreHexLine"] = str(last + 1)

    # block RAM contents
    ref, (low, high) = bram_contents(os.path.join(flow, "bram", "bram_init.txt"), image)
    macros["flowBram"] = lines(bram_line(*high, store), bram_line(*low, store))
    macros["flowBramRef"] = ref
    macros["flowBramLow"], macros["flowBramHigh"] = tex(short(low[0])), tex(short(high[0]))
    macros["flowStoreLow"] = init_half(low[1], store)
    macros["flowStoreHigh"] = init_half(high[1], store)
    macros["flowBramInit"] = f"INIT\\_{store // 16:02X}"
    macros["flowBramWords"] = f"{store // 16 * 16} to {store // 16 * 16 + 15}"

    # bitstream
    fields, length, size, sync = bit_header(os.path.join(flow, "bram", "SOC.bit"))
    design = ";".join(f for f in fields["a"].split(";") if not f.startswith("SW_CRC"))
    macros["flowBit"] = lines(tex(f"a  {design}"), tex(f"b  {fields['b']}"),
                              tex(f"e  {length} bytes of configuration"),
                              tex(f"{sync:08x}:  ") + mark("aa995566") + tex("  sync word"))
    macros["flowBitBytes"] = thousands(length)
    macros["flowBitFileBytes"] = thousands(size)

    # JTAG, board, UART: the board capture
    capture = Capture(os.path.join(captures, "mandelbrot_bram"))
    frames = capture.frames()
    if len(frames) < 2:
        fail(f"{len(frames)} complete frames in the mandelbrot capture, want 2")
    (start, _), (next_start, _) = frames[:2]
    first_byte, next_frame = capture.time(start), capture.time(next_start)
    macros["flowJtag"] = lines(tex(script_line("board_program.tcl", r"^program_hw_devices")),
                               tex(f"PROGRAM_START {capture.program_start:.3f}"),
                               tex(f"PROGRAM_END   {capture.program_end:.3f}"))
    macros["flowLoadSeconds"] = f"{capture.program_end - capture.program_start:.1f}"
    macros["flowBoard"] = lines(tex(f"first byte   {first_byte:.3f} s"),
                                tex(f"next frame   {next_frame:.3f} s"))
    macros["flowFrameMs"] = f"{1e3 * (next_frame - first_byte):.1f}"
    pixel = re.match(rb"\x1b\[H(\x1b\[[0-9;]*m  )", capture.data[start:])
    if not pixel:
        fail("frame 0 does not open with ESC [ H and a pixel's colour")
    rest = capture.data[start + len(HOME) + len(pixel.group(1)):][:6]
    macros["flowUart"] = (uart_text(HOME) + r"\flowmark{" + uart_text(pixel.group(1)) + "}"
                          + uart_text(rest) + "…")

    # flash boot: ELF, binary, MCS, flash
    start_fn = disassemble(os.path.join(fw, "mandelbrot.spiflash.elf"))["_start"][:2]
    macros["flowFlashElf"] = lines(*[(mark if i == 0 else tex)(f"{a:x}:  {w:08x}  {op:<4}{args}")
                                     for i, (a, w, op, args, _) in enumerate(start_fn)])
    _, flash_word, flash_op, flash_args, _ = start_fn[0]
    macros["flowFlashFirst"] = tex(f"{flash_op} {flash_args}")
    macros["flowFlashWord"] = f"0x{flash_word:08x}"
    binary = read(os.path.join(fw, "mandelbrot.spiflash.bin"), "rb")
    if int.from_bytes(binary[0:4], "little") != flash_word:
        fail("the flash binary does not begin with the flash ELF's first instruction")
    macros["flowFlashBin"] = lines(tex("0000:  ") + mark(binary[:4].hex(" ")) + "~"
                                   + tex(binary[4:8].hex(" ")))
    macros["flowFlashBytes"] = tex(binary[:4].hex(" "))
    macros["flowFlashBinBytes"] = thousands(len(binary))
    offset = define("SPIFLASH_CODE_OFFSET")
    records = mcs_records(os.path.join(fw, "mandelbrot.spiflash.mcs"))
    base, data = 0, bytearray()
    for kind, address, payload, _ in records:
        if kind == 4:
            base = int.from_bytes(payload, "big") << 16
        elif kind == 0:
            if base + address != offset + len(data):
                fail(f"MCS record at {base + address:#x}, want {offset + len(data):#x}")
            data += payload
    if bytes(data) != binary:
        fail("the MCS does not hold the flash binary")
    ext, rec = records[0][3], records[1][3]
    if records[0][0] != 4:
        fail("the MCS does not open with an extended linear address record")
    macros["flowMcs"] = lines(tex(ext[:9]) + mark(ext[9:13]) + tex(ext[13:]),
                              tex(rec[:9]) + mark(rec[9:17]) + tex(rec[17:21]) + "…")
    macros["flowMcsUpper"] = ext[9:13]
    macros["flowFlash"] = lines(
        tex(script_line("board_flash.tcl", r"PROGRAM\.ADDRESS_RANGE")),
        tex(script_line("board_flash.tcl", r"^\s*program_hw_cfgmem")),
        tex(f"0x{offset:06X} to 0x{offset + len(binary) - 1:06X}"))

    body = ["% Generated by docs/design/scripts/flow_excerpts.py (make flow, in docs/design/)",
            "% from the build of mandelbrot and its board capture; do not edit. design.tex",
            "% defines \\flowmark.", ""]
    for name, value in macros.items():
        body.append(f"\\newcommand{{\\{name}}}{{%\n  {value}}}")
    with open(out, "w") as f:
        f.write("\n".join(body) + "\n")
    print(f"FLOW excerpts {out}: line {led_line} of fw/mandelbrot.c, the store at "
          f"{store_addr:#x}, image word {store}")


if __name__ == "__main__":
    main()
