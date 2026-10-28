"""The PDF file around a list of objects, for the report's figure scripts (vcd_wave.py,
board_figures.py): each script builds its own catalog, pages and content streams, and this
writes the header, the numbered objects, the cross-reference table and the trailer. Object 1
must be the catalog. Nothing written records a date, so unchanged objects give an identical
file. Needs only Python 3.
"""


def write_pdf_objects(path, objects):
    """Write the objects, bytes each, as a PDF 1.4 file; object n is objects[n - 1]."""
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
