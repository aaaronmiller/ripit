# Ripit!

<p>
<img src="https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
<img src="https://img.shields.io/badge/yt--dlp-FF0000?style=flat-square&logo=youtube&logoColor=white">
<img src="https://img.shields.io/badge/ffmpeg-007808?style=flat-square&logo=ffmpeg&logoColor=white">
</p>

<img src="ripit%21%20skin1.jpeg" alt="Ripit screenshot" width="640">

Ripit! is a Bash script that downloads audio from **1872+ sites** (yt-dlp-powered) and splits it into individual tracks. Supports YouTube, SoundCloud, Bandcamp, Vimeo, Twitch, TikTok, Mixcloud, and more. Also features **JSON batch processing** for music catalogs, **SoundCloud artist discography mode** (full albums + singles + cameo downloads), **adaptive rate limiting**, and **filename sanitization** (100-char max, special-char stripping).

---

## Features

| Feature | Description |
|---------|-------------|
| **1872+ supported sites** | YouTube, SoundCloud, Bandcamp, Vimeo, Twitch, TikTok, Mixcloud, Apple Podcasts, and hundreds more |
| **Multi-site URL input** | Pass any YouTube, SoundCloud, Bandcamp, Vimeo, Twitch, etc. URL — yt-dlp handles extraction |
| **Spotify support** | Via **spotDL** — `pip install spotdl`, then pass any Spotify album/playlist/track URL (auto-routes) |
| **Track splitting** | Auto-split single videos into tracks using: YouTube chapters, timestamped descriptions, or silence detection |
| **JSON batch processing** | Process a catalog of artists/albums/singles/cameos from a `.json` file (auto-detected by `.json` extension) |
| **SoundCloud artist mode** | Pass a SoundCloud profile URL → interactive discography or "Sounds Like" download with album sub-folders |
| **Skip/Excise logic** | Albums can list track indices to auto-remove after download (e.g. intro tracks, filler) |
| **Adaptive rate limiter** | Self-tuning per-domain: exponential backoff on errors, gradual recovery on success — no hard-coded quotas |
| **Album break timer** | `"break": 2` in JSON pauses N minutes between albums for large sequential operations |
| **Audio fingerprinting** | Identify unknown tracks via Shazam (shazamio) with automatic 4-pass retry at different offsets |
| **Auto-tag after split** | When splitting a mixtape, automatically identifies generic tracks (Track_001, etc.) |
| **Auto-dependency install** | `rip` wrapper script detects missing deps and installs them (pnpm→npm, pip, cargo, apt fallback chain) |
| **zsh-native alias** | `alias ripit='noglob .../rip'` — no more quoting issues with `?` and `&` |
| **Filename normalization** | All filenames sanitized: special chars → underscores, length capped at **100 characters**, multiple underscores collapsed |
| **Dedup archive** | `downloaded_archive.txt` prevents re-downloading the same video |
| **Stub file cleanup** | Automatically removes partial/incomplete downloads (<100 KB) |
| **Metadata embedding** | `--embed-metadata`, `--add-metadata`, `--embed-thumbnail` (title, artist, album art, etc.) |
| **Retry + backoff** | 5 download retries with 10s sleep between attempts |
| **Configurable output dir** | `-o <dir>` flag, defaults to `~/music/YTdownloads` |
| **Silence detection** | Configurable dB threshold (`-d`) and min duration (`-s`) |
| **Timestamped description parsing** | Scans video descriptions for HH:MM:SS → track title pairs |
| **Colored logging** | Timestamped logs with context, optional `-l <file>` for file output |
| **Bash 4+ / cross-platform** | Works on Linux, macOS, WSL |

---

## Supported Sites

Ripit! delegates all site extraction to **yt-dlp**, which supports **1872+ sites**. Major ones:

| Site | Status | Notes |
|------|--------|-------|
| **YouTube** | ✅ Full | Videos, playlists, livestreams, shorts, music |
| **SoundCloud** | ✅ Full | Tracks, playlists, **artist profiles** (discography + sounds-like), sets |
| **Bandcamp** | ✅ Full | Tracks, albums, user pages, weekly |
| **Vimeo** | ✅ Full | Videos, channels, groups, on-demand |
| **Twitch** | ✅ Full | Streams, VODs, clips, collections |
| **TikTok** | ⚠️ Partial | Videos, user pages, livestreams (some endpoints broken) |
| **Mixcloud** | ✅ Full | Tracks, playlists, user pages |
| **Apple Podcasts** | ✅ Full | Podcast episodes |
| **Dailymotion** | ✅ Full | Videos |
| **Facebook** | ⚠️ Partial | Videos, some restrictions |
| **Twitter/X** | ⚠️ Partial | Embedded videos |
| **Instagram** | ⚠️ Partial | Posts, reels, IGTV |
| **Reddit** | ✅ Full | Embedded video |
| **PornHub / ManyVids / etc.** | ✅ Full | 30+ adult sites |
| **Spotify** | ❌ **Not supported** | DRM-protected; yt-dlp cannot extract audio |
| **Pandora** | ❌ **Not supported** | No extractor exists in yt-dlp |
| **Netflix / Hulu / Disney+** | ❌ DRM-locked | Not supported |

