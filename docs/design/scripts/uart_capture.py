#!/usr/bin/env python3
"""Record the board's UART output with host timestamps, around the command that loads the board.

    uart_capture.py <port> <seconds> <out_base> -- <command> [args...]
    (docs/design/scripts/board_capture.sh runs it, with board_program.tcl as the command)

Opens <port> at 115200 8N1 and runs <command>, passing its output through. Recording starts when
the command prints a line beginning "BOARD loading", just before it loads the FPGA, and goes on
until <seconds> after the command ends. Until the load, the design already in the FPGA writes to
the UART too. When the command succeeds, writes:

    <out_base>.bin    every byte recorded, as received
    <out_base>.times  the timeline, in seconds since the port was opened, one event per line:
                      PROGRAM_START <t> and PROGRAM_END <t>, the load and the command's end;
                      READ <t> <count>, a read that brought the next <count> bytes of .bin;
                      END <t> bytes=<n>

The port is read every millisecond, and low-latency mode, set here, makes the FT232R USB-UART
bridge send a packet at least every millisecond: a byte's READ time is within about two
milliseconds of its arrival. Exits with the command's exit code. Needs pyserial.
"""
import datetime
import subprocess
import sys
import threading
import time

import serial

MARK = "BOARD loading"


def main():
    if len(sys.argv) < 6 or sys.argv[4] != "--":
        sys.exit(__doc__.split("\n\n")[1])
    port, seconds, out_base, command = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[5:]

    data = bytearray()
    events = []
    loading = threading.Event()
    opened = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    with serial.Serial(port, 115200, timeout=0) as uart:
        uart.set_low_latency_mode(True)
        t0 = time.monotonic()
        now = lambda: f"{time.monotonic() - t0:.4f}"
        program = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True)

        def relay():
            for line in program.stdout:
                if not loading.is_set() and line.startswith(MARK):
                    events.append(f"PROGRAM_START {now()}")
                    loading.set()
                sys.stdout.write(line)
                sys.stdout.flush()
        relay_thread = threading.Thread(target=relay)
        relay_thread.start()

        deadline = None
        while deadline is None or time.monotonic() < deadline:
            time.sleep(0.001)
            chunk = uart.read(uart.in_waiting)
            if chunk and loading.is_set():
                events.append(f"READ {now()} {len(chunk)}")
                data += chunk
            if deadline is None and program.poll() is not None:
                relay_thread.join()
                events.append(f"PROGRAM_END {now()}")
                if program.returncode != 0 or not loading.is_set():
                    print(f"CAPTURE nothing written: the command exited {program.returncode}"
                          + ("" if loading.is_set() else f" without printing '{MARK}'"))
                    sys.exit(program.returncode or 1)
                deadline = time.monotonic() + seconds
        events.append(f"END {now()} bytes={len(data)}")

    with open(out_base + ".bin", "wb") as f:
        f.write(data)
    with open(out_base + ".times", "w") as f:
        f.write(f"# {port} at 115200 8N1, opened {opened.isoformat()}; "
                "times in seconds since then\n")
        f.write("\n".join(events) + "\n")
    print(f"CAPTURE {out_base}.bin: {len(data)} bytes")


if __name__ == "__main__":
    main()
