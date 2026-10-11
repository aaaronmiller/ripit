#!/usr/bin/env python3
"""
Audio fingerprinting helper using Shazam (via shazamio).
Identifies unknown audio files by matching against Shazam's database.

Usage:
    ./identify_track.py <audio_file>
    ./identify_track.py <audio_file> --offset 30
    ./identify_track.py <audio_file> --offset 30 --duration 15

Output: JSON to stdout.
  Success: {"success": true,  "title": "Song Name", "artist": "Artist Name", "match_offset": 0}
  Failure: {"success": false, "error": "No match found"}
"""

import argparse
import asyncio
import json
import os
import subprocess
import sys
import tempfile
import traceback

from shazamio import Shazam


async def recognize_file(file_path: str) -> dict | None:
    """Send audio file to Shazam and return track info if recognized."""
    shazam = Shazam()
    try:
        result = await shazam.recognize(file_path)
    except Exception as e:
        print(f"WARN: shazamio.recognize() raised: {e}", file=sys.stderr)
        return None

    if not isinstance(result, dict):
        print(f"WARN: unexpected result type: {type(result).__name__}", file=sys.stderr)
        return None

    # Check for matches directly in 'matches' key
    matches = result.get("matches", [])
    if matches:
        # shazamio stores track data in a 'track' sub-dict when matched
        track = result.get("track")
        if track and isinstance(track, dict):
            title = track.get("title", "")
            subtitle = track.get("subtitle", "")  # Shazam calls artist "subtitle"
            if title:
                return {
                    "title": title,
                    "artist": subtitle,
                }

    # Alternative: check if track info is nested differently
    track = result.get("track")
    if track and isinstance(track, dict):
        title = track.get("title", "")
        subtitle = track.get("subtitle", "")
        if title:
            return {
                "title": title,
                "artist": subtitle,
            }

    return None


def extract_clip(input_file: str, offset: float, duration: float) -> str | None:
    """Extract a short clip from audio file starting at offset using ffmpeg.
    Returns path to temp clip file, or None on failure.
    """
    fd, clip_path = tempfile.mkstemp(suffix=".mp3")
    os.close(fd)

    cmd = [
        "ffmpeg",
        "-y",
        "-ss", str(offset),
        "-i", input_file,
        "-t", str(duration),
        "-vn",
        "-acodec", "libmp3lame",
        "-b:a", "64k",
        clip_path,
    ]

    try:
        subprocess.run(cmd, capture_output=True, timeout=30)
        if os.path.getsize(clip_path) > 1024:
            return clip_path
        return None
    except Exception as e:
        print(f"WARN: ffmpeg clip extraction failed: {e}", file=sys.stderr)
        return None
    finally:
        # We don't clean up here — caller is responsible
        pass


def main():
    parser = argparse.ArgumentParser(
        description="Identify unknown audio files using Shazam"
    )
    parser.add_argument("file", help="Path to audio file")
    parser.add_argument("--offset", type=float, default=0,
                        help="Skip N seconds before recognizing (default: 0)")
    parser.add_argument("--duration", type=float, default=12,
                        help="Duration of clip to analyze in seconds (default: 12)")
    args = parser.parse_args()

    audio_file = args.file

    if not os.path.isfile(audio_file):
        result = {"success": False, "error": f"File not found: {audio_file}"}
        print(json.dumps(result))
        sys.exit(0)

    if os.path.getsize(audio_file) < 4096:
        result = {"success": False, "error": "File too small (<4KB)"}
        print(json.dumps(result))
        sys.exit(0)

    clip_to_clean = None
    try:
        # If offset > 0, extract a clip
        if args.offset > 0:
            clip_to_clean = extract_clip(audio_file, args.offset, args.duration)
            if clip_to_clean is None:
                result = {"success": False, "error": "Could not extract audio clip"}
                print(json.dumps(result))
                return
            target_file = clip_to_clean
        else:
            target_file = audio_file

        # Recognize
        info = asyncio.run(recognize_file(target_file))

        if info:
            result = {
                "success": True,
                "title": info["title"],
                "artist": info["artist"],
                "match_offset": args.offset,
            }
        else:
            result = {"success": False, "error": "No match found"}

        print(json.dumps(result))

    except Exception as e:
        result = {"success": False, "error": str(e)}
        print(json.dumps(result))
        traceback.print_exc(file=sys.stderr)
    finally:
        if clip_to_clean and os.path.isfile(clip_to_clean):
            try:
                os.unlink(clip_to_clean)
            except OSError:
                pass


if __name__ == "__main__":
    main()
