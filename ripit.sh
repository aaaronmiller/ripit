#!/usr/bin/env bash

# Define colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m' # Bold Yellow for emphasis
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'

# --- Global variable to hold the current context (video/playlist title) ---
# This is simpler than passing it to every log_message call.
# It will be updated after the title is fetched.
CURRENT_LOG_CONTEXT=""

# Colorful ASCII art banner
echo -e "${MAGENTA}"
cat <<'EOF'
  _______    __       _______   __  ___________
 /"      \  |" \     |   __ "\ |" \("     _   ")
|:        | ||  |    (. |__) :)||  |)__/  \\__/
|_____/   ) |:  |    |:  ____/ |:  |   \\_ /
 //      /  |.  |    (|  /     |.  |   |.  |
|:  __   \  /\  |\  /|__/ \    /\  |\  \:  |
|__|  \___)(__\_|_)(_______)  (__\_|_)  \__|
EOF
echo -e "${CYAN}"
cat <<'EOF'
          __      ___       _______   ____  ____  ___      ___
         /""\    |"  |     |   _  "\ ("  _||_ " ||"  \    /"  |
        /    \   ||  |     (. |_)  :)|   (  ) : | \   \  //   |
       /' /\  \  |:  |     |:     \/ (:  |  | . ) /\\  \/.    |
      //  __'  \  \  |___  (|  _  \\  \\ \__/ // |: \.        |
     /   /  \\  \( \_|:  \ |: |_)  :) /\\ __ //\ |.  \    /:  |
    (___/    \___)\_______)(_______/ (__________)|___|\__/|___|
EOF
echo -e "${YELLOW}"
cat <<'EOF'
          _______    _______        __       _______   _______    _______   _______      ___
         /" _   "|  /"      \      /""\     |   _  "\ |   _  "\  /"     "| /"      \    |"  |
        (: ( \___) |:        |    /    \    (. |_)  :)(. |_)  :)(: ______)|:        |   ||  |
         \/ \      |_____/   )   /' /\  \   |:     \/ |:     \/  \/    |  |_____/   )   |:  |
         //  \ ___  //      /   //  __'  \  (|  _  \\ (|  _  \\  // ___)_  //      /   _|  /
        (:   _(  _||:  __   \  /   /  \\  \ |: |_)  :)|: |_)  :)(:      "||:  __   \  / |_/ )
         \_______) |__|  \___)(___/    \___)(_______/ (_______/  \_______)|__|  \___)(_____/
EOF
echo -e "${RESET}"
echo -e "${BOLD}${GREEN}🎵 YouTube Audio Ripper & Track Splitter 🎵${RESET}"
echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo

# --- Logging Function with colors and context ---
log_message() {
  # Usage: log_message LEVEL "Message" [COLOR_OVERRIDE]
  local level="$1"
  local message="$2"
  local color_override="${3:-}" # Optional color override
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local color_code="${RESET}"
  local emoji=""

  case "$level" in
    "INFO")    color_code="${GREEN}"; emoji="ℹ️ " ;;
    "WARN")    color_code="${YELLOW}"; emoji="⚠️ " ;;
    "ERROR")   color_code="${RED}"; emoji="❌ " ;;
    "DEBUG")   color_code="${BLUE}"; emoji="🔍 " ;;
    "SUCCESS") color_code="${GREEN}"; emoji="✅ " ;;
  esac

  # Apply override if provided
  if [ -n "$color_override" ]; then
      color_code="$color_override"
  fi

  # Prepare context string (if CURRENT_LOG_CONTEXT is set)
  local context_str=""
  if [ -n "$CURRENT_LOG_CONTEXT" ]; then
      # Ensure context doesn't contain control characters that might break `echo -e`
      local clean_context
      clean_context=$(echo "$CURRENT_LOG_CONTEXT" | tr -d '[:cntrl:]')
      context_str=" [${CYAN}${clean_context}${RESET}]" # Context for console
  fi
  local file_context_str=""
   if [ -n "$CURRENT_LOG_CONTEXT" ]; then
      local clean_context
      clean_context=$(echo "$CURRENT_LOG_CONTEXT" | tr -d '[:cntrl:]')
      file_context_str=" [${clean_context}]" # Context for file
  fi


  # Format for console (with colors and context)
  local colored_log_line="${CYAN}[${timestamp}]${RESET} ${color_code}[${level}]${RESET}${context_str} ${emoji}${message}"
  echo -e "${colored_log_line}" >&2

  # Format for file (no colors, with context)
  if [ -n "$LOG_FILE" ]; then
    local log_line="[${timestamp}] [${level}]${file_context_str} ${message}"
    echo "$log_line" >> "$LOG_FILE"
  fi
}

# --- Dependency Check ---
log_message "DEBUG" "Checking for required commands..."
for cmd in yt-dlp ffmpeg jq mktemp date grep sed sort awk printf wc tr find dirname mkdir touch; do # Added dirname, mkdir, touch
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_message "ERROR" "Required command '$cmd' not found in PATH. Please install it (e.g., using 'brew install $cmd' on macOS)."
    exit 1
  fi
done
log_message "DEBUG" "All required commands found."

# Check Bash version (needs 4+ for readarray/mapfile)
if [[ -n "${BASH_VERSINFO[0]}" ]] && (( BASH_VERSINFO[0] < 4 )); then
  log_message "ERROR" "Bash version 4 or higher is required (due to 'readarray/mapfile' usage). Your version: ${BASH_VERSINFO[0]}. Please update Bash (e.g., 'brew install bash')."
  exit 1
fi

# --- Sanitization Function ---
sanitize_filename() {
  # Replaces problematic characters including / with _
  echo "$1" | sed \
    -e 's#[\\/:\*\?"<>|$'"'"']\+#_#g' `# Replace forbidden characters (including /) with underscore` \
    -e 's/[[:space:]]\+/_/g'          `# Replace whitespace sequences with underscore` \
    -e 's/__\+/_/g'                   `# Collapse multiple underscores` \
    -e 's/^_//'                       `# Remove leading underscore` \
    -e 's/_$//'                       `# Remove trailing underscore`
}

