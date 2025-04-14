#!/bin/bash

# --- Configuration ---
# Path to the script that rips/splits individual videos
RIP_SCRIPT_PATH="$HOME/Scripts/rip.sh" # ADJUST THIS PATH AS NEEDED
# Base directory where ripped albums are stored
BASE_MUSIC_DIR="$HOME/music/YTdownloads"
# File storing the list of YouTube channel/playlist URLs to track
INDEX_FILE="$HOME/.yt_collection_index.txt"
# Log file location
LOG_FILE="$HOME/yt_collection_updater.log"
# Log level (DEBUG, INFO, WARN, ERROR) - Controls console output
LOG_LEVEL="INFO"

# --- Temporary Files ---
# Using process substitution ($$) and trap for cleanup is safer
TMP_DIR=$(mktemp -d)
ALL_VIDEOS_TMP="$TMP_DIR/all_videos.tmp.$$"
SORTED_VIDEOS_TMP="$TMP_DIR/sorted_videos.tmp.$$"

# --- Ensure Cleanup ---
cleanup() {
  log_message "DEBUG" "Cleaning up temporary directory: $TMP_DIR"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# --- Logging Function ---
# Usage: log_message LEVEL "Message"
log_message() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_line="[$timestamp] [$level] $message"

  # Log to file
  echo "$log_line" >> "$LOG_FILE"

  # Optionally print to console based on level
  case "$LOG_LEVEL" in
    DEBUG)
      echo "$log_line"
      ;;
    INFO)
      [[ "$level" == "INFO" || "$level" == "WARN" || "$level" == "ERROR" ]] && echo "$log_line"
      ;;
    WARN)
      [[ "$level" == "WARN" || "$level" == "ERROR" ]] && echo "$log_line"
      ;;
    ERROR)
      [[ "$level" == "ERROR" ]] && echo "$log_line"
      ;;
  esac
}

# --- Sanitization Function ---
# MUST be identical to the one in rip_audio.sh for accurate directory checking
sanitize_filename() {
    echo "$1" | sed \
        -e 's/[\\/:\*\?"<>|$'"'"']\+/_/g' \
        -e 's/[[:space:]]\+/_/g' \
        -e 's/__\+/_/g' \
        -e 's/^_//' \
        -e 's/_$//'
}

# --- Usage Info ---
usage() {
  echo "Usage: $0 [--add <youtube_url>] [--help]"
  echo ""
  echo "  (no arguments)   Update library from URLs in $INDEX_FILE."
  echo "  --add <url>      Add a YouTube channel/playlist URL to the index."
  echo "  --help           Display this help message."
  echo ""
  echo "Configured Rip Script: $RIP_SCRIPT_PATH"
  echo "Configured Music Dir: $BASE_MUSIC_DIR"
  echo "Configured Index File: $INDEX_FILE"
  echo "Configured Log File: $LOG_FILE"
}

# --- Dependency Checks ---
log_message "DEBUG" "Checking dependencies..."
command -v yt-dlp >/dev/null 2>&1 || { log_message "ERROR" "Dependency missing: yt-dlp not found in PATH."; exit 1; }
command -v sort >/dev/null 2>&1 || { log_message "ERROR" "Dependency missing: sort not found in PATH."; exit 1; }
if [ ! -f "$RIP_SCRIPT_PATH" ]; then
    log_message "ERROR" "Rip script not found at: $RIP_SCRIPT_PATH"; exit 1;
elif [ ! -x "$RIP_SCRIPT_PATH" ]; then
     log_message "ERROR" "Rip script is not executable: $RIP_SCRIPT_PATH"; exit 1;
fi
log_message "DEBUG" "Dependencies seem OK."

# --- Argument Parsing ---
MODE="update"
URL_TO_ADD=""

if [ "$#" -gt 0 ]; then
  case "$1" in
    --add)
      if [ -z "$2" ]; then
        log_message "ERROR" "--add option requires a URL argument."
        usage
        exit 1
      fi
      MODE="add"
      URL_TO_ADD="$2"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      log_message "ERROR" "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
fi

# --- Main Logic ---

# --- Mode: Add URL ---
if [ "$MODE" == "add" ]; then
  log_message "INFO" "Mode: Add URL to Index"
  touch "$INDEX_FILE" # Ensure file exists
  if grep -Fxq "$URL_TO_ADD" "$INDEX_FILE"; then
    log_message "WARN" "URL already exists in index file: $URL_TO_ADD"
    exit 0
  else
    log_message "INFO" "Adding URL to index: $URL_TO_ADD"
    echo "$URL_TO_ADD" >> "$INDEX_FILE"
    if [ $? -eq 0 ]; then
        log_message "INFO" "URL added successfully."
        exit 0
    else
        log_message "ERROR" "Failed to write to index file: $INDEX_FILE"
        exit 1
    fi
  fi
fi

# --- Mode: Update ---
log_message "INFO" "==== Starting Collection Update ===="
log_message "INFO" "Using Index: $INDEX_FILE"
log_message "INFO" "Using Music Dir: $BASE_MUSIC_DIR"

# Read index file
if [ ! -f "$INDEX_FILE" ] || [ ! -s "$INDEX_FILE" ]; then
  log_message "ERROR" "Index file is missing or empty: $INDEX_FILE"
  log_message "ERROR" "Add collection URLs using the --add option first."
  exit 1
