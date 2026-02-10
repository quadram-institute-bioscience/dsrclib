#!/usr/bin/env python3
"""Analyse hyperfine benchmark results from 'make bench'.

Reads the CSV files in the benchmark/ directory and prints a plain-language
summary comparing the original dsrc C++ tool against the Nim wrapper.

Uses the updated naming convention: compression_single, compression_threaded,
decompression_single, decompression_threaded.
"""

import csv
import os
import sys

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))

CASES = [
    ("compression_single",       "Compression, single thread"),
    ("compression_threaded",     "Compression, 4 threads"),
    ("decompression_single",     "Decompression, single thread"),
    ("decompression_threaded",   "Decompression, 4 threads"),
]


def load_csv(name):
    """Return list of rows (dicts) from a hyperfine CSV."""
    path = os.path.join(BENCH_DIR, f"{name}.csv")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return list(csv.DictReader(f))


def identify_tool(command):
    """Return 'dsrc' or 'nim' based on the command string."""
    if command.startswith("dsrc "):
        return "dsrc"
    if "fastq2dsrc" in command or "undsrc" in command:
        return "nim"
    return "unknown"


def ms(seconds):
    """Format seconds as milliseconds string."""
    return f"{float(seconds) * 1000:.1f} ms"


def main():
    print("=" * 60)
    print("  DSRC (C++) vs Nim wrapper  —  Benchmark Summary")
    print("=" * 60)
    print()

    any_found = False

    for filename, label in CASES:
        rows = load_csv(filename)
        if rows is None:
            print(f"  {label}: (no data — run 'make bench' first)")
            print()
            continue

        any_found = True
        tools = {}
        for row in rows:
            tool = identify_tool(row["command"])
            tools[tool] = row

        if "dsrc" not in tools or "nim" not in tools:
            print(f"  {label}: unexpected CSV format, skipping")
            print()
            continue

        dsrc_mean = float(tools["dsrc"]["mean"])
        nim_mean = float(tools["nim"]["mean"])
        dsrc_std = float(tools["dsrc"]["stddev"])
        nim_std = float(tools["nim"]["stddev"])

        ratio = nim_mean / dsrc_mean
        overhead_pct = (ratio - 1) * 100

        print(f"  {label}")
        print(f"    dsrc (C++):  {ms(dsrc_mean)}  ± {ms(dsrc_std)}")
        print(f"    Nim wrapper: {ms(nim_mean)}  ± {ms(nim_std)}")

        if overhead_pct > 5:
            print(f"    → Nim is {ratio:.2f}x slower ({overhead_pct:+.0f}% overhead)")
        elif overhead_pct < -5:
            print(f"    → Nim is {abs(overhead_pct):.0f}% faster (!)")
        else:
            print(f"    → Essentially the same speed ({overhead_pct:+.1f}%)")

        print()

    if not any_found:
        print("No benchmark CSVs found. Run 'make bench' first.")
        sys.exit(1)

    # Overall verdict
    print("-" * 60)
    print("  Overall verdict")
    print("-" * 60)

    ratios = []
    for filename, _ in CASES:
        rows = load_csv(filename)
        if rows is None:
            continue
        tools = {}
        for row in rows:
            tools[identify_tool(row["command"])] = row
        if "dsrc" in tools and "nim" in tools:
            ratios.append(float(tools["nim"]["mean"]) / float(tools["dsrc"]["mean"]))

    if ratios:
        avg_ratio = sum(ratios) / len(ratios)
        avg_overhead = (avg_ratio - 1) * 100
        print(f"  Average across {len(ratios)} cases: Nim is {avg_ratio:.2f}x vs C++")
        print(f"  Mean overhead: {avg_overhead:+.0f}%")
        print()
        if avg_overhead < 10:
            print("  The Nim wrapper adds minimal overhead over the native C++ dsrc tool.")
        elif avg_overhead < 30:
            print("  The Nim wrapper has moderate overhead compared to the C++ dsrc tool.")
        else:
            print("  The Nim wrapper is noticeably slower than the C++ dsrc tool.")
    print()


if __name__ == "__main__":
    main()
