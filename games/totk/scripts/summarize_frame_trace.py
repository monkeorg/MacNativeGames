#!/usr/bin/env python3
"""Summarize existing DM_NVN_TSV timing rows without launching the game.

Guest present-call cadence does not establish native rendered FPS. Delayed GPU
and presentation rows are matched by frame ID, never by file order.
"""
import argparse
import gzip
import json
import math
from pathlib import Path
import statistics


METRICS = {
    '@frame_ms': 'guest nvnQueuePresentTexture call interval; not GPU completion or display FPS',
    '@gpu_ms': 'runtime GPU duration for a game frame; not a frame interval',
    '@presented_ms': 'presented callback interval for adjacent game presents; not interpolated-frame cadence',
}
CALL_TIME = '@call_ms'


def distribution(values, interval):
    ordered = sorted(values)
    if not ordered:
        return None
    def percentile(q):
        return ordered[max(0, math.ceil(q * len(ordered)) - 1)]
    result = dict(samples=len(ordered), mean_ms=statistics.mean(ordered),
                  median_ms=statistics.median(ordered), p95_ms=percentile(.95),
                  p99_ms=percentile(.99), longest_ms=ordered[-1])
    if interval:
        slowest = ordered[-max(1, math.ceil(len(ordered) * .01)):]
        result.update(sampled_interval_seconds=sum(ordered) / 1000,
                      cadence_hz=1000 / statistics.mean(ordered),
                      low_1_percent_hz=1000 / statistics.mean(slowest),
                      over_60hz_budget=sum(x > 1000 / 60 for x in ordered),
                      over_30hz_budget=sum(x > 1000 / 30 for x in ordered))
    return result


def summarize(stream, first, last):
    if first < 0 or last < first:
        raise ValueError('require 0 <= first <= last')
    rows = {name: {} for name in (*METRICS, CALL_TIME)}
    duplicates = {name: set() for name in rows}
    malformed = 0
    for line in stream:
        if line.startswith('#') or line.rstrip('\r\n') == 'frame\tname\tvalue':
            continue
        parts = line.rstrip('\r\n').split('\t')
        if len(parts) != 3 or not parts[0].isascii() or not parts[0].isdigit():
            malformed += 1
            continue
        frame = int(parts[0])
        name = parts[1]
        if not first <= frame <= last or name not in rows:
            continue
        try:
            value = float(parts[2])
        except ValueError:
            value = math.nan
        if frame in rows[name]:
            duplicates[name].add(frame)
        rows[name][frame] = value
    metrics = {}
    expected = last - first + 1
    for name, samples in rows.items():
        if name == CALL_TIME:
            continue
        duplicate = duplicates[name]
        valid = {f: v for f, v in samples.items()
                 if f not in duplicate and math.isfinite(v) and v > 0}
        missing = expected - len(samples)
        metrics[name] = dict(
            semantics=METRICS[name], expected_frame_ids=expected,
            missing_frame_ids=missing, duplicate_frame_ids=len(duplicate),
            invalid_frame_ids=sum(f not in duplicate and
                                  (not math.isfinite(v) or v <= 0)
                                  for f, v in samples.items()),
            discarded_frame_ids=sum(f not in duplicate and v == -1
                                    for f, v in samples.items()) if name == '@presented_ms' else 0,
            complete=len(valid) == expected,
            statistics=distribution(valid.values(), name != '@gpu_ms'))
    timestamps = sorted((f, v) for f, v in rows[CALL_TIME].items()
                        if f not in duplicates[CALL_TIME] and math.isfinite(v) and v >= 0)
    increasing = all(b[1] > a[1] for a, b in zip(timestamps, timestamps[1:]))
    timestamp_span = dict(semantics='elapsed between first and last selected guest present-call timestamp; excludes preceding interval',
                          samples=len(timestamps), strictly_increasing=increasing,
                          first_frame=timestamps[0][0] if timestamps else None,
                          last_frame=timestamps[-1][0] if timestamps else None,
                          seconds=(timestamps[-1][1] - timestamps[0][1]) / 1000
                          if len(timestamps) >= 2 and increasing else None,
                          missing_frame_ids=expected - len(rows[CALL_TIME]),
                          duplicate_frame_ids=len(duplicates[CALL_TIME]),
                          invalid_frame_ids=sum(f not in duplicates[CALL_TIME] and
                                                (not math.isfinite(v) or v < 0)
                                                for f, v in rows[CALL_TIME].items()))
    return dict(first_frame=first, last_frame=last, malformed_lines=malformed,
                guest_call_timestamp_span=timestamp_span,
                percentile_method='nearest rank; median averages the middle pair',
                low_1_percent_definition='1000 / mean of slowest ceil(N * 0.01) positive intervals',
                native_rendered_fps='unverified', memory='not supplied by this TSV analysis',
                thermal='not supplied by this TSV analysis', metrics=metrics)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--first-frame', type=int, required=True)
    parser.add_argument('--last-frame', type=int, required=True)
    args = parser.parse_args()
    if args.first_frame < 0 or args.last_frame < args.first_frame:
        parser.error('require 0 <= first-frame <= last-frame')
    opener = gzip.open if args.trace.suffix == '.gz' else open
    with opener(args.trace, 'rt', encoding='utf-8') as stream:
        print(json.dumps(summarize(stream, args.first_frame, args.last_frame), indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
