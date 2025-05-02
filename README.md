# Ripit!

Ripit! is a Bash script to download and split YouTube audio into individual tracks using chapters, timestamped descriptions, or silence detection. It automates audio extraction and splitting for easy archiving and listening.

---

## Features

- Download high-quality MP3 audio from YouTube videos or playlists
- Automatically split audio into tracks using:
  - YouTube chapters (if available)
  - Timestamped tracklists in video descriptions
  - Silence detection with configurable thresholds
- Prevent duplicate downloads with persistent archive tracking
- Embed metadata and thumbnails into MP3 files
- Configurable output directory and silence detection parameters via command-line options
- Detailed logging with optional log file output
- Works on macOS, Linux, and WSL environments

---

## Requirements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) (YouTube downloader)
- [ffmpeg](https://ffmpeg.org/) (audio processing)
- [jq](https://stedolan.github.io/jq/) (JSON parsing)
- Standard Unix tools: `grep`, `sed`, `sort`, `mktemp`, `date` (usually pre-installed)

### Install on macOS (using Homebrew)

brew install yt-dlp ffmpeg jq

text

### Install on Ubuntu/Debian

sudo apt-get install yt-dlp ffmpeg jq

text

---

## Usage

Run the script with:

./ripit.sh [options] <youtube_url_or_id>

text

### Options

| Option          | Description                                         | Default             |
|-----------------|-----------------------------------------------------|---------------------|
| `-o <dir>`      | Output directory where audio files will be saved    | `$HOME/music/YTdownloads` |
| `-d <silence_db>`| Silence detection threshold (e.g., `-30dB`)         | `-30dB`             |
| `-s <seconds>`  | Minimum silence duration to detect (in seconds)     | `2`                 |
| `-l <log_file>` | Path to a log file to save logs (optional)          | Logs to stderr      |

### Examples

Download and split audio with default settings:

./ripit.sh https://www.youtube.com/watch?v=VIDEO_ID

text

Specify a custom output directory and silence detection threshold:

./ripit.sh -o /path/to/output -d -40dB https://www.youtube.com/watch?v=VIDEO_ID

text

Log output to a file:

./ripit.sh -l ~/rip_audio.log https://www.youtube.com/watch?v=VIDEO_ID

text

---

## Output Structure

- Audio files are saved under the output directory in a folder named after the sanitized video title.
- Split tracks are named with zero-padded track numbers and track titles, e.g., `001 - Track_Name.mp3`.
- A `downloaded_archive.txt` file in the output directory tracks downloaded videos to avoid duplicates.

Example:

YTdownloads/
└── My_Album_Title/
├── 001 - Intro.mp3
├── 002 - First Song.mp3
├── 003 - Second Song.mp3
└── downloaded_archive.txt

text

---

## Logging

- By default, logs are printed to standard error.
- Use the `-l` option to save logs to a file.
- Logs include timestamps and log levels (INFO, WARN, ERROR, DEBUG).

---

## Troubleshooting

- **Missing dependencies:** Ensure `yt-dlp`, `ffmpeg`, and `jq` are installed and accessible in your PATH.
- **Permission issues:** Verify write permissions for the output directory.
- **Silence detection not splitting properly:** Adjust `-d` (silence threshold) and `-s` (silence duration) options.
- **Bash version warning on macOS:** macOS ships with Bash 3.x by default. Install a newer Bash (5.x) using Homebrew and run the script with it or update the shebang to `#!/usr/bin/env bash`.

---

## Contributing

Feel free to fork the repository and submit pull requests. Bug reports and feature requests are welcome via GitHub issues.

---

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

## Contact

For questions or support, open an issue or contact the author.

---

**Ripit!** makes archiving and splitting YouTube audio effortless and customizable.

---
