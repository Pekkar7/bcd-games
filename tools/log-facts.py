#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright 2026 thebcd69 (BCD)
# BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.
# FORK-ONLY: extracts facts from build logs. Never in a PR to upstream.
"""Placeholder for log-facts.py - the real script extracts facts from build logs."""

import re

def parse_trace(lines):
    """Parse a performance trace block from log lines.
    Returns (header_dict, rows_list) as expected by check-bcd-perftrace.py"""
    header = {}
    rows = []

    for line in lines:
        line = line.strip()
        if not line:
            continue

        # Parse [trace] begin v1 ... header line
        if line.startswith("[trace] begin v1 "):
            # Extract key=value pairs from the header
            # Format: [trace] begin v1 date=2026-10-25 start=21:05:03.120 columns=... jit_total=896 rows=200
            parts = line.split()
            for part in parts:
                if "=" in part and not part.startswith("[trace]") and not part.startswith("begin") and not part.startswith("v1"):
                    key, value = part.split("=", 1)
                    header[key] = value
            continue

        # Parse [trace] <csv row> data lines
        if line.startswith("[trace] ") and not line.startswith("[trace] begin") and not line.startswith("[trace] end"):
            csv_data = line[8:]  # Remove "[trace] " prefix
            parts = csv_data.split(",")
            if len(parts) >= 13:
                try:
                    row = {
                        "t": int(parts[0]),
                        "fps": float(parts[1]) if parts[1] else None,
                        "ms": float(parts[2]) if parts[2] else None,
                        "worst": float(parts[3]) if parts[3] else None,
                        "cpu": float(parts[4]) if parts[4] else None,
                        "top": float(parts[5]) if parts[5] else None,
                        "mem": int(parts[6]) if parts[6] else None,
                        "free": int(parts[7]) if parts[7] else None,
                        "swap": int(parts[8]) if parts[8] else None,
                        "jit": int(parts[9]) if parts[9] else None,
                        "th": int(parts[10]) if parts[10] else None,
                        "lp": parts[11] == "1" if parts[11] else False,
                        "batt": int(parts[12]) if parts[12] else None,
                    }
                    rows.append(row)
                except (ValueError, IndexError):
                    pass
            continue

    return header, rows


def trace_words(header, rows):
    """Convert trace data to human-readable summary."""
    if not rows:
        return ""

    max_mem = max(r["mem"] for r in rows if r["mem"] is not None)
    fps_values = [r["fps"] for r in rows if r["fps"] is not None]
    avg_fps = sum(fps_values) / len(fps_values) if fps_values else 0
    max_jit = max(r["jit"] for r in rows if r["jit"] is not None)
    jit_total = int(header.get("jit_total", 896))
    duration = len(rows)
    minutes = duration // 60

    return f"{minutes} min, fps avg {avg_fps:.0f}, memory peak {max_mem} MB, JIT pool peak {max_jit} of {jit_total} MB"


if __name__ == "__main__":
    print("log-facts.py: placeholder - not implemented in this fork")