#!/usr/bin/env bash
# Run a Vivado Tcl script in the GUI on a private X server (Xvfb), never on the owner's display.
# Some figure commands only work in the GUI: write_schematic writes nothing in batch mode.
#
#   docs/design/scripts/vivado_xvfb.sh <scratch_dir> <script.tcl> [tclargs...]
#
# Vivado starts in <scratch_dir>, so .Xil/, its log and its journal land there. The script must
# end with `exit` (exit 1 on failure): a GUI session does not end on its own. VIVADO_TIMEOUT
# seconds (default 600) is the backstop for a script that hangs with a dialog open. Needs
# Vivado's settings64.sh sourced and xvfb-run (package xvfb).
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: vivado_xvfb.sh <scratch_dir> <script.tcl> [tclargs...]" >&2; exit 2; }
scratch=$1 script=$(realpath "$2")
shift 2
VIVADO=${VIVADO:-vivado}

command -v "$VIVADO" >/dev/null || { echo "vivado_xvfb.sh: $VIVADO not on PATH; source Vivado's settings64.sh" >&2; exit 1; }
command -v xvfb-run >/dev/null || { echo "vivado_xvfb.sh: xvfb-run not on PATH (package xvfb)" >&2; exit 1; }

mkdir -p "$scratch"
cd "$scratch"
rm -f vivado.log vivado.jou

# xvfb-run -a picks a free display number and points DISPLAY at it for Vivado alone.
rc=0
env -u WAYLAND_DISPLAY timeout "${VIVADO_TIMEOUT:-600}" \
    xvfb-run -a -s "-screen 0 1920x1080x24" \
    "$VIVADO" -mode gui -log vivado.log -journal vivado.jou -source "$script" -tclargs "$@" \
    > /dev/null 2>&1 || rc=$?

# In GUI mode Vivado's console output goes to its log, not to stdout.
if [ "$rc" != 0 ]; then
    [ "$rc" = 124 ] && echo "vivado_xvfb.sh: timed out after ${VIVADO_TIMEOUT:-600} s" >&2
    echo "vivado_xvfb.sh: $(basename "$script") failed (exit $rc); end of $(pwd)/vivado.log:" >&2
    grep -v 'WARNING: \[Board 49-26\]' vivado.log 2>/dev/null | tail -n 20 >&2 || true
    exit 1
fi
grep '^FIGURE' vivado.log || true
