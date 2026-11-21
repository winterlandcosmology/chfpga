#!/usr/bin/env python3
"""Checks the Ethernet frames written by the rawpack testbenches (one frame per line, in hex).

Each file holds the frames of one 100G link. Verifies, for every frame: the Ethernet/IPv4/UDP
headers (lengths, IP checksum), the raw stream header (format 4), that the packet counter and the
timestamps of each stream are contiguous (no packet lost anywhere in the chain), and every sample
against the testbench pattern: sample number t of channel c has the 14-bit value
(t * (2c + 3) + 1000c) mod 16384 at the input, and it is sent as 12 bits (rounded or truncated, as
the header says).

Verifies, over all the files: that a stream is on its link (streams A and B on the first file,
C and D on the second), and that the packets of all streams with the same packet counter start on
the same sample. A file can hold several runs (the run number of the header goes up by one): the
packet counters start again at 0 in each run.

The first link can also carry the upstream frames of the testbench (every 32-byte word starts with
"UPST", the frame number and the position of the word). Each one must be complete: 194 words of
one frame, in order. With --upstream 1, they must be there before and after the raw packets (or
all of them with no gap if the link has no raw packet). With --upstream 2, the upstream transmitter
was stopped in the middle of a frame: the frames that the firmware closed with a word of zeros are
accepted, one for each run at most.

Uses only the Python standard library.
Usage: check_frames.py FILE [FILE ...] [--min-packets N] [--upstream {0,1,2}]
"""
import argparse
import sys

WORDS_PER_FRAME = 2048
STREAMS_PER_LINK = 2
UPSTREAM_MARK = b'UPST'
UPSTREAM_WORDS = 194
NAMES = 'ABCD'


def reduce_sample(value, rounded):
    """ The 12-bit number sent for a 14-bit sample (two's complement, as an unsigned 12-bit value). """
    if value >= 8192:
        value -= 16384
    if rounded:
        value += 2
    return min(value >> 2, 2047) & 0xFFF


