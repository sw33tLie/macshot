#!/usr/bin/env python3
"""Independently decode probe-long-video-export.swift's synthetic writer fixture.

Usage: scripts/verify-long-video-export.py /path/to/export.jsonl
Requires ffmpeg/ffprobe. Reads only; prints JSON and fails on missing tracks,
decode errors, altered duration/frame count, or displaced synthetic AV markers.
"""
import importlib.util
import json
from pathlib import Path
import statistics
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("recording_verifier", Path(__file__).with_name("verify-recording-stress.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def main():
    verify.require(len(sys.argv) == 2, __doc__)
    events = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
    verify.require(events[0]["event"] == "prepared" and events[-1]["event"] == "complete", "Export did not finish")
    prepared, complete = events[0], events[-1]
    source = verify.inspect(Path(prepared["source"]))
    output = verify.inspect(Path(complete["output"]))
    verify.require(source["video_frames"] == output["video_frames"], "Transcode lost or duplicated frames")
    verify.require(source["audio_channels"] == output["audio_channels"], "Audio layout changed")
    for actual in [output["video_duration"]] + output["audio_durations"]:
        verify.require(abs(actual - prepared["duration"]) < 0.05, "Export track duration changed")
    seconds = int(prepared["duration"])
    cycle = (seconds - 1) // 120 * 120
    last_pulse = cycle + min(50, (seconds - cycle - 1) // 10 * 10)
    times = sorted({0, seconds // 240 * 120, last_pulse})
    markers = []
    for time in times:
        before = verify.video_marker(prepared["source"], time)
        after = verify.video_marker(complete["output"], time)
        verify.require(before == after and after["pulse"], "Export video marker changed")
        markers.append(after)
    audio = [verify.audio_marker(complete["output"], track, channels, time)
             for track, channels in enumerate(output["audio_channels"]) for time in times]
    samples = [e["residentBytes"] / 1024**2 for e in events if e["event"] == "sample"]
    print(json.dumps({"source": source, "output": output, "video_markers": markers,
        "audio_markers": audio, "sampled_peak_mib": max(samples),
        "early_mean_mib": statistics.mean(samples[:20]), "late_mean_mib": statistics.mean(samples[-20:]),
        "completion": complete}, indent=2))


if __name__ == "__main__":
    main()
