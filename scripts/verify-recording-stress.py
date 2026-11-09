#!/usr/bin/env python3
"""Read-only, independent ffmpeg/ffprobe checks for stress-recording.swift.

Usage: scripts/verify-recording-stress.py /path/to/metrics.jsonl
Prints JSON; exits nonzero on a failed media check. No third-party Python modules.
Synthetic timestamps and marker alignment do not measure physical-device drift.
"""
import array
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, check=True)
    return result.stdout, result.stderr


def inspect(path):
    output, _ = run(["ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format", "-of", "json", str(path)])
    metadata = json.loads(output)
    # Preserve the demuxer's clock. Rounding sparse/VFR samples to a default
    # 30-fps null-muxer clock can invent duplicate DTS errors at a short tail.
    _, errors = run(["ffmpeg", "-v", "error", "-i", str(path), "-map", "0",
        "-fps_mode:v", "passthrough", "-enc_time_base:v", "-1", "-f", "null", "-"])
    require(not errors.strip(), f"Decode errors in {path}: {errors.decode()}")
    video = [s for s in metadata["streams"] if s["codec_type"] == "video"]
    audio = [s for s in metadata["streams"] if s["codec_type"] == "audio"]
    require(len(video) == 1 and len(audio) == 2, f"Missing tracks in {path}")
    require(video[0]["codec_name"] == "h264" and all(s["codec_name"] == "aac" for s in audio), "Unexpected codecs")
    require((video[0]["width"], video[0]["height"]) == (1920, 1080), "Unexpected video dimensions")
    require([s["channels"] for s in audio] == [1, 2], "Microphone/system channel layout changed")
    return {
        "bytes": int(metadata["format"]["size"]),
        "video_duration": float(video[0]["duration"]),
        "video_frames": int(video[0]["nb_read_frames"]),
        "audio_durations": [float(s["duration"]) for s in audio],
        "audio_channels": [int(s["channels"]) for s in audio],
    }


def video_marker(path, seconds):
    pixels, _ = run(["ffmpeg", "-v", "error", "-ss", str(seconds), "-i", str(path),
        "-map", "0:v:0", "-frames:v", "1", "-vf", "crop=1000:128:0:0", "-pix_fmt", "gray", "-f", "rawvideo", "-"])
    require(len(pixels) == 1000 * 128, f"No marker frame at {seconds}s")
    counter = sum((1 << bit) for bit in range(24) if pixels[32 * 1000 + 32 + bit * 40] > 128)
    return {"requested_time": seconds, "source_frame": counter, "source_time": counter / 30,
            "pulse": pixels[96 * 1000 + 48] > 128}


def audio_marker(path, track, channels, marker_time):
    start = max(0, marker_time - 0.2)
    raw, _ = run(["ffmpeg", "-v", "error", "-ss", str(start), "-i", str(path), "-t", "0.5",
        "-map", f"0:a:{track}", "-ar", "48000", "-ac", str(channels), "-c:a", "pcm_f32le", "-f", "f32le", "-"])
    values = array.array("f")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()
    block = 48 * channels  # one-millisecond RMS windows
    for position in range(0, len(values) - block + 1, block):
        rms = math.sqrt(sum(v * v for v in values[position:position + block]) / block)
        if rms > 0.15:
            onset = start + position / channels / 48000
            require(abs(onset - marker_time) < 0.025, f"Audio marker shifted: {onset} vs {marker_time}")
            return {"track": track, "expected": marker_time, "onset": onset, "error_ms": (onset - marker_time) * 1000}
    raise RuntimeError(f"No audio marker at {marker_time}s in track {track}")


def main():
    require(len(sys.argv) == 2, __doc__)
    events = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
    require(events and events[0]["event"] == "start", "Missing start record")
    require(events[-1]["event"] == "complete", "The recording has not completed successfully")
    start, complete = events[0], events[-1]
    seconds = start["seconds"]
    directory = Path(start["directory"])
    final_path = directory / "recording.mp4"
    final = inspect(final_path)
    snapshot = inspect(directory / "while-recording.mp4")
    for duration in [final["video_duration"]] + final["audio_durations"]:
        require(abs(duration - seconds) < 0.05, f"Unexpected final track duration: {duration}")
    require(seconds / 2 - 20 <= snapshot["video_duration"] <= seconds / 2 + 1, "Incomplete snapshot recovery")
    require(final["video_frames"] in [complete["frames"], complete["frames"] + 1], "Encoded frame count differs from accepted buffers")
    expected_source_frames = (seconds // 120 * 60 + min(seconds % 120, 60)) * 30
    require(complete["sourceFrames"] == expected_source_frames, "Some generated source frames were rejected")
    require(complete["droppedFrames"] == 0, "Encoder backpressure dropped video frames")
    cycle = (seconds - 1) // 120 * 120
    last_pulse = cycle + min(50, (seconds - cycle - 1) // 10 * 10)
    pulse_times = sorted({0, last_pulse})
    markers = [video_marker(final_path, t) for t in pulse_times]
    for marker in markers:
        require(abs(marker["source_time"] - marker["requested_time"]) <= 1 / 30 + 0.0001, "Video counter/timeline mismatch")
        require(marker["pulse"], "Video pulse missing")
    audio_markers = [audio_marker(final_path, track, channels, t)
                     for track, channels in enumerate(final["audio_channels"]) for t in pulse_times]
    samples = [e for e in events if e["event"] == "sample"]
    steady = [s for s in samples if s["elapsed"] >= min(120, seconds / 4)]
    require(bool(steady), "No steady-state memory samples")
    early = steady[:min(18, len(steady))]
    late = steady[-min(18, len(steady)):]
    memory = {
        "peak_mib": max(s["residentBytes"] for s in samples) / 1024**2,
        "early_steady_mib": statistics.mean(s["residentBytes"] for s in early) / 1024**2,
        "late_steady_mib": statistics.mean(s["residentBytes"] for s in late) / 1024**2,
    }
    memory["late_minus_early_mib"] = memory["late_steady_mib"] - memory["early_steady_mib"]
    print(json.dumps({"final": final, "snapshot": snapshot, "memory": memory,
        "video_markers": markers, "audio_markers": audio_markers, "writer_completion": complete}, indent=2))


if __name__ == "__main__":
    main()
