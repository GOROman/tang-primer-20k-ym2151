#!/usr/bin/env python3
"""Send the compressed stream using 1 KiB XMODEM-CRC at 230400 baud."""
import argparse, time
from pathlib import Path
import serial

def crc16(data):
    c = 0
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xffff if c & 0x8000 else (c << 1) & 0xffff
    return c

ap = argparse.ArgumentParser()
ap.add_argument("data", type=Path)
ap.add_argument("--port", default="/dev/cu.usbserial-1101")
a = ap.parse_args()
if a.data.suffix.lower() == ".hex":
    payload = bytes(int(value, 16) for value in a.data.read_text().split())
else:
    payload = a.data.read_bytes()
pad = (-len(payload)) % 1024
payload += bytes(pad)
with serial.Serial(a.port, 230400, timeout=0.05) as uart:
    uart.reset_input_buffer()
    deadline = time.time() + 10
    while time.time() < deadline:
        if uart.read(1) == b"\x15": break
    else: raise SystemExit("FPGA did not send NAK")
    seq = 0
    for off in range(0, len(payload), 1024):
        block = payload[off:off+1024]
        packet = b"\x02" + bytes((seq, 255-seq)) + block + crc16(block).to_bytes(2, "big")
        for attempt in range(10):
            uart.write(packet); uart.flush()
            deadline = time.time() + 2
            reply = None
            while time.time() < deadline:
                value = uart.read(1)
                if value in (b"\x06", b"\x15"):
                    reply = value
                    break
            if reply == b"\x06": break
        else: raise SystemExit(f"packet {seq} failed")
        seq = (seq + 1) & 255
        print(f"{min(off+1024, len(payload))}/{len(payload)}", flush=True)
print("XMODEM upload complete")