fi

mapfile -t PAGE_URLS < "$INDEX_FILE"
log_message "INFO" "Found ${#PAGE_URLS[@]} collection page(s) in index."

# Create or clear temporary file
> "$ALL_VIDEOS_TMP"

# --- Video Discovery ---
log_message "INFO" "--- Discovering Videos ---"
total_discovered=0
for page_url in "${PAGE_URLS[@]}"; do
  log_message "INFO" "Fetching video list from: $page_url"
  # Use process substitution and loop to handle potential errors per line
  while IFS=' ' read -r date_str video_id; do
      # Basic validation of format
      if [[ "$date_str" =~ ^[0-9]{8}$ ]] && [[ -n "$video_id" ]]; then
          echo "$date_str $video_id" >> "$ALL_VIDEOS_TMP"
          ((total_discovered++))
      else
          log_message "WARN" "Skipping invalid line from yt-dlp output for page '$page_url': date='$date_str', id='$video_id'"
      fi
  done < <(yt-dlp --flat-playlist --print "%(upload_date>%Y%m%d)s %(id)s" "$page_url" 2> >(sed "s/^/[$page_url yt-dlp ERR] /" >> "$LOG_FILE"))

  # Check yt-dlp exit status ($PIPESTATUS[0] for the first command in pipe)
  yt_dlp_status=${PIPESTATUS[0]}
  if [ $yt_dlp_status -ne 0 ]; then
      log_message "ERROR" "yt-dlp failed (code $yt_dlp_status) while fetching list from $page_url. Check log."
      # Continue to next page? Or exit? Let's continue for resilience.
  fi
done

log_message "INFO" "Discovered $total_discovered potential videos across all pages."

if [ $total_discovered -eq 0 ]; then
    log_message "WARN" "No videos discovered. Exiting."
    exit 0
fi

# --- Sorting ---
log_message "INFO" "--- Sorting Videos by Upload Date ---"
sort -n -k1,1 "$ALL_VIDEOS_TMP" > "$SORTED_VIDEOS_TMP"
if [ $? -ne 0 ]; then
    log_message "ERROR" "Failed to sort video list."
    exit 1
fi

# --- Processing Videos ---
log_message "INFO" "--- Processing Sorted Videos ---"
processed_count=0
skipped_count=0
ripped_count=0
failed_count=0

while IFS=' ' read -r upload_date video_id; do
    ((processed_count++))
    video_url="https://www.youtube.com/watch?v=$video_id"
    log_message "DEBUG" "Processing $processed_count/$total_discovered: ID=$video_id Date=$upload_date URL=$video_url"

    # Get Title
    video_title=$(yt-dlp --print "%(title)s" "$video_url" 2>>"$LOG_FILE")
    title_status=$?
    if [ $title_status -ne 0 ] || [ -z "$video_title" ]; then
        log_message "ERROR" "Failed to get title for video ID $video_id (URL: $video_url). Skipping."
        ((failed_count++))
        continue
    fi

    # Sanitize Title
    sanitized_title=$(sanitize_filename "$video_title")
    if [ -z "$sanitized_title" ]; then
        log_message "WARN" "Sanitized title for '$video_title' (ID: $video_id) is empty. Using 'untitled_$video_id'."
        sanitized_title="untitled_$video_id"
    fi

    # Check if Directory Exists
    expected_dir="$BASE_MUSIC_DIR/$sanitized_title"
    if [ -d "$expected_dir" ]; then
        log_message "INFO" "($processed_count/$total_discovered) Skipping existing: '$video_title' (Directory: $expected_dir)"
        ((skipped_count++))
    else
        # Rip New Video
        log_message "INFO" "($processed_count/$total_discovered) Ripping NEW: '$video_title' (URL: $video_url)"
        # Execute rip script, append its output (stdout & stderr) to our log file
        "$RIP_SCRIPT_PATH" "$video_url" >> "$LOG_FILE" 2>&1
        rip_status=$?

        if [ $rip_status -eq 0 ]; then
            log_message "INFO" "Rip SUCCESSFUL for '$video_title' (ID: $video_id)."
            ((ripped_count++))
        else
            log_message "ERROR" "Rip FAILED (code $rip_status) for '$video_title' (ID: $video_id). Check log above for rip script output."
            ((failed_count++))
            # Should we attempt to clean up a potentially partial directory created by rip.sh?
            # Maybe not - rip.sh might have its own cleanup or leave clues.
        fi
    fi
    # Optional: Add a small sleep here if desired to be extra nice to YouTube servers
    # sleep 1
done < "$SORTED_VIDEOS_TMP"

# --- Summary ---
log_message "INFO" "--- Update Summary ---"
log_message "INFO" "Total Videos Considered: $total_discovered"
log_message "INFO" "Videos Processed (title check): $processed_count"
log_message "INFO" "Skipped (Already Existed): $skipped_count"
log_message "INFO" "Ripped Successfully: $ripped_count"
log_message "INFO" "Failures (Title/Rip): $failed_count"
log_message "INFO" "==== Collection Update Finished ===="

exit 0 # Success overall, individual failures logged