# --- Timestamp Conversion Function ---
timestamp_to_seconds() {
  local ts=$1
  local seconds=0
  # Handle potential floating point seconds from timestamps
  local int_ts=${ts%.*}
  IFS=: read -ra parts <<< "$int_ts"
  local count=${#parts[@]}
  if [[ $count -eq 3 ]]; then
    seconds=$((10#${parts[0]} * 3600 + 10#${parts[1]} * 60 + 10#${parts[2]}))
  elif [[ $count -eq 2 ]]; then
    seconds=$((10#${parts[0]} * 60 + 10#${parts[1]}))
  elif [[ $count -eq 1 ]]; then
    seconds=$((10#${parts[0]}))
  else
    log_message "WARN" "Could not parse timestamp integer part: '$int_ts' from '$ts'"
    seconds=0
  fi
  # Add fractional part if present
  if [[ "$ts" == *.* ]]; then
      local fractional_part="0.${ts#*.}"
      # Use awk for reliable floating point addition
      seconds=$(awk -v s="$seconds" -v f="$fractional_part" 'BEGIN {print s + f}')
  fi
  echo "$seconds"
}

# --- Description Parsing for Titles Function ---
parse_description_for_titles() {
  local line cleaned_line
  local title_found=0
  # Improved skip patterns: handles more variations, ignores lines likely not titles
  local skip_patterns='^tracklist:?$|^track list:?$|^timestamps:?$|^https?:|^\s*[-–—=*#]+\s*$|download link|free download|support the artist|follow me|credits|lyrics'
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') # Trim whitespace
    [ -z "$line" ] && continue # Skip empty lines
    # Skip lines matching common non-title patterns
    if echo "$line" | grep -iqE "$skip_patterns"; then
      continue
    fi
    # Attempt to remove common prefixes like "1. ", "01)", "- ", "* "
    cleaned_line=$(echo "$line" | sed -E 's/^[[:space:]]*([0-9]+[\.\)]?|[-–—*•])[[:space:]]+//')
    if [ "$cleaned_line" != "$line" ]; then
      line="$cleaned_line"
    fi
    # Heuristic: Skip very short lines or lines that look like timestamps again
    if [[ ${#line} -lt 3 ]] || [[ "$line" =~ ^[0-9]+:[0-9]{2}(:[0-9]{2})? ]]; then
        continue
    fi
    if [ -n "$line" ]; then
      echo "$line"
      title_found=1
    fi
  done
  if [ "$title_found" -eq 1 ]; then return 0; else return 1; fi
}

# --- Silence Detection Function ---
detect_silence_points() {
  local audio_file="$1"
  local noise_db="$2" # Expect number e.g. -30
  local duration_s="$3"
  local ffmpeg_output silence_points_unsorted exit_code

  log_message "INFO" "Running silence detection (noise=${noise_db}dB, duration=${duration_s}s) on: $(basename "$audio_file")"
  # Run ffmpeg, redirecting stderr (where silencedetect logs) to stdout
  # SC2140 Fix: Use a single quoted string for the -af argument
  local filter_string="silencedetect=noise=${noise_db}dB:duration=${duration_s}"
  ffmpeg_output=$(ffmpeg -hide_banner -nostats \
    -i "$audio_file" \
    -af "$filter_string" \
    -f null - 2>&1)
  exit_code=$?

  log_message "DEBUG" "ffmpeg silencedetect output:\n$ffmpeg_output"

  # Check exit code - non-zero isn't always an error with '-f null -'
  if [ "$exit_code" -ne 0 ]; then
    # Specifically check for common error keywords in the output
    if echo "$ffmpeg_output" | grep -Eq "Error|Invalid|Cannot|Could not|failed"; then
      log_message "ERROR" "ffmpeg failed during silence detection (code $exit_code). Check debug output above."
      return 1
    else
      log_message "DEBUG" "ffmpeg exited non-zero ($exit_code) but no explicit error found; likely normal completion for '-f null -'."
    fi
  fi

  log_message "DEBUG" "Using grep/sed for parsing silence detection output."
  # More robust parsing: grep for the line, then extract the number
  silence_points_unsorted=$(echo "$ffmpeg_output" | grep 'silence_start:' | sed -n 's/.*silence_start: \([0-9.]*\).*/\1/p')

  if [ -z "$silence_points_unsorted" ]; then
    log_message "WARN" "Silence detection ran but found no silence points matching criteria (noise=${noise_db}dB, duration=${duration_s}s)."
    return 1
  fi

  # Sort the points numerically
  echo "$silence_points_unsorted" | sort -n
  return 0
}

# --- Progress Bar Function ---
show_progress() {
  local current=$1
  local total=$2
  local message=$3
  local width=40 # Slightly shorter width
  # Ensure total is not zero to avoid division by zero
  [[ $total -eq 0 ]] && total=1
  local percentage=$((current * 100 / total))
  local completed=$((width * current / total))
  # Ensure completed doesn't exceed width due to rounding
  [[ $completed -gt $width ]] && completed=$width
  local remaining=$((width - completed))

  # Create the progress bar string
  local progress_bar
  printf -v progress_bar '[%*s%*s] %3d%%' "$completed" '' "$remaining" '' "$percentage"
  # Replace spaces with '=' for completed part, add '>' if not full
  progress_bar="${progress_bar// /=}"
  if [[ $completed -lt $width ]]; then
     progress_bar=$(echo "$progress_bar" | sed "s/= />/; s/ >/>/") # Add '>' at the transition
  fi

  # Print the progress bar: \r moves cursor to beginning, -ne prevents newline
  echo -ne "${CYAN}${message}${RESET} ${BOLD}${progress_bar}${RESET}\r"

  # Print newline when complete
  if [[ $current -ge $total ]]; then
    echo
  fi
}


# --- Main Rip Function ---
rip() {
  # Usage/help function with colors
  usage() {
    cat <<EOF >&2
${BOLD}${GREEN}Usage:${RESET} $0 ${YELLOW}[options]${RESET} ${CYAN}<youtube_url_or_id>${RESET}

${BOLD}${GREEN}Description:${RESET}
  Downloads audio from a YouTube URL (video or playlist).
  For single videos, attempts to split into tracks using Chapters,
  Timestamped Description, or Silence Detection (in that order).
  For playlists, downloads each video as a separate MP3 file.

${BOLD}${GREEN}Options:${RESET}
  ${YELLOW}-o <dir>${RESET}      Specify output directory (default: ~/music/YTdownloads)
  ${YELLOW}-d <db>${RESET}       Silence detection threshold in dB (default: -30)
                   Note: Provide only the number, e.g., -d -40
  ${YELLOW}-s <sec>${RESET}      Minimum silence duration in seconds (default: 2)
  ${YELLOW}-l <file>${RESET}     Log file path (optional, appends if exists)
  ${YELLOW}-h${RESET}             Show this help message

${BOLD}${GREEN}Arguments:${RESET}
  ${CYAN}youtube_url_or_id${RESET} YouTube video/playlist URL or ID (required)

${BOLD}${MAGENTA}Examples:${RESET}
  ${WHITE}$0 https://www.youtube.com/watch?v=dQw4w9WgXcQ${RESET}
  ${WHITE}$0 -o ~/Music/Mixes -d -35 -s 1.5 https://youtu.be/dQw4w9WgXcQ${RESET}
  ${WHITE}$0 PLpSRhk4sG0Wn5Hp-oOsd2QGMXipry3-rw ${RESET}# Playlist ID example
EOF
  }

  # --- Argument Parsing ---
  local BASE_MUSIC_DIR="$HOME/music/YTdownloads"
  local SILENCE_DB="-30" # Store as number, add 'dB' later
  local SILENCE_SEC="2"
  local LOG_FILE="" # Initialize, might be set by -l

  # Use getopts for robust option parsing
  while getopts ":o:d:s:l:h" opt; do
    case $opt in
      o) BASE_MUSIC_DIR="$OPTARG" ;;
      d) SILENCE_DB="$OPTARG" ;;
      s) SILENCE_SEC="$OPTARG" ;;
      l) LOG_FILE="$OPTARG" ;; # Set LOG_FILE if -l is used
      h) usage; return 0 ;;
      \?) log_message "ERROR" "Invalid option: -$OPTARG"; usage; return 1 ;;
      :) log_message "ERROR" "Option -$OPTARG requires an argument."; usage; return 1 ;;
    esac
  done
  shift $((OPTIND -1)) # Remove processed options

  # Check for mandatory URL/ID argument
  if [ -z "$1" ]; then
    log_message "ERROR" "No YouTube URL or Video/Playlist ID provided."
    usage
    return 1
  fi
  local target_url="$1"
  shift # Consume the URL argument

  # Validate numeric options
  if ! [[ "$SILENCE_DB" =~ ^-?[0-9]+$ ]]; then
      log_message "ERROR" "Silence dB threshold must be an integer (e.g., -30). Got: '$SILENCE_DB'"
      return 1
  fi
  if ! [[ "$SILENCE_SEC" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      log_message "ERROR" "Silence duration must be a number (e.g., 2 or 1.5). Got: '$SILENCE_SEC'"
      return 1
  fi

  # --- Temporary Files Setup ---
  local TMP_DIR
  TMP_DIR=$(mktemp -d)
  cleanup() {
    log_message "DEBUG" "Cleaning up temporary directory: $TMP_DIR"
    rm -rf "$TMP_DIR"
  }
  trap cleanup EXIT INT TERM HUP # Ensure cleanup on exit/interrupt

  # --- Log File Header ---
  if [ -n "$LOG_FILE" ]; then
      # Ensure log directory exists
      local log_dir
      log_dir=$(dirname "$LOG_FILE")
      mkdir -p "$log_dir" || { echo "ERROR: Could not create log directory '$log_dir'. Exiting." >&2; exit 1; }
      # Check if file exists and is empty, write header if needed
      if [ ! -s "$LOG_FILE" ]; then
          local header_ts
          header_ts=$(date '+%Y-%m-%d %H:%M:%S')
          echo "### Log Start: ${header_ts} ###" > "$LOG_FILE"
          echo "### Newest entries are appended at the bottom. ###" >> "$LOG_FILE"
      fi
  fi

  # --- Configuration Output ---
  local ARCHIVE_FILE="$BASE_MUSIC_DIR/downloaded_archive.txt"
  echo -e "\n${BOLD}${MAGENTA}🎧 RIPIT! CONFIGURATION 🎧${RESET}"
  log_message "INFO" "Output directory set to: ${CYAN}$BASE_MUSIC_DIR${RESET}"
  log_message "INFO" "Silence detection threshold: ${CYAN}${SILENCE_DB}dB${RESET}"
  log_message "INFO" "Silence detection minimum duration: ${CYAN}${SILENCE_SEC}s${RESET}"
  [ -n "$LOG_FILE" ] && log_message "INFO" "Logging to file: ${CYAN}$LOG_FILE${RESET}"

  # --- Directory and File Setup ---
  mkdir -p "$BASE_MUSIC_DIR" || { log_message "ERROR" "Could not create base directory '$BASE_MUSIC_DIR'. Check permissions."; return 1; }
  touch "$ARCHIVE_FILE" || { log_message "ERROR" "Could not create/touch archive file '$ARCHIVE_FILE'. Check permissions."; return 1; }

  # --- Fetch Metadata and Detect Type ---
  echo -e "\n${BOLD}${MAGENTA}🔍 FETCHING VIDEO INFO & DETECTING TYPE 🔍${RESET}"
  log_message "INFO" "Processing URL/ID: ${CYAN}$target_url${RESET}"

  local video_info_json="" # Will store JSON for single video if detected
  local video_title="" description=""
  local is_playlist=0 # 0=Single, 1=Playlist, -1=Unknown/Error

  # *** FIX: Reliable Playlist Check using --flat-playlist ***
  echo -ne "${YELLOW}Checking if input is a playlist...${RESET} "
  local playlist_entry_count=0
  # Run yt-dlp, capture output to variable, suppress stderr, get exit code
  local id_list_output
  id_list_output=$(yt-dlp --flat-playlist --print id -- "$target_url" 2>/dev/null)
  local check_rc=$?

  if [ "$check_rc" -ne 0 ]; then
      echo -e "${RED}Check Failed!${RESET}"
      log_message "WARN" "Could not reliably check if input is a playlist (yt-dlp exit code: $check_rc). Assuming single video."
      is_playlist=-1 # Unknown
  else
      # Count lines in the output
      playlist_entry_count=$(echo "$id_list_output" | wc -l)
      if (( playlist_entry_count > 1 )); then
          echo -e "${GREEN}Yes (${playlist_entry_count} entries)${RESET}"
          is_playlist=1
      else
          # If only 0 or 1 ID is printed, it's likely a single video URL
          echo -e "${GREEN}No (0 or 1 entry)${RESET}"
          is_playlist=0
      fi
  fi

  # Now fetch detailed metadata (title, description etc.) for logging and naming
  echo -ne "${YELLOW}Fetching title and details...${RESET} "
  local meta_fetch_opts=("--dump-json")
  # If we positively identified a playlist, fetch playlist metadata
  # Otherwise (single or unknown), fetch video metadata (use --no-playlist)
  if [ "$is_playlist" -eq 0 ] || [ "$is_playlist" -eq -1 ]; then
      meta_fetch_opts+=("--no-playlist")
  fi

  video_info_json=$(yt-dlp "${meta_fetch_opts[@]}" -- "$target_url" 2>/dev/null)
  local json_fetch_rc=$?

  if [ "$json_fetch_rc" -ne 0 ] || [ -z "$video_info_json" ]; then
      echo -e "${RED}Failed!${RESET}"
      log_message "WARN" "Could not fetch detailed JSON metadata (yt-dlp exit code: $json_fetch_rc)."
      video_title="Unknown_Title_Fetch_Failed"
      description=""
      # Don't override is_playlist if the initial check succeeded
      if [ "$is_playlist" -ne 1 ]; then
          is_playlist=-1 # Update to unknown if initial check also failed/was single
      fi
  else
      echo -e "${GREEN}Success!${RESET}"
      log_message "DEBUG" "Detailed JSON metadata fetched successfully."
      # Extract title based on detected type
      if [ "$is_playlist" -eq 1 ]; then
          video_title=$(echo "$video_info_json" | jq -r '.title // .playlist_title // "untitled_playlist"')
          description="" # Not needed for playlist download
      else # is_playlist is 0 or -1
          video_title=$(echo "$video_info_json" | jq -r '.title // "untitled_video"')
          description=$(echo "$video_info_json" | jq -r '.description // empty')
      fi
  fi
  # *** FIX: Sanitize title *before* using it for context or paths ***
  local sanitized_video_title
  sanitized_video_title=$(sanitize_filename "$video_title")
  # Handle empty sanitized title
  if [ -z "$sanitized_video_title" ]; then
    log_message "WARN" "Sanitized title is empty after cleanup. Using 'untitled'."
    sanitized_video_title="untitled"
  fi

  # Use the ORIGINAL title for context logging
  CURRENT_LOG_CONTEXT="$video_title"

  # Log detected type with emphasis (only if type is known)
  if [ "$is_playlist" -eq 1 ]; then
      log_message "INFO" "Detected ${BOLD}${YELLOW}Playlist${RESET}${GREEN} input. Will download individual tracks." "${BOLD}${YELLOW}"
  elif [ "$is_playlist" -eq 0 ]; then
      log_message "INFO" "Detected ${BOLD}${YELLOW}Single Video${RESET}${GREEN} input. Will check for chapters/timestamps/silence." "${BOLD}${YELLOW}"
  fi

  # Check if title extraction failed
  if [[ "$video_title" == "untitled_playlist" ]] || [[ "$video_title" == "untitled_video" ]] || [[ "$video_title" == "Unknown_Title_Fetch_Failed" ]]; then
      log_message "WARN" "Using placeholder title: $video_title"
  fi

  # Log context test message to file if LOG_FILE is set
  if [ -n "$LOG_FILE" ]; then
      log_message "DEBUG" "Logging context test: Title set to '$CURRENT_LOG_CONTEXT'"
  fi

  # *** FIX: Use SANITIZED title for output directory ***
  local output_base_dir="$BASE_MUSIC_DIR/$sanitized_video_title"

  echo -e "\n${BOLD}${MAGENTA}📝 DETAILS 📝${RESET}"
  log_message "INFO" "Title: ${CYAN}$video_title${RESET}" # Log original title
  log_message "INFO" "Sanitized Name (for paths): ${CYAN}$sanitized_video_title${RESET}" # Log sanitized name
  log_message "INFO" "Output Base Directory: ${CYAN}$output_base_dir${RESET}"
  log_message "INFO" "Using Archive File: ${CYAN}$ARCHIVE_FILE${RESET}"

  mkdir -p "$output_base_dir" || { log_message "ERROR" "Could not create output directory '$output_base_dir'. Check permissions."; return 1; }

  # --- Download ---
  echo -e "\n${BOLD}${MAGENTA}⬇️  DOWNLOADING AUDIO ⬇️${RESET}"
  log_message "INFO" "Starting download with yt-dlp..."

  local output_template # Define the output template variable
  local downloaded_audio_file # Path for single video file (used only if not playlist)

  if [ "$is_playlist" -eq 1 ]; then
    # Playlist: Use index and title for separate files within the SANITIZED playlist-named directory
    output_template="$output_base_dir/%(playlist_index)02d - %(title)s.%(ext)s"
    log_message "INFO" "Using playlist output template: $output_template"
    # No single file to split later
    downloaded_audio_file=""
  else
    # Single Video (or unknown type): Save as one file named after the SANITIZED video/URL title
    output_template="$output_base_dir/$sanitized_video_title.%(ext)s"
    log_message "INFO" "Using single video output template: $output_template"
    # Define the expected single file path for later splitting checks
    downloaded_audio_file="$output_base_dir/$sanitized_video_title.mp3"
  fi

  # Common yt-dlp options
  local ytdlp_opts=(
    -f bestaudio -x                  # Select best audio and extract
    --audio-format mp3               # Convert to MP3
    --audio-quality 0                # Best MP3 quality (VBR ~245 kbps)
    --embed-metadata                 # Embed basic metadata
    --add-metadata                   # Add more metadata (description, etc.)
    --embed-thumbnail                # Embed thumbnail as cover art
    --download-archive "$ARCHIVE_FILE" # Track downloaded files
    --no-overwrites                  # Don't overwrite existing files (use archive instead)
    -o "$output_template"            # Set output filename template
    --no-part                        # Don't use .part files
    --retries 30                     # Retry up to 30 times on errors
    # --socket-timeout 30            # Optional: Timeout for each network read (in seconds)
  )

  # Add --no-playlist only if we positively identified a single video
  # If type was unknown (-1) or playlist (1), let yt-dlp default behavior handle it.
  if [ "$is_playlist" -eq 0 ]; then
      # Explicitly prevent playlist download if we detected single video
      ytdlp_opts+=(--no-playlist)
      log_message "DEBUG" "Using --no-playlist flag for single video download."
  elif [ "$is_playlist" -eq 1 ]; then
      # No need for explicit --yes-playlist, it's the default for playlist URLs
      log_message "DEBUG" "Letting yt-dlp handle playlist download naturally."
  else # is_playlist == -1 (unknown)
      log_message "DEBUG" "Could not determine type, letting yt-dlp handle playlist decision."
  fi


  yt-dlp "${ytdlp_opts[@]}" -- "$target_url"
  local yt_dlp_download_code=$?

  # --- Handle Download Result ---
  if [ "$yt_dlp_download_code" -eq 101 ]; then
    log_message "SUCCESS" "Video(s) already present in download archive '$ARCHIVE_FILE'."
    # For single video, still check if the file exists for potential splitting
    if [ "$is_playlist" -eq 0 ] && [ -n "$downloaded_audio_file" ] && [ ! -f "$downloaded_audio_file" ]; then
      log_message "WARN" "Video in archive, but expected file not found: $downloaded_audio_file. Splitting might fail."
      # Allow script to continue, splitting logic will handle file not found
    fi
    yt_dlp_download_code=0 # Treat as success for subsequent steps
  elif [ "$yt_dlp_download_code" -ne 0 ]; then
    log_message "WARN" "yt-dlp download command failed or was interrupted (code $yt_dlp_download_code)."
    # Check if *any* mp3 files were created in the target dir (for playlists or failed single)
    if ! ls "$output_base_dir"/*.mp3 > /dev/null 2>&1; then
        log_message "ERROR" "Download command failed AND no MP3 files found in '$output_base_dir'."
        return "$yt_dlp_download_code"
    elif [ "$is_playlist" -eq 0 ] && [ -n "$downloaded_audio_file" ] && [ ! -f "$downloaded_audio_file" ]; then
        log_message "ERROR" "Download command failed AND expected single audio file '$downloaded_audio_file' not found."
        return "$yt_dlp_download_code"
    else
        log_message "WARN" "Found some MP3 files despite download error. Will proceed if possible (e.g., splitting single file)."
    fi
  else
    log_message "SUCCESS" "yt-dlp download command finished successfully. 🎉"
    # Verify expected file(s) exist
    if [ "$is_playlist" -eq 0 ] && [ -n "$downloaded_audio_file" ] && [ ! -f "$downloaded_audio_file" ]; then
        log_message "ERROR" "Download successful but expected single file '$downloaded_audio_file' not found!"
        return 1
    elif [ "$is_playlist" -eq 1 ] && ! ls "$output_base_dir"/*.mp3 > /dev/null 2>&1; then
        # Check if *any* files were downloaded, even if some failed/were skipped
        # This handles cases where archive skips some but others download
        log_message "WARN" "Playlist download finished, but couldn't verify all expected MP3s (some might be archived or failed)."
        # Don't exit here, let the script finish
    else
        log_message "DEBUG" "Confirmed expected output file(s) exist or download completed."
    fi
  fi


  # --- Splitting Logic (Only for Single Videos) ---
  # *** FIX: Ensure splitting only happens if is_playlist is definitively 0 ***
  if [ "$is_playlist" -eq 0 ]; then

    # Double-check file existence before attempting to split
    if [ ! -f "$downloaded_audio_file" ]; then
      log_message "ERROR" "Cannot proceed with splitting - audio file '$downloaded_audio_file' not found (may be archived but missing)."
      return 1
    fi

    log_message "INFO" "Processing as single file, checking for splitting methods..."
    echo -e "\n${BOLD}${MAGENTA}✂️  ANALYZING AUDIO FOR SPLITTING ✂️${RESET}"

    local segments=()
    local split_success=0
    local split_method="None"

    # --- Chapters ---
    local chapters_array_json='[]'
    local chapters_count=0
    # Re-fetch JSON specifically for chapter info if needed.
    # We already fetched the full JSON earlier if possible, so reuse it.
    # If the initial fetch failed, video_info_json will be empty.
    if [ -n "$video_info_json" ] && echo "$video_info_json" | jq -e '.chapters' > /dev/null 2>&1; then
        chapters_array_json=$(echo "$video_info_json" | jq -c '.chapters // []')
        chapters_count=$(echo "$chapters_array_json" | jq 'length')
    elif [ -z "$video_info_json" ]; then
       # Only fetch again if the initial fetch failed
       log_message "DEBUG" "Fetching fresh JSON for chapter check (initial fetch failed)..."
       local fresh_json
       fresh_json=$(yt-dlp --dump-json --no-playlist -- "$target_url" 2>/dev/null) # Ensure no-playlist here
       if [ -n "$fresh_json" ] && echo "$fresh_json" | jq -e '.chapters' > /dev/null 2>&1; then
           chapters_array_json=$(echo "$fresh_json" | jq -c '.chapters // []')
           chapters_count=$(echo "$chapters_array_json" | jq 'length')
       fi
    fi

    if (( chapters_count > 0 )); then
      # Use BOLD YELLOW for emphasis
      log_message "INFO" "Found ${BOLD}${YELLOW}$chapters_count${RESET}${GREEN} chapters. Parsing..." "${BOLD}${YELLOW}"
      local i=0 # Use 0-based index consistent with jq array iteration
      local temp_segments=()
      while IFS= read -r chapter_line; do
        local start_time_float end_time_float chapter_title
        start_time_float=$(echo "$chapter_line" | jq -r '.start_time // 0')
        end_time_float=$(echo "$chapter_line" | jq -r '.end_time // "null"') # Keep null if missing
        chapter_title=$(echo "$chapter_line" | jq -r '.title // empty')
        chapter_title=${chapter_title:-"Chapter_$((i+1))"} # Fallback title

        local start_sec end_sec_str safe_title
        start_sec=$(printf "%.3f" "$start_time_float") # Keep precision for ffmpeg

        if [[ "$end_time_float" != "null" ]] && awk -v s="$start_time_float" -v e="$end_time_float" 'BEGIN { exit !(e > s) }'; then
           end_sec_str=$(printf "%.3f" "$end_time_float")
        else
           # Missing end time, or end time is not after start time - use EOF
           end_sec_str="EOF"
           if [[ "$end_time_float" != "null" ]]; then
             log_message "WARN" "Chapter $((i+1)) end time ($end_time_float) <= start time ($start_time_float). Using EOF."
           fi
        fi

        safe_title=$(sanitize_filename "$chapter_title")
        safe_title=${safe_title:-"chapter_$((i+1))"} # Fallback sanitized title

        temp_segments+=("$start_sec $end_sec_str $safe_title")
        ((i++))
        show_progress "$i" "$chapters_count" "Parsing chapters"
      done < <(echo "$chapters_array_json" | jq -c '.[]')

      if [ ${#temp_segments[@]} -gt 0 ]; then
        segments=("${temp_segments[@]}")
        split_method="Chapters"
        log_message "SUCCESS" "Parsed chapters into ${CYAN}${#segments[@]}${RESET} segments. 📑"
      fi
    fi # End Chapters check

    # --- Timestamped Description ---
    if [ "$split_method" == "None" ]; then
      log_message "INFO" "No chapters found. Checking description for timestamped tracks..."
      local tracks=()
      # Adjusted regex to be less strict about leading chars and more strict on time format
      local timestamp_regex='^.*?(([0-9]+):)?([0-9]{1,2}:[0-9]{2})[[:space:]]+(.+)$'

      # Ensure description is available
      if [ -z "$description" ]; then
        if [ -n "$video_info_json" ]; then
          description=$(echo "$video_info_json" | jq -r '.description // empty')
        else
          log_message "DEBUG" "Fetching description separately for timestamp check..."
          description=$(yt-dlp --print description --skip-download --no-playlist -- "$target_url" 2>/dev/null)
        fi
      fi

      if [ -n "$description" ]; then
        echo -e "${YELLOW}Scanning description for timestamps...${RESET}"
        local timestamp_count=0
        while IFS= read -r line; do
          # Match timestamp format
          if [[ "$line" =~ $timestamp_regex ]]; then
            ((timestamp_count++))
            local hh_part="${BASH_REMATCH[2]}"
            local mm_ss_part="${BASH_REMATCH[3]}"
            local track_title="${BASH_REMATCH[4]}"
            # Clean up potential extra chars around title (like trailing dash/space)
            track_title=$(echo "$track_title" | sed 's/[[:space:]]*[-–—][[:space:]]*$//; s/[[:space:]]*$//')

            local full_ts
            if [[ -n "$hh_part" ]]; then full_ts="${hh_part}:${mm_ss_part}"; else full_ts="${mm_ss_part}"; fi

            local start_sec safe_title
            start_sec=$(timestamp_to_seconds "$full_ts") # Convert HH:MM:SS to seconds.ms
            safe_title=$(sanitize_filename "$track_title")
            safe_title=${safe_title:-"track"} # Fallback sanitized title

            tracks+=("$start_sec $safe_title")
            echo -ne "${CYAN}Found timestamp: ${YELLOW}$full_ts ${WHITE}$track_title${RESET}                      \r"
          fi
        done <<< "$description"
        echo # Newline after scanning

        if ((timestamp_count > 0)); then
          # Use BOLD YELLOW for emphasis
          log_message "INFO" "Found ${BOLD}${YELLOW}$timestamp_count${RESET}${GREEN} potential timestamps in description." "${BOLD}${YELLOW}"
        else
          log_message "INFO" "No lines matching timestamp format found in description."
        fi

        # Need at least 2 timestamps to define tracks
        local track_count=${#tracks[@]} # Use variable for clarity
        if (( track_count > 1 )); then
          log_message "INFO" "Processing ${CYAN}${track_count}${RESET} found timestamps..."
          # Sort tracks by start time (numeric sort on first field)
          # Use process substitution and mapfile/readarray for robust sorting
          unset sorted_tracks # Clear array before assignment
          mapfile -t sorted_tracks < <(printf "%s\n" "${tracks[@]}" | sort -n -k1,1)

          local temp_segments=()
          for (( i=0; i<${#sorted_tracks[@]}; i++ )); do
            # Read sorted start time and title
            read -r start_sec safe_title <<< "${sorted_tracks[i]}"
            local end_sec_str="EOF"
            # Determine end time (start of next track)
            if (( i < ${#sorted_tracks[@]} - 1 )); then
              read -r next_start_sec _ <<< "${sorted_tracks[i+1]}"
              # Ensure next track starts after current track (using awk for float comparison)
              if awk -v current="$start_sec" -v next="$next_start_sec" 'BEGIN { exit !(next > current) }'; then
                 end_sec_str="$next_start_sec"
              else
                 log_message "WARN" "Timestamped track $((i+1)) end time ($next_start_sec) <= start time ($start_sec). Skipping segment end."
                 # If end is before start, might indicate bad timestamps, EOF is safer
                 end_sec_str="EOF"
              fi
            fi
            temp_segments+=("$start_sec $end_sec_str $safe_title")
            show_progress "$((i+1))" "${#sorted_tracks[@]}" "Processing timestamps"
          done

          if [ ${#temp_segments[@]} -gt 0 ]; then
            segments=("${temp_segments[@]}")
            split_method="Timestamped Description"
            log_message "SUCCESS" "Created ${CYAN}${#segments[@]}${RESET} segments from description timestamps. 🕒"
          fi
        elif (( track_count == 1 )); then
             log_message "INFO" "Only one timestamp found in description, not enough to define multiple tracks."
        fi # End processing multiple tracks
      fi # End description check
    fi # End Timestamped Description check

    # --- Silence Detection ---
    if [ "$split_method" == "None" ]; then
      log_message "INFO" "No chapters or timestamped tracks found. Trying silence detection..."
      echo -e "${YELLOW}Analyzing audio for silence...${RESET}"
      local silence_points=()
      # Use mapfile/readarray to read sorted silence points directly
      mapfile -t silence_points < <(detect_silence_points "$downloaded_audio_file" "$SILENCE_DB" "$SILENCE_SEC")
      local detect_rc=$? # Get exit status of detect_silence_points
      echo # Newline after potential progress indicators inside detect_silence_points

      if [ "$detect_rc" -eq 0 ] && [ ${#silence_points[@]} -gt 0 ]; then
         local detected_silences=${#silence_points[@]}
         local expected_tracks=$((detected_silences + 1))
         # Use BOLD YELLOW for emphasis
         log_message "INFO" "Silence detection found ${BOLD}${YELLOW}${detected_silences}${RESET}${GREEN} points (expecting ${BOLD}${YELLOW}${expected_tracks}${RESET}${GREEN} tracks). Attempting to use them for splitting..." "${BOLD}${YELLOW}"


         # Try to find titles in description that match the number of tracks
         local title_list=()
         local num_titles=0
         mapfile -t title_list < <(parse_description_for_titles <<< "$description")
         num_titles=${#title_list[@]}

         local temp_segments=()

         # Check if number of titles matches number of expected tracks
         if [ "$num_titles" -eq "$expected_tracks" ]; then
            split_method="Silence Detection with Description Titles"
            log_message "SUCCESS" "Found ${CYAN}$num_titles${RESET} titles in description matching ${CYAN}$expected_tracks${RESET} silence-based tracks! 🎵"
            for (( i=0; i < expected_tracks; i++ )); do
                local start_sec_float=0 end_sec_float="EOF"
                if (( i > 0 )); then start_sec_float="${silence_points[$((i-1))]}"; fi
                if (( i < detected_silences )); then end_sec_float="${silence_points[$i]}"; fi

                local title="${title_list[$i]}"
                local safe_title # Declare separately
                safe_title=$(sanitize_filename "$title")
                safe_title=${safe_title:-"track_$((i+1))"} # Fallback sanitized title

                temp_segments+=("$start_sec_float $end_sec_float $safe_title")
                show_progress "$((i+1))" "$expected_tracks" "Creating segments with titles"
            done
            segments=("${temp_segments[@]}")
         else
            # Number of titles doesn't match, use generic names
            split_method="Silence Detection with Generic Titles"
            if [ "$num_titles" -gt 0 ]; then
               log_message "INFO" "Found ${CYAN}$num_titles${RESET} titles but ${CYAN}$expected_tracks${RESET} tracks expected from silence. Using generic titles."
            else
               log_message "INFO" "No usable titles found in description. Using generic track names."
            fi

            for (( i=0; i < expected_tracks; i++ )); do
               local start_sec_float=0 end_sec_float="EOF"
               if (( i > 0 )); then start_sec_float="${silence_points[$((i-1))]}"; fi
               if (( i < detected_silences )); then end_sec_float="${silence_points[$i]}"; fi

               local safe_title # Declare separately (SC2155 fix)
               safe_title=$(printf "Track_%03d" $((i+1)))

               temp_segments+=("$start_sec_float $end_sec_float $safe_title")
               show_progress "$((i+1))" "$expected_tracks" "Creating generic segments"
            done
            segments=("${temp_segments[@]}")
         fi # End title matching check
      else
         # Silence detection failed or found no points
         log_message "INFO" "Silence detection failed or found no points. Keeping full track."
      fi # End silence detection success check
    fi # End Silence Detection check

    # --- Perform Splitting ---
    local num_segments=${#segments[@]}

    if (( num_segments > 0 )) && [[ "$split_method" != "None" ]]; then
      split_success=1
      echo -e "\n${BOLD}${MAGENTA}✂️  SPLITTING TRACKS ✂️${RESET}"
      log_message "INFO" "Splitting into ${CYAN}$num_segments${RESET} tracks using method: ${YELLOW}$split_method${RESET}"
      local i=0
      local failed_splits=0
      local split_files=() # Keep track of created files

      while (( i < num_segments )); do
        local start_sec end_sec_str track_title
        read -r start_sec end_sec_str track_title <<< "${segments[$i]}"
        local track_num=$((i+1))

        local output_file # Declare separately (SC2155 fix)
        local track_num_padded
        track_num_padded=$(printf "%03d" "$track_num")
        output_file="$output_base_dir/$track_num_padded - $track_title.mp3"

        split_files+=("$output_file") # Add to list for potential cleanup

        log_message "DEBUG" "Track $track_num: start=$start_sec, end=$end_sec_str, title='$track_title', output='$output_file'"
        show_progress "$((i+1))" "$num_segments" "Splitting track ${track_num}/${num_segments}"

        local ffmpeg_cmd=()
        # Use -vn (no video), -ss (start), -i (input), -acodec copy (fast), map metadata
        ffmpeg_cmd+=(-hide_banner -nostats -vn -ss "$start_sec" -i "$downloaded_audio_file")
        if [[ "$end_sec_str" != "EOF" ]]; then
          ffmpeg_cmd+=(-to "$end_sec_str")
        fi
        # Use -acodec copy for speed, map metadata from input, set ID3v2 version
        ffmpeg_cmd+=(-acodec copy -map_metadata 0 -id3v2_version 3 "$output_file")

        # Log the command being run for debugging
        log_message "DEBUG" "Running ffmpeg: ffmpeg ${ffmpeg_cmd[*]}"

        # Execute ffmpeg, capture stderr for logging errors
        local ffmpeg_split_output
        ffmpeg_split_output=$(ffmpeg "${ffmpeg_cmd[@]}" 2>&1)
        local ffmpeg_rc=$?

        if [ "$ffmpeg_rc" -ne 0 ]; then
          log_message "ERROR" "ffmpeg split command failed for track $track_num (code $ffmpeg_rc). Output:\n$ffmpeg_split_output"
          split_success=0
          failed_splits=$((failed_splits + 1))
          # Optionally break on first error: break
        fi
        ((i++))
      done
      echo # Newline after progress bar

      if [ "$split_success" -eq 1 ]; then
        # Use BOLD YELLOW for emphasis
        log_message "SUCCESS" "Splitting completed successfully! 🎉 Created ${BOLD}${YELLOW}$num_segments${RESET}${GREEN} tracks." "${BOLD}${YELLOW}"
        log_message "INFO" "Removing original audio file: $(basename "$downloaded_audio_file")"
        rm -f "$downloaded_audio_file"
        echo -e "\n${BOLD}${GREEN}✅ Split complete! Your tracks are ready in:${RESET}"
        echo -e "${BOLD}${CYAN}$output_base_dir${RESET}"
      else
        log_message "ERROR" "Splitting failed for ${CYAN}$failed_splits${RESET} track(s). Keeping original audio file."
        echo -e "\n${BOLD}${YELLOW}⚠️ Splitting had errors. Original file preserved.${RESET}"
        log_message "INFO" "Cleaning up any partially created split files..."
        for file in "${split_files[@]}"; do
           if [ -f "$file" ]; then
              log_message "DEBUG" "Removing partial split file: $file"
              rm -f "$file"
           fi
        done
      fi
    else
      # No segments found or splitting method identified
      log_message "INFO" "No segments found using any method. Keeping full audio track."
      echo -e "\n${BOLD}${YELLOW}⚠️ No tracks to split. Original audio file preserved:${RESET}"
      echo -e "${BOLD}${CYAN}$downloaded_audio_file${RESET}"
    fi # End perform splitting check

  else
    # This block runs if is_playlist was 1 or -1 (unknown type but download succeeded)
    local final_track_count=0
    # Count actual MP3 files downloaded in the playlist directory, handle potential errors
    if [ -d "$output_base_dir" ]; then
        # Use find to count .mp3 files, redirect stderr to avoid permission errors etc.
        final_track_count=$(find "$output_base_dir" -maxdepth 1 -name '*.mp3' -type f 2>/dev/null | wc -l)
    fi


    if [ "$is_playlist" -eq 1 ]; then
        # Use BOLD YELLOW for emphasis
        log_message "SUCCESS" "Playlist download complete. ${BOLD}${YELLOW}${final_track_count}${RESET}${GREEN} tracks saved/archived by yt-dlp." "${BOLD}${YELLOW}"
        echo -e "\n${BOLD}${GREEN}✅ Playlist download complete! Tracks are ready in:${RESET}"
        echo -e "${BOLD}${CYAN}$output_base_dir${RESET}"
    else # is_playlist == -1
        log_message "WARN" "Could not determine input type, but download completed. ${BOLD}${YELLOW}${final_track_count}${RESET}${YELLOW} file(s) are in:" "${BOLD}${YELLOW}"
        echo -e "${BOLD}${CYAN}$output_base_dir${RESET}"
        echo -e "${BOLD}${YELLOW}Splitting was not attempted due to uncertain input type.${RESET}"
    fi

  fi # End of is_playlist check


  # --- Completion Banner ---
  echo
  echo -e "${GREEN}"
  cat <<'EOF'
 ___________  __    __       __  ___________
("     _   ")/" |  | "\     /""\("     _   ")
 )__/  \\__/(:  (__)  :)   /    \)__/  \\__/
    \\_ /    \/      \/   /' /\  \  \\_ /
    |.  |    //  __  \\  //  __'  \ |.  |
    \:  |   (:  (  )  :)/   /  \\  \\:  |
     \__|    \__|  |__/(___/    \___)\__|
EOF
  echo -e "${CYAN}"
  cat <<'EOF'
      ________  __    __   __  ___________  ____  ________
     /"       )/" |  | "\ |" \("     _   ")))_ ")/"       )
    (:   \___/(:  (__)  :)||  |)__/  \\__/(____((:   \___/
     \___  \   \/      \/ |:  |   \\_ /          \___  \
      __/  \\  //  __  \\ |.  |   |.  |           __/  \\
     /" \   :)(:  (  )  :)/\  |\  \:  |          /" \   :)
    (_______/  \__|  |__/(__\_|_)  \__|         (_______/
EOF
  echo -e "${YELLOW}"
  cat <<'EOF'
         ________      ______    _____  ___    _______     ___
        |"      "\    /    " \  (\"   \|"  \  /"     "|   |"  |
        (.  ___  :)  // ____  \ |.\\   \    |(: ______)   ||  |
        |: \   ) || /  /    ) :)|: \.   \\  | \/    |     |:  |
        (| (___\ ||(: (____/ // |.  \    \. | // ___)_   _|  /
        |:       :) \        /  |    \    \ |(:      "| / |_/ )
        (________/   \"_____/    \___|\____\) \_______)(_____/
EOF
  echo -e "${RESET}"
  echo -e "${BOLD}${GREEN}🎵 Thanks for using Ripit! 🎵${RESET}"
  echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${RESET}"
  echo

  # Easter egg - 1 in 10 chance of showing
  if (( RANDOM % 10 == 0 )); then
    sleep 1
    echo -e "${YELLOW}✨ Pro tip: ${WHITE}Check the log file (${LOG_FILE:-none specified}) for detailed info!${RESET}"
  fi

  # Explicitly return success if we reached the end without errors
  return 0
}

# --- Script entrypoint ---
# Ensures the script runs the main function only when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rip "$@"
fi
