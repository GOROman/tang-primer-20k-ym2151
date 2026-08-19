#!/usr/bin/env python3
"""Convert timestamped YM2151 register writes into an NLG1 stream."""

import argparse
from pathlib import Path


QUANTUM_US = 64


def read_events(path: Path):
    events = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 3:
            raise ValueError(f"{path}:{line_number}: expected time address data")
        timestamp, address, data = map(int, fields[:3])
        if not 0 <= address <= 255 or not 0 <= data <= 255:
            raise ValueError(f"{path}:{line_number}: register value out of range")
        events.append((timestamp, address, data))
    if not events:
        raise ValueError(f"{path}: no events")
    return events


def convert(events):
    # CTC0=1 gives a 256-cycle unit.  At the 4 MHz OPM clock this is 64 us.
    payload = bytearray((0x81, 0x01))
    timeline_units = 0
    current_ctc3 = None

    for timestamp_us, address, data in events:
        target_units = round(timestamp_us / QUANTUM_US)
        remaining = max(0, target_units - timeline_units)
        while remaining:
            chunk = min(remaining, 255)
            if current_ctc3 != chunk:
                payload.extend((0x82, chunk))
                current_ctc3 = chunk
            payload.append(0x80)
            timeline_units += chunk
            remaining -= chunk
        payload.extend((0x01, address, data))

    header = bytearray(96)
    header[:4] = b"NLG1"
    return bytes(header + payload), timeline_units * QUANTUM_US


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evt", type=Path)
    parser.add_argument("nlg", type=Path)
    args = parser.parse_args()

    events = read_events(args.evt)
    nlg, timeline_us = convert(events)
    args.nlg.parent.mkdir(parents=True, exist_ok=True)
    args.nlg.write_bytes(nlg)
    print(
        f"{len(events)} events, {len(nlg) - 96} payload bytes, "
        f"timeline {timeline_us / 1_000_000:.6f} s"
    )


if __name__ == "__main__":
    main()
