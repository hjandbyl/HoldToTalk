#!/usr/bin/env python3
"""Sample a running HoldToTalk process and its content-free dictation timings.

Does not start recording, upload audio, change permissions, or launch the app.
Use identical hardware, build configuration, engine/model, and speech for comparisons.
"""
import argparse
import datetime
import json
import math
import platform
import re
import statistics
import subprocess
import threading
import time
from pathlib import Path


def percentile(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def cpu_seconds(text):
    parts = text.split(":")
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total


def sample(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "time=,rss="], capture_output=True, text=True, check=True)
    cpu, rss = result.stdout.split()
    return time.monotonic(), cpu_seconds(cpu), int(rss) / 1024


def compare(current, baseline):
    # Compare timings by engine so cloud and local results cannot hide one another.
    results = {}
    for name in ("cpu_mean_percent", "rss_peak_mib"):
        before, after = baseline.get(name), current.get(name)
        results[name] = delta(before, after)
    current_timings = current.get("timings_by_engine", {})
    baseline_timings = baseline.get("timings_by_engine", {})
    for engine in sorted(current_timings.keys() | baseline_timings.keys()):
        for metric in ("first_frame", "result", "insertion"):
            for quantile in ("p50_ms", "p95_ms"):
                name = f"{metric}_{quantile}"
                before = baseline_timings.get(engine, {}).get(name)
                after = current_timings.get(engine, {}).get(name)
                results[f"{engine}.{name}"] = delta(before, after)
    return results


def delta(before, after):
    if before is None or after is None or before <= 0:
        return {"status": "unmeasured", "before": before, "after": after}
    percent = (after / before - 1) * 100
    return {"status": "regression" if after > before * 1.1 else "within_gate", "change_percent": percent,
            "before": before, "after": after}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, help="Defaults to the single running HoldToTalk process")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--label", default="manual")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    if args.duration <= 0 or args.interval <= 0:
        parser.error("duration and interval must be positive")
    if args.pid is None:
        found = subprocess.run(["/usr/bin/pgrep", "-x", "HoldToTalk"], capture_output=True, text=True).stdout.split()
        if len(found) != 1:
            parser.error("specify --pid when zero or multiple HoldToTalk processes are running")
        args.pid = int(found[0])
    metrics = []
    pattern = re.compile(r"engine=(\w+) outcome=(\w+) firstFrameMs=([-\d.]+) resultMs=([-\d.]+) insertionMs=([-\d.]+) peakBytes=(\d+)")
    predicate = f'subsystem == "com.local.HoldToTalk" AND category == "Dictation" AND processID == {args.pid}'
    logger = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--level", "info", "--predicate", predicate],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def read_metrics():
        for line in logger.stdout:
            try:
                message = json.loads(line).get("eventMessage", "")
            except (ValueError, AttributeError):
                continue
            match = pattern.search(message)
            if match:
                engine, outcome, first, result, insertion, peak = match.groups()
                metrics.append({"engine": engine, "outcome": outcome, "first_frame": float(first),
                                "result": float(result), "insertion": float(insertion), "peak_bytes": int(peak)})

    reader = threading.Thread(target=read_metrics, daemon=True)
    reader.start()
    samples = []
    cpu = []
    try:
        previous = sample(args.pid)
    except (subprocess.CalledProcessError, ValueError):
        logger.terminate()
        logger.wait(timeout=3)
        reader.join(timeout=3)
        logger.stdout.close()
        parser.error("the selected process is not running")
    end = time.monotonic() + args.duration
    stopped = False
    try:
        while time.monotonic() < end:
            time.sleep(max(0, min(args.interval, end - time.monotonic())))
            try:
                current = sample(args.pid)
            except (subprocess.CalledProcessError, ValueError):
                stopped = True
                break
            elapsed = current[0] - previous[0]
            cpu.append(max(0, 100 * (current[1] - previous[1]) / elapsed))
            samples.append(current[2])
            previous = current
    finally:
        logger.terminate()
        try:
            logger.wait(timeout=3)
        except subprocess.TimeoutExpired:
            logger.kill()
        reader.join(timeout=3)
        logger.stdout.close()
    timings = {}
    for engine in sorted({metric["engine"] for metric in metrics}):
        selected = [metric for metric in metrics if metric["engine"] == engine]
        values = {"sessions": len(selected), "failed_sessions": sum(metric["outcome"] == "failed" for metric in selected)}
        for field in ("first_frame", "result", "insertion"):
            valid = [metric[field] for metric in selected if metric[field] >= 0]
            values[field + "_p50_ms"] = percentile(valid, 0.5)
            values[field + "_p95_ms"] = percentile(valid, 0.95)
        values["network_buffer_peak_bytes"] = max(metric["peak_bytes"] for metric in selected)
        timings[engine] = values
    report = {
        "label": args.label, "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(), "pid": args.pid, "duration_seconds": args.duration,
        "process_stopped": stopped, "samples": len(samples),
        "cpu_mean_percent": statistics.mean(cpu) if cpu else None,
        "rss_peak_mib": max(samples) if samples else None,
        "rss_first_mib": samples[0] if samples else None, "rss_last_mib": samples[-1] if samples else None,
        "timings_by_engine": timings,
        "notes": ["A 10% regression requires reproduction under matched conditions.",
                  "No session timings means recognition latency is unmeasured, not zero.",
                  "Insertion timing includes ordered queue wait and event dispatch; it does not confirm editor acceptance."]}
    if args.baseline:
        report["comparison"] = compare(report, json.loads(args.baseline.read_text()))
    output = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output)
    else:
        print(output, end="")
    return 2 if stopped or any(item["status"] == "regression" for item in report.get("comparison", {}).values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
