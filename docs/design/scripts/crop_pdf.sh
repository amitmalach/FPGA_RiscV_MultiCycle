#!/usr/bin/env bash
# Crop a one-page PDF to its drawing plus a 4 pt margin, for the final report's figures.
#
#   docs/design/scripts/crop_pdf.sh <in.pdf> <out.pdf>
#
# Ghostscript's bbox device finds the drawing's bounding box; pdfwrite then cuts the page to
# it with a fixed media size and a page offset. pdfwrite also embeds the fonts (Vivado's
# schematics name Helvetica without embedding it) and, with the Omit* flags, writes no date or
# document ID, so regenerating an unchanged figure leaves the file byte-identical.
set -euo pipefail

[ $# = 2 ] || { echo "usage: crop_pdf.sh <in.pdf> <out.pdf>" >&2; exit 2; }
in=$1 out=$2 margin=4

bbox=$(gs -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=bbox "$in" 2>&1 | awk '/^%%HiResBoundingBox:/ {print $2, $3, $4, $5}')
[ -n "$bbox" ] || { echo "crop_pdf.sh: no drawing found in $in" >&2; exit 1; }
read -r x0 y0 x1 y1 <<< "$bbox"
read -r width height dx dy <<< "$(awk -v x0="$x0" -v y0="$y0" -v x1="$x1" -v y1="$y1" -v m="$margin" \
    'BEGIN { printf "%.2f %.2f %.2f %.2f", x1 - x0 + 2*m, y1 - y0 + 2*m, m - x0, m - y0 }')"

gs -q -dSAFER -sDEVICE=pdfwrite -o "$out" \
    -dDEVICEWIDTHPOINTS="$width" -dDEVICEHEIGHTPOINTS="$height" -dFIXEDMEDIA \
    -dAutoRotatePages=/None -dEmbedAllFonts=true -dOmitInfoDate -dOmitID -dOmitXMP \
    -c "<</NeverEmbed []>> setdistillerparams <</PageOffset [$dx $dy]>> setpagedevice" -f "$in"
