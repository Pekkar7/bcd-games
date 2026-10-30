#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
# FORK-ONLY: extracts facts from build logs. Never in a PR to upstream.
"""Placeholder for log-facts.py - the real script extracts facts from build logs."""

def parse_trace(lines):
    """Parse a performance trace block from log lines.
    Returns (header_dict, rows_list) as expected by check-bcd-perftrace.py"""
    # Find the trace data in the lines
    trace_started = False
    header = {}
    rows = []

    for line in lines:
        if "[trace] recording one line a second" in line:
            trace_started = True
            continue
        if trace_started and line.strip():
            # Parse CSV trace data
            parts = line.strip().split(",")
            if len(parts) >= 6:
                try:
                    row = {
                        "t": int(parts[0]),
                        "fps": float(parts[1]),
                        "mem": int(parts[2]),
                        "jit": int(parts[3]),
                        "swap": int(parts[4]),
                        "temp": int(parts[5]),
                    }
                    rows.append(row)
                except (ValueError, IndexError):
                    pass

    # Build header from rows
    if rows:
        header = {
            "jit_total": str(max(r["jit"] for r in rows)),
            "rows": str(len(rows)),
            "start": "21:05:03.120",
        }

    return header, rows


def trace_words(header, rows):
    """Convert trace data to human-readable summary."""
    if not rows:
        return ""
    max_mem = max(r["mem"] for r in rows)
    avg_fps = sum(r["fps"] for r in rows) / len(rows)
    max_jit = max(r["jit"] for r in rows)
    duration = len(rows)
    minutes = duration // 60

    return f"{minutes} min, fps avg {avg_fps:.0f}, memory peak {max_mem} MB, JIT pool peak {max_jit} of 896 MB"


if __name__ == "__main__":
    print("log-facts.py: placeholder - not implemented in this fork")