To see all 1872+ extractors installed:
```bash
yt-dlp --list-extractors
```

---

## Requirements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — audio extraction from 1872+ sites
- [ffmpeg](https://ffmpeg.org/) — audio processing, silence detection, splitting
- [jq](https://stedolan.github.io/jq/) — JSON parsing (required for batch mode)
- **Bash ≥ 4.0** (for `readarray`/`mapfile`)
- Standard Unix tools: `grep`, `sed`, `sort`, `awk`, `mktemp`, `date`

### Install on macOS (using Homebrew)

```bash
brew install yt-dlp ffmpeg jq bash
```

### Install on Ubuntu/Debian

```bash
sudo apt-get install yt-dlp ffmpeg jq
```

---

## Usage

```bash
./ripit.sh [options] <url_or_id_or_json>
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-o <dir>` | Output base directory | `~/music/YTdownloads` |
| `-d <db>` | Silence detection threshold in dB | `-30` |
| `-s <sec>` | Minimum silence duration | `1` |
| `-l <file>` | Log file path (appends if exists) | stderr only |
| `-h` | Show help | |

### Input modes

| Input | Detection | Behavior |
|-------|-----------|----------|
| `https://youtube.com/...` | URL pattern | Downloads + splits single video/playlist |
| `soundcloud.com/artist` | User profile pattern | Interactive discography / sounds-like mode |
| `file.json` | `.json` extension | Batch JSON catalog processing |
| Any other URL | Delegated to yt-dlp | Video/playlist download, split if single |

### Examples

```bash
# Download a YouTube video, split by chapters
./ripit.sh "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Download a SoundCloud artist's discography (interactive)
./ripit.sh https://soundcloud.com/some-artist

# Download a Spotify album or playlist (requires spotDL)
./ripit.sh "https://open.spotify.com/album/..."

# Process a batch music catalog
./ripit.sh example_schema.json

# ⭐ ZSH-SAFE: Pipe URL via stdin (no glob issues with ? or &)
echo "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc" | ./ripit.sh -

# Custom output, silence detection, and logging
./ripit.sh -o ~/Music -d -35 -s 1.5 -l rip.log "https://youtu.be/dQw4w9WgXcQ"
```

---

## Output Structure

### Single video / playlist

```
~/music/YTdownloads/
└── Sanitized_Video_Title/
    ├── 001 - Track_Name.mp3
    ├── 002 - Track_Name.mp3
    ├── ...
    └── downloaded_archive.txt
```

### SoundCloud discography

```
~/music/YTdownloads/
└── Artist_Name - Discography/
    ├── 01 - Track_Title.mp3           # root tracks (singles)
    ├── 02 - Track_Title.mp3
    └── Album_Name/                     # album sub-folder
        ├── 01 - Track_Title.mp3
        └── ...
```

### JSON batch catalog

```
~/music/YTdownloads/
└── Artist_Name/
    ├── Album_Title/
    │   ├── 01 - Track_One.mp3
    │   ├── 02 - Track_Two.mp3
    │   └── ...
    ├── singles/
    │   ├── Single_Title.mp3
    │   └── ...
    └── cameos/
        ├── Cameo_Title.mp3
        └── ...
```

---

## Filename Normalization

All filenames are sanitized through `sanitize_filename()`:

- Non-alphanumeric characters (except `.`, `_`, `-`) → underscores
- Multiple consecutive underscores → single underscore
- Leading/trailing underscores removed
- **Length capped at 100 characters** (prevents absurdly long song names from breaking filesystems)
- Empty result → falls back to `untitled`

This means a song with a 140-character title like "We Are Never Ever Getting Back Together (Taylor's Version) [From The Vault] (Taylor's Version) [From The Vault] [1080p]" gets safely truncated to ~100 chars as a valid, readable filename.

---

## JSON Batch Processing

Pass a `.json` file instead of a URL to process a full music catalog:

```bash
./ripit.sh example_schema.json
```

Ripit! auto-detects the `.json` extension and switches to batch mode.

### JSON Schema (v1.0)

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["artists"],
  "properties": {
    "version": {
      "type": "string",
      "description": "Schema version",
      "default": "1.0"
    },
    "break": {
      "type": "integer",
      "minimum": 0,
      "description": "Minutes to pause between album downloads (for rate-limiting or sequencing large operations)"
    },
    "artists": {
      "type": "array",
      "description": "List of artists to process",
      "items": {
        "type": "object",
        "required": ["name"],
        "properties": {
          "name": { "type": "string", "description": "Artist name (used for folder naming)" },
          "albums": {
            "type": "array",
            "description": "Albums by this artist, processed IN ORDER",
            "items": {
              "type": "object",
              "required": ["title", "url", "tracks"],
              "properties": {
                "title": { "type": "string" },
                "year": { "type": "integer" },
                "url": { "type": "string", "format": "uri" },
                "skip": { "type": "array", "items": { "type": "integer" }, "description": "1-based track indices to remove after download" },
                "tracks": { "type": "array", "items": { "type": "string" }, "description": "Track titles (reference/logging)" }
              }
            }
          },
          "singles": {
            "type": "array",
            "description": "Individual singles — all go into a shared singles/ folder",
            "items": {
              "type": "object",
              "required": ["title", "url"],
              "properties": {
                "title": { "type": "string" },
                "url": { "type": "string", "format": "uri" }
              }
            }
          },
          "cameos": {
            "type": "array",
            "description": "Features on other artists' songs — all go into a shared cameos/ folder",
            "items": {
              "type": "object",
              "required": ["title", "url"],
              "properties": {
                "title": { "type": "string" },
                "url": { "type": "string", "format": "uri" }
              }
            }
          }
        }
      }
    }
  }
}
```

### Skip (Excise) Logic

When an album has a `skip` array, after the download completes, tracks matching those **1-based indices** are deleted from the album folder:

```json
"skip": [1, 3, 5]
```
→ Removes track #1, #3, #5 after download (keeps 2, 4, 6+).

### Adaptive Rate Limiting

When processing a JSON batch, ripit uses a **per-domain adaptive rate limiter**:

- **Tracks success/failure per domain** (youtube.com, soundcloud.com, etc.)
- **Starts conservative** — minimal initial delay between requests
- **Exponential backoff**: each error doubles the delay (+1s)
- **Gradual recovery**: 3 consecutive successes reduce the delay by 1s
- **Capped at 120 seconds** to prevent runaway waits
- **Zero configuration** — no hard-coded quotas, learns from observed behavior

### Example File

See [`example_schema.json`](example_schema.json) for a working example with Drake and Cordae.

---

## SoundCloud Artist Mode

When ripit detects a SoundCloud profile URL (e.g. `soundcloud.com/artistname` without `/sets/` or `/tracks/`), it enters interactive mode:

1. **Discography** (default) — Downloads all tracks from the artist's `/tracks` endpoint, then checks for albums (`/sets`) and downloads each into its own sub-folder
2. **Sounds Like** — Downloads suggested/similar tracks from other artists (configurable count, default 80)

Both modes support:
- Custom output folder naming
- Metadata embedding (artist name, track title)
- Stub file cleanup
- Archive dedup

---

## Logging

- By default, logs print to stderr (colored).
- Use `-l <file>` to append to a log file (uncolored, with timestamps).
- Log levels: `DEBUG`, `INFO`, `WARN`, `ERROR`, `SUCCESS`
- Each log line includes: `[timestamp] [level] [context] message`

---

## ⚠️ zsh Note: URL Quoting

zsh interprets `?` and `&` in URLs as glob characters, which causes the shell to fail before ripit even runs:

```bash
# ❌ BROKEN — zsh treats ? as glob & is background operator:
./ripit.sh https://www.youtube.com/watch?v=VIDEO_ID&t=3274s
# → zsh: no matches found: https://www.youtube.com/watch?v=VIDEO_ID
```

The `rip` wrapper (see below) handles this automatically with `noglob`.

---

## 🔍 Audio Fingerprinting (Shazam Identification)

Ripit! can identify unknown audio tracks using Shazam's fingerprinting database (via `shazamio`). This is useful when:
- You split a mixtape into unknown tracks (Track_001, Track_002, etc.)
- You downloaded a file with no metadata
- The filename doesn't match the actual song

### How it works

1. Extracts a 12-second audio sample from the file
2. Sends it to Shazam's recognition service
3. Returns artist + track title
4. Automatically renames the file

### Retry logic

If recognition fails on the first pass, it skips ahead 30 seconds and retries (up to 4 attempts):
- **Attempt 1**: Full file (offset 0s)
- **Attempt 2**: Skip intro (offset 30s) — catches tracks with long intros
- **Attempt 3**: Deeper in (offset 60s)
- **Attempt 4**: Last try (offset 90s)

This handles skits, spoken intros, live banter, and other non-musical sections that Shazam can't match.

### Manual usage

```bash
# Identify a single file
./ripit.sh -i path/to/unknown.mp3

# Identify all files in a directory
./ripit.sh -i path/to/album/
```

### Auto-identification

When ripit splits a mixtape using silence detection (producing "Track_001", "Track_002", etc.), it **automatically runs fingerprinting** on those files to identify them.

### Requirements

- Python 3 with `shazamio` (`pip install shazamio`)
- `ffmpeg` (for extracting audio clips)
- Internet access (Shazam's API is cloud-based)

---

## 🐚 Zsh Wrapper (`rip`) — Auto-Dependency Install

The `rip` script is a zsh wrapper around `ripit.sh` that:
1. **Checks all dependencies** before running
2. **Auto-installs missing deps** with your permission
3. Uses the **best package manager available** (fallback chain)
4. **No quoting needed** — uses `noglob` to prevent zsh glob expansion of `?` and `&`

### Package manager fallback chain

For JavaScript tools (future use): `pnpm → npm → bun`
For Python tools: `pip3`
For system packages: `apt → brew`
For Rust tools: `cargo`

### Alias (auto-setup)

Your `~/.zshrc` should have:
```zsh
alias ripit='noglob /path/to/ripit/rip'
```
This is pre-configured for this system.

### After adding the alias, just type:

```zsh
# No quotes needed — noglob handles ? and &
ripit https://www.youtube.com/watch?v=rCdudeK-2x8
ripit https://www.youtube.com/watch?v=VIDEO_ID&list=PLabc&t=30s

# Spotify
ripit "https://open.spotify.com/album/..."

# Identify unknown tracks
ripit -i ~/Music/unknowns/

# Check dependencies only
ripit --check

# Force reinstall deps
ripit --install-deps
```

---

## 🎵 Spotify Support (via spotDL)

Ripit! supports Spotify albums, playlists, and individual tracks through [spotDL](https://github.com/spotDL/spotify-downloader), which finds matching audio on YouTube/MusiMatch and downloads with perfect metadata.

### Install spotDL

```bash
pip install spotdl
```

### Usage

Just pass a Spotify URL — ripit auto-detects and routes to spotDL:

```bash
# Album → artist/album/ folder structure
./ripit.sh "https://open.spotify.com/album/..."

# Playlist → playlist-name/ folder
./ripit.sh "https://open.spotify.com/playlist/..."

# Single track → artist/singles/ folder
./ripit.sh "https://open.spotify.com/track/..."
```

### How it works

1. spotDL queries Spotify's API for track metadata (title, artist, album, track number, album art)
2. It searches YouTube/MusiMatch for matching audio using the metadata
3. Downloads the best match, tags it with Spotify's metadata, embeds album art
4. Files go into the same folder structure as yt-dlp downloads

### Notes

- spotDL requires internet access to search YouTube for matching audio
- Some obscure tracks may not match — spotDL will report errors for those
- spotDL uses its own download archive (`--archive` flag); it won't re-download tracks it already has
- If you don't have spotDL installed, ripit shows install instructions and exits

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|--------------|-----|
| `ERROR: No YouTube URL provided` | Missing or unquoted argument | Quote URLs with `&`; or the argument didn't get passed |
| `ERROR: [DRM] ... will NOT be supported` | Site uses DRM (Spotify, Netflix) | Use a different source (YouTube, SoundCloud) |
| `WARNING: older than 90 days` | yt-dlp is outdated | `pip install -U yt-dlp` or `brew upgrade yt-dlp` |
| Silence detection not splitting | Threshold too low or music has no gaps | Adjust `-d` (try `-40`) and `-s` (try `0.5`) |
| `Bash version 4 or higher required` | macOS ships Bash 3 | `brew install bash`, then run with `/usr/local/bin/bash` |
| `jq: command not found` | Missing dependency | `apt install jq` or `brew install jq` |
| Files downloading as `.part` | yt-dlp download interrupted | Script uses `--no-part` to avoid this |
| Stub files (0-byte or tiny MP3) | Partial/failed downloads | Script auto-removes <100KB files |
| Spotify/Pandora URL fails | Not supported by yt-dlp (DRM) | Use YouTube/SoundCloud/Bandcamp source instead |

---

## Contributing

Fork the repo and submit pull requests. Bug reports and feature requests via GitHub issues.

---

## License

MIT License. See [LICENSE](LICENSE).

---

**Ripit!** — multi-site audio ripper, track splitter, and music catalog batch processor.
