#!/usr/bin/env bash
# Crop the excerpts of Digilent's Genesys 2 schematic that chapter 2 of the final report cites.
#
#   docs/design/scripts/schematic_crops.sh <schematic.pdf> <out_dir>
#   (make figures runs it with SCHEMATIC, default build/genesys2_sch.pdf)
#
# The schematic is Digilent's public PDF, revision H.1, 22 pages of 828 x 612 pt; its SHA-256
# below makes sure the fixed regions fall on the parts they name. Digilent's site refuses a
# scripted download, so the PDF is a local copy: figures/README.md, "Schematic excerpts", says
# where to get it. pdftoppm renders each region at 300 dpi into <out_dir>/sch_<name>.png; the
# PNGs record no date, so an unchanged region regenerates byte-identical.
set -euo pipefail

[ $# = 2 ] || { echo "usage: schematic_crops.sh <schematic.pdf> <out_dir>" >&2; exit 2; }
pdf=$1 out=$2 dpi=300
sha256=73a6b396ddcf037a112c2f917d3c9044d246c706e5b8a15431d941ccc5f99c43

[ -f "$pdf" ] || { echo "schematic_crops.sh: no schematic at $pdf; see figures/README.md, \"Schematic excerpts\"" >&2; exit 1; }
echo "$sha256  $pdf" | sha256sum --check --quiet - \
    || { echo "schematic_crops.sh: $pdf is not the Genesys 2 schematic revision H.1 the regions were measured on" >&2; exit 1; }
mkdir -p "$out"

# name, page, then the region in points from the page's top left corner: x, y, width, height.
while read -r name page x y w h; do
    px() { echo $(( $1 * dpi / 72 )); }
    pdftoppm -png -singlefile -r $dpi -f "$page" -l "$page" \
        -x "$(px "$x")" -y "$(px "$y")" -W "$(px "$w")" -H "$(px "$h")" "$pdf" "$out/sch_$name"
    echo "FIGURE $out/sch_$name.png (page $page)"
done <<'REGIONS'
oscillator 13 248 484 266 76
uart        9 318 304 456 180
config     15 140 140 672 216
mode       15 215 372 245  82
leds        4  50 364 108 182
reset      11 580 410 168 78
REGIONS
