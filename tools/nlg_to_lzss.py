#!/usr/bin/env python3
import argparse
from collections import defaultdict, deque
from pathlib import Path


def compress(data: bytes) -> bytes:
    out = bytearray()
    chains = defaultdict(deque)
    pos = 0

    def remember(p: int) -> None:
        if p + 2 >= len(data):
            return
        key = data[p:p + 3]
        q = chains[key]
        q.append(p)
        while q and p - q[0] > 4096:
            q.popleft()
        while len(q) > 96:
            q.popleft()

    while pos < len(data):
        ctrl_at = len(out)
        out.append(0)
        ctrl = 0
        for bit in range(8):
            if pos >= len(data):
                break
            best_len = 0
            best_dist = 0
            if pos + 2 < len(data):
                key = data[pos:pos + 3]
                for candidate in reversed(chains[key]):
                    dist = pos - candidate
                    if dist > 4096:
                        break
                    length = 0
                    while (length < 18 and pos + length < len(data)
                           and data[candidate + length] == data[pos + length]):
                        length += 1
                    if length > best_len:
                        best_len = length
                        best_dist = dist
                        if length == 18:
                            break
            if best_len >= 3:
                code = best_dist - 1
                out.append(code & 0xff)
                out.append((((code >> 8) & 0x0f) << 4) | (best_len - 3))
                for p in range(pos, pos + best_len):
                    remember(p)
                pos += best_len
            else:
                ctrl |= 1 << bit
                out.append(data[pos])
                remember(pos)
                pos += 1
        out[ctrl_at] = ctrl
    return bytes(out)


def decompress(data: bytes, output_size: int) -> bytes:
    out = bytearray()
    pos = 0
    while len(out) < output_size:
        control = data[pos]
        pos += 1
        for bit in range(8):
            if len(out) >= output_size:
                break
            if control & (1 << bit):
                out.append(data[pos])
                pos += 1
            else:
                lo = data[pos]
                hi_len = data[pos + 1]
                pos += 2
                distance = (((hi_len >> 4) << 8) | lo) + 1
                length = (hi_len & 0x0f) + 3
                for _ in range(length):
                    out.append(out[-distance])
    return bytes(out)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("nlg", type=Path)
    parser.add_argument("hex", type=Path)
    parser.add_argument("meta", type=Path)
    args = parser.parse_args()

    raw = args.nlg.read_bytes()
    if raw[:4] != b"NLG1" or len(raw) < 96:
        raise SystemExit("not an NLG1 file")
    payload = raw[96:]
    packed = compress(payload)
    if decompress(packed, len(payload)) != payload:
        raise SystemExit("internal LZSS verification failed")

    args.hex.parent.mkdir(parents=True, exist_ok=True)
    args.hex.write_text("".join(f"{value:02x}\n" for value in packed))
    args.meta.write_text(
        f"localparam integer SONG_PACKED_BYTES = {len(packed)};\n"
        f"localparam integer SONG_RAW_BYTES = {len(payload)};\n"
    )
    print(f"NLG payload {len(payload)} bytes -> LZSS {len(packed)} bytes")


if __name__ == "__main__":
    main()