def check(paths, min_packets=1, upstream=0):
    expected_ctr = {}      # stream -> packet counter of its next packet
    run_of = {}            # stream -> run number of its last packet
    origin = {}            # (run, stream) -> first sample of its packet number 0, UDP destination port
    counts = {}            # (run, stream) -> packets
    up_frames = []         # for each upstream frame of link 0: (frame number, raw packets of link 0 before it)
    up_closed = 0
    payload_bytes = 0
    total = 0
    for link, path in enumerate(paths):
        n = 0
        with open(path) as f:
            for lineno, line in enumerate(f, 1):
                frame = bytes.fromhex(line.strip())

                def fail(msg):
                    sys.exit(f'{path}:{lineno}: packet {n}: {msg}')

                if frame[:4] == UPSTREAM_MARK:
                    if link != 0 or not upstream:
                        fail('upstream frame, but this link has no upstream bus')
                    words = [frame[i:i + 32] for i in range(0, len(frame), 32)]
                    if words[-1] == bytes(32) and upstream == 2:
                        up_closed += 1  # stopped in the middle, closed by the firmware
                        continue
                    if len(frame) != 32 * UPSTREAM_WORDS or any(w[:8] != words[0][:8] or int.from_bytes(w[8:10], 'big') != i for i, w in enumerate(words)):
                        fail(f'upstream frame that is not complete ({len(frame) / 32:g} words)')
                    number = int.from_bytes(frame[4:8], 'big')
                    if up_frames and number <= up_frames[-1][0]:
                        fail('upstream frame out of order')
                    up_frames.append((number, n))
                    continue
                if len(frame) < 64:
                    fail(f'frame too short ({len(frame)} bytes)')
                if frame[12:14] != b'\x08\x00':
                    fail('not IPv4')
                ip = frame[14:34]
                if ip[0] != 0x45 or ip[9] != 17:
                    fail('not a plain IPv4/UDP header')
                if int.from_bytes(ip[2:4], 'big') != len(frame) - 14:
                    fail(f'IP length {int.from_bytes(ip[2:4], "big")} does not match the frame ({len(frame) - 14})')
                s = sum(int.from_bytes(ip[i:i + 2], 'big') for i in range(0, 20, 2))
                s = (s & 0xFFFF) + (s >> 16)
                s = (s & 0xFFFF) + (s >> 16)
                if s != 0xFFFF:
                    fail('bad IP header checksum')
                if int.from_bytes(frame[38:40], 'big') != len(frame) - 34:
                    fail('bad UDP length')
                h = frame[42:64]
                if h[0:2] != b'RA' or h[2] != 4:
                    fail('bad magic/version')
                run = h[20]
                if h[21] != 12:
                    fail(f'sample width {h[21]} (expected 12)')
                flags, chan_byte, blocks = h[3], h[4], h[5]
                if flags & 0xC0:
                    fail(f'error flags set (0x{flags:02X})')
                rounded = bool(flags & 2)
                mask = (flags >> 2) & 0xF
                stream, chan = (chan_byte >> 4) & 7, chan_byte & 7
                if not mask & (1 << stream):
                    fail(f'packet of stream {NAMES[stream]}, which is not enabled (mask 0x{mask:X})')
                if stream // STREAMS_PER_LINK != link and len(paths) > 1:
                    fail(f'packet of stream {NAMES[stream]} on link {link}')
                dest_port = int.from_bytes(frame[36:38], 'big')
                ctr = int.from_bytes(h[6:12], 'big')
                first_sample = (int.from_bytes(h[12:18], 'big') * WORDS_PER_FRAME + int.from_bytes(h[18:20], 'big')) * 8
                data = frame[64:]
                if len(data) != 96 * blocks:
                    fail(f'{len(data)} sample bytes, expected {96 * blocks}')
                samples = blocks * 64

                if run != run_of.get(stream):
                    if run != run_of.get(stream, 0) + 1:
                        fail(f'stream {NAMES[stream]}: run number {run} after run {run_of.get(stream, 0)}')
                    if int.from_bytes(h[18:20], 'big') != 0:
                        fail('the stream does not start on a frame boundary')
                    if ctr != 0:
                        fail(f'the first packet of stream {NAMES[stream]} in run {run} has packet counter {ctr}')
                    run_of[stream] = run
                    origin[run, stream] = (first_sample, dest_port)
                elif ctr != expected_ctr[stream]:
                    fail(f'stream {NAMES[stream]}: packet counter {ctr}, expected {expected_ctr[stream]}: {ctr - expected_ctr[stream]} packet(s) lost')
                if first_sample != origin[run, stream][0] + ctr * samples:
                    fail(f'stream {NAMES[stream]}: first sample {first_sample}, expected {origin[run, stream][0] + ctr * samples}')
                if dest_port != origin[1, stream][1]:
                    fail(f'stream {NAMES[stream]}: UDP destination port {dest_port}, was {origin[1, stream][1]}')
                expected_ctr[stream] = ctr + 1

                # 2 samples per 3 bytes, little-endian bit stream, one channel in time order
                i = 0
                for g in range(0, len(data), 3):
                    w = int.from_bytes(data[g:g + 3], 'little')
                    for k in range(2):
                        got = (w >> (12 * k)) & 0xFFF
                        t = first_sample + i
                        expected = reduce_sample((t * (2 * chan + 3) + 1000 * chan) % 16384, rounded)
                        if got != expected:
                            fail(f'sample {i} (channel {chan}, t={t}): got {got}, expected {expected}')
                        i += 1
                n += 1
                counts[run, stream] = counts.get((run, stream), 0) + 1
                payload_bytes += len(data)
        if link == 0 and upstream:
            numbers = [number for number, _ in up_frames]
            if not up_frames or up_frames[0][1] != 0 or (up_frames[-1][1] != n and upstream == 1):
                sys.exit(f'{path}: the upstream frames are not there before and after the raw packets')
            if n == 0 and numbers != list(range(numbers[0], numbers[0] + len(numbers))):
                sys.exit(f'{path}: no raw stream on this link, but upstream frames are missing')
            if up_closed > (max(run_of.values()) if n else 0):
                sys.exit(f'{path}: {up_closed} upstream frames closed by the firmware')
        total += n
    if total < min_packets:
        sys.exit(f'{", ".join(paths)}: only {total} packets, expected at least {min_packets}')
    runs = sorted({run for run, _ in origin})
    streams = sorted({stream for _, stream in origin})
    for run in runs:
        if len({origin[run, s][0] for s in streams}) > 1:
            sys.exit(f'Run {run}: the streams do not start on the same sample: ' + ', '.join(f'{NAMES[s]}: {origin[run, s][0]}' for s in streams))
        if max(counts[run, s] for s in streams) - min(counts[run, s] for s in streams) > 1:
            sys.exit(f'Run {run}: packets of each stream: ' + ', '.join(f'{NAMES[s]}: {counts[run, s]}' for s in streams))
    ports = sorted(origin[1, s][1] for s in streams)
    if len(set(ports)) != len(ports):
        sys.exit(f'Two streams have the same UDP destination port: {ports}')
    print(f'{", ".join(paths)}: {total} packets OK in {len(runs)} run(s) ('
          + ', '.join(f'{sum(counts[r, s] for r in runs)} of stream {NAMES[s]} on port {origin[1, s][1]}' for s in streams)
          + f'), {payload_bytes * 8 // 12} samples checked, no packet lost, all streams start on the same sample'
          + (f', {len(up_frames)} complete upstream frames, {up_closed} closed by the firmware' if upstream else ''))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('files', nargs='+', help='one file for each link, link 0 first')
    p.add_argument('--min-packets', type=int, default=1)
    p.add_argument('--upstream', type=int, default=0, choices=(0, 1, 2), help='upstream frames on the first link: 0 none, 1 all the time, 2 stopped during the runs')
    a = p.parse_args()
    check(a.files, a.min_packets, a.upstream)
