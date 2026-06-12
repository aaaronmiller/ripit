#!/bin/bash
# Enhanced YT-audio rip scropt with silence detection and chapter parsing, and audo track labeling.


# --- Configuration ---
# Base directory where ripped albums are stored (Allow override via env var)
BASE_MUSIC_DIR="${YT_DOWNLOAD_DIR:-$HOME/music/YTdownloads}"
# File storing the list of downloaded video IDs to avoid re-downloading
ARCHIVE_FILE="$BASE_MUSIC_DIR/downloaded_archive.txt"
# Log file location (optional, uncomment to enable basic logging)
# LOG_FILE="$HOME/rip_audio.log"

# --- Silence Detection Configuration (Optional Override via Env Vars) ---
# Lower dB means quieter threshold (e.g., -50dB is stricter than -30dB)
SILENCE_DB="${SILENCE_DB:--30dB}"
# Minimum duration of silence to register (in seconds)
SILENCE_SEC="${SILENCE_SEC:-2}"

# --- Temporary Files ---
# Using process substitution ($$) and trap for cleanup is safer
TMP_DIR=$(mktemp -d)
# Ensure cleanup on exit
cleanup() {
  # echo "Cleaning up temporary directory: $TMP_DIR" >&2 # Optional debug
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM HUP

# --- Logging Function (Basic) ---
# Usage: log_message LEVEL "Message"
log_message() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_line="[$timestamp] [$level] $message"

  # Print to stderr (visible during run)
  echo "$log_line" >&2

  # Append to log file if defined
  # [ -n "$LOG_FILE" ] && echo "$log_line" >> "$LOG_FILE"
}

# --- Dependency Check ---
log_message "DEBUG" "Checking for required commands..."
for cmd in yt-dlp ffmpeg jq mktemp date grep sed sort; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_message "ERROR" "Required command '$cmd' not found in PATH. Please install it (e.g., using 'brew install $cmd' on macOS)."
    exit 1
  fi
done
log_message "DEBUG" "All required commands found."

# Check Bash version
# BASH_VERSINFO is a Bash-specific array available in v3+
# Index 0 holds the major version
if [[ -n "$BASH_VERSINFO" ]] && (( BASH_VERSINFO[0] < 4 )); then
     log_message "WARN" "Bash version ${BASH_VERSINFO[0]} detected. macOS default Bash is often 3.x. This script uses features compatible with older versions (like replaced mapfile), but be aware if making modifications."
fi

# --- Sanitization Function ---
# MUST be identical to the one used by any calling script (like update_collections.sh)
sanitize_filename() {
    # Remove/replace common problematic characters: / \ : * ? " < > | $ '
    # Replace multiple spaces/underscores with a single underscore
    # Remove leading/trailing underscores/spaces
    echo "$1" | sed \
        -e 's/[\\/:\*\?"<>|$'"'"']\+/_/g' \
        -e 's/[[:space:]]\+/_/g' \
        -e 's/__\+/_/g' \
        -e 's/^_//' \
        -e 's/_$//'
}

# --- Timestamp Conversion Function ---
# Handles HH:MM:SS and MM:SS
timestamp_to_seconds() {
    local ts=$1
    local seconds=0
    IFS=: read -ra parts <<< "$ts" # read -a works in Bash 3+
    local count=${#parts[@]}
    if [[ $count -eq 3 ]]; then
        seconds=$((10#${parts[0]} * 3600 + 10#${parts[1]} * 60 + 10#${parts[2]}))
    elif [[ $count -eq 2 ]]; then
        seconds=$((10#${parts[0]} * 60 + 10#${parts[1]}))
    elif [[ $count -eq 1 ]]; then
        seconds=$((10#${parts[0]}))
    else
        log_message "WARN" "Could not parse timestamp: '$ts'"
        seconds=0
    fi
    echo $seconds
}

# --- Description Parsing for Titles Function ---
# Tries to extract potential titles, one per line to stdout
# Returns 0 if titles found, 1 otherwise
parse_description_for_titles() {
    local line cleaned_line
    local title_found=0
    # Heuristic filters - adjust as needed
    # Skip: tracklist headers, URLs, lines with only separators/spaces
    local skip_patterns='^(tracklist|track list|timestamps):?$|^https?:|^[-=_*#[:space:]]+$'

    while IFS= read -r line; do
        # Trim whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue # Skip empty
        # Skip common non-title patterns (case-insensitive)
        if echo "$line" | grep -iqE "$skip_patterns"; then
            continue
        fi
        # Attempt to strip common leading list markers (like "01.", "1)", "-", "*")
        # Use extended regex (-E) for '+' and '?' - macOS sed requires -E
        cleaned_line=$(echo "$line" | sed -E 's/^[[:space:]]*([0-9]+[\.\)]?|-|\*)[[:space:]]+//')
        # Use the cleaned line if stripping occurred, otherwise original
        if [ "$cleaned_line" != "$line" ]; then
             line="$cleaned_line"
        fi
        # If line still has content, consider it a title
        if [ -n "$line" ]; then
             echo "$line"
             title_found=1
        fi
    done
    # Return 0 if titles were output (success), 1 otherwise (failure)
    if [ "$title_found" -eq 1 ]; then return 0; else return 1; fi
}

# --- Silence Detection Function ---
# Outputs detected silence start times (float seconds), one per line, sorted
# Returns 0 on success (found points), 1 on failure (ffmpeg error or no points)
detect_silence_points() {
    local audio_file="$1"
    local noise_db="$2"
    local duration_s="$3"
    local ffmpeg_output silence_points_unsorted exit_code

    log_message "INFO" "Running silence detection (noise=${noise_db}, duration=${duration_s}s) on: $(basename "$audio_file")"

    # Run ffmpeg, capture stderr, check exit code
    # Use -nostats to reduce noise, redirect stderr to stdout for easier capture
    ffmpeg_output=$(ffmpeg -hide_banner -nostats \
        -i "$audio_file" \
        -af silencedetect=noise="${noise_db}":duration="${duration_s}" \
        -f null - 2>&1) # Capture combined stderr/stdout
    exit_code=$?

    log_message "DEBUG" "ffmpeg silencedetect output:\n$ffmpeg_output"

    if [ $exit_code -ne 0 ]; then
        # Check for actual errors besides normal non-zero exit with -f null
        if echo "$ffmpeg_output" | grep -Eq "Error|Invalid|Cannot|Could not"; then
             log_message "ERROR" "ffmpeg failed during silence detection (code $exit_code). Check debug output above."
             return 1
        else
             log_message "DEBUG" "ffmpeg exited non-zero ($exit_code) but no explicit error found; likely normal for '-f null -'."
        fi
    fi

    # Parse output for silence_start times using sed (more portable than grep -P)
    # --- SED ONLY PARSING (Fix for macOS grep) ---
    log_message "DEBUG" "Using sed for parsing silence detection output."
    silence_points_unsorted=$(echo "$ffmpeg_output" | sed -n 's/.*silence_start: \([0-9.]*\).*/\1/p')

    if [ -z "$silence_points_unsorted" ]; then
        log_message "WARN" "Silence detection ran but found no silence points matching criteria (noise=${noise_db}, duration=${duration_s}s)."
        return 1 # Indicate no points found
    fi

    # Sort and output
    echo "$silence_points_unsorted" | sort -n
    return 0 # Success, points found and output
}


# --- Main Rip Function ---
rip() {
    # Check if a URL argument was provided
    if [ -z "$1" ]; then
        log_message "ERROR" "Usage: ./rip_audio.sh <youtube_url_or_id>"
        log_message "ERROR" "No YouTube URL or Video ID provided."
        return 1
    fi

    # Simple check for potentially invalid test URL from example
    if [[ "$1" == "https://www.youtube.com/watch\?v\=AdZ2vZ-7rYo\&t\=2s" ]]; then
        log_message "WARN" "The provided URL is likely an example/invalid. Please use a real YouTube video URL or ID."
        # Optionally return 1 here, or let yt-dlp handle the error
        # return 1
    fi

    local target_url="$1"
    local overall_rc=0 # Track overall success/failure

    # Ensure base directory exists
    mkdir -p "$BASE_MUSIC_DIR" || { log_message "ERROR" "Could not create base directory '$BASE_MUSIC_DIR'. Check permissions."; return 1; }
    # Ensure archive file is touchable/writable
    touch "$ARCHIVE_FILE" || { log_message "ERROR" "Could not create/touch archive file '$ARCHIVE_FILE'. Check permissions."; return 1; }

    log_message "INFO" "Processing URL/ID: $target_url"

    # --- Get Video Info ---
    local video_info_json
    local video_title description # Declare vars
    # Fetch JSON once to get title, description, chapters if available
    log_message "DEBUG" "Fetching video metadata (JSON) using yt-dlp..."
    video_info_json=$(yt-dlp --print-json --skip-download -- "$target_url" 2>/dev/null)
    local json_fetch_rc=$?

    if [ $json_fetch_rc -ne 0 ] || [ -z "$video_info_json" ]; then
        log_message "WARN" "Could not fetch initial JSON metadata (yt-dlp exit code: $json_fetch_rc). Will try fetching title/desc separately."
        # Try fetching title directly as fallback
        video_title=$(yt-dlp --print "%(title)s" --skip-download -- "$target_url" 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$video_title" ]; then
             log_message "ERROR" "Failed to retrieve video title using yt-dlp. Cannot proceed. Check URL/ID and yt-dlp."
             return 1
        fi
        description="" # Assume no description available
        log_message "INFO" "Using fallback method to get title."
    else
        log_message "DEBUG" "JSON metadata fetched successfully."
        # Extract title and description from JSON using jq
        video_title=$(echo "$video_info_json" | jq -r '.title // empty')
        description=$(echo "$video_info_json" | jq -r '.description // empty')
        if [ -z "$video_title" ]; then
             log_message "ERROR" "Could not extract video title from JSON via jq. Cannot proceed."
             return 1
        fi
    fi

    local sanitized_video_title
    sanitized_video_title=$(sanitize_filename "$video_title")
    if [ -z "$sanitized_video_title" ]; then
        log_message "WARN" "Sanitized video title is empty. Using 'untitled_video'."
        sanitized_video_title="untitled_video"
    fi

    local sanitized_output_dir="$BASE_MUSIC_DIR/$sanitized_video_title"
    local expected_download_path="$sanitized_output_dir/$sanitized_video_title.mp3"

    log_message "INFO" "Video Title: $video_title"
    log_message "INFO" "Sanitized Title: $sanitized_video_title"
    log_message "INFO" "Output Directory: $sanitized_output_dir"
    log_message "INFO" "Expected File: $expected_download_path"
    log_message "INFO" "Using Archive File: $ARCHIVE_FILE"

    # Create the specific output directory
    mkdir -p "$sanitized_output_dir" || { log_message "ERROR" "Could not create output directory '$sanitized_output_dir'. Check permissions."; return 1; }

    # --- Download Audio ---
    log_message "INFO" "Starting download (if not archived)..."
    yt-dlp \
        -f bestaudio -x \
        --audio-format mp3 \
        --audio-quality 0 \
        --embed-metadata \
        --add-metadata \
        --embed-thumbnail \
        --download-archive "$ARCHIVE_FILE" \
        --no-overwrites \
        -o "$sanitized_output_dir/$sanitized_video_title.%(ext)s" \
        --no-part \
        -- "$target_url"

    local yt_dlp_download_code=$?
    local downloaded_audio_file="$expected_download_path" # Assume this path

    if [ $yt_dlp_download_code -eq 101 ]; then
        log_message "INFO" "Video already present in download archive. Checking if file exists..."
        if [ ! -f "$downloaded_audio_file" ]; then
            log_message "WARN" "Video in archive, but expected file not found: $downloaded_audio_file. Will attempt split if possible, but download may be incomplete."
        else
            log_message "INFO" "Existing file found: $downloaded_audio_file"
        fi
        yt_dlp_download_code=0
    elif [ $yt_dlp_download_code -ne 0 ]; then
        log_message "WARN" "yt-dlp download command failed or was interrupted (code $yt_dlp_download_code)."
        if [ ! -f "$downloaded_audio_file" ]; then
           log_message "ERROR" "Download command failed AND expected audio file '$downloaded_audio_file' not found."
           return $yt_dlp_download_code
        else
           log_message "WARN" "Found existing file '$downloaded_audio_file' despite download error. Attempting to proceed."
        fi
    else
         log_message "INFO" "yt-dlp download command finished successfully."
         if [ ! -f "$downloaded_audio_file" ]; then
             log_message "ERROR" "Download successful but expected file '$downloaded_audio_file' not found!"
             return 1
         else
            log_message "DEBUG" "Confirmed expected file exists: $downloaded_audio_file"
         fi
    fi

    # --- Splitting Logic ---
    local segments=() # Array to hold segment info: "start_sec end_sec title"
    local split_success=0 # Flag to track if splitting occurred and succeeded
    local split_method="None" # Keep track of which method was used

    # Pre-declare vars needed across sections
    local title_list=() silence_points=() # Initialize as arrays
    local detected_silences=0
    local num_titles=0
    local detect_rc=1 # Assume silence detection fails or is not run

    # Check if audio file exists before attempting to split
    if [ ! -f "$downloaded_audio_file" ]; then
        log_message "ERROR" "Cannot proceed with splitting - audio file not found: $downloaded_audio_file"
        return 1
    fi

    # --- 1. Try parsing chapters from JSON ---
    log_message "INFO" "Checking for chapters..."
    local chapters_array_json='[]'
    local chapters_count=0
    if [ -n "$video_info_json" ] && echo "$video_info_json" | jq -e '.chapters' > /dev/null 2>&1; then
        chapters_array_json=$(echo "$video_info_json" | jq -c '.chapters // []')
        chapters_count=$(echo "$chapters_array_json" | jq 'length')
    fi

    if [[ "$chapters_count" -gt 0 ]]; then
        log_message "INFO" "Found $chapters_count chapters. Parsing..."
        local i=1
        local temp_segments=()
        while IFS= read -r chapter_line; do
            local start_time_float=$(echo "$chapter_line" | jq -r '.start_time // 0')
            local end_time_float=$(echo "$chapter_line" | jq -r '.end_time // "null"')
            local chapter_title=$(echo "$chapter_line" | jq -r '.title // empty')
            chapter_title=${chapter_title:-"Chapter_$i"}
            local start_sec=$(printf "%.0f" "$start_time_float")
            local end_sec_str="EOF"
            local end_sec_int="EOF"
            if [[ "$end_time_float" != "null" ]]; then
                end_sec_int=$(printf "%.0f" "$end_time_float")
                if (( end_sec_int > start_sec )); then
                    end_sec_str="$end_sec_int"
                else
                     log_message "WARN" "Chapter $i end time ($end_sec_int) <= start time ($start_sec). Using EOF."
                     end_sec_str="EOF"
                fi
            fi
            local safe_title=$(sanitize_filename "$chapter_title")
            safe_title=${safe_title:-"chapter_$i"}
            temp_segments+=("$start_sec $end_sec_str $safe_title")
            ((i++))
        done < <(echo "$chapters_array_json" | jq -c '.[]')

        if [ ${#temp_segments[@]} -gt 0 ]; then
            segments=("${temp_segments[@]}")
            split_method="Chapters"
            log_message "INFO" "Parsed chapters into ${#segments[@]} segments."
        fi
    fi # End chapter check


    # --- 2. If no segments from chapters, try timestamped description ---
    if [ "$split_method" == "None" ]; then
        log_message "INFO" "No chapters found. Checking description for timestamped tracks..."
        local tracks=()
        local timestamp_regex='^[[:space:]]*(([0-9]+):)?([0-9]+:[0-9]{2})[[:space:]]+(.+)$'
        # Ensure description is available
        if [ -z "$description" ] && [ -n "$video_info_json" ]; then
             description=$(echo "$video_info_json" | jq -r '.description // empty')
        elif [ -z "$description" ]; then
             log_message "DEBUG" "Fetching description separately for timestamp check..."
             description=$(yt-dlp --print "%(description)s" --skip-download -- "$target_url" 2>/dev/null)
        fi

        if [ -n "$description" ]; then
            while IFS= read -r line; do
                 if [[ "$line" =~ $timestamp_regex ]]; then
                    local hh_part="${BASH_REMATCH[2]}" mm_ss_part="${BASH_REMATCH[3]}" track_title="${BASH_REMATCH[4]}" full_ts
                    if [[ -n "$hh_part" ]]; then full_ts="${hh_part}:${mm_ss_part}"; else full_ts="${mm_ss_part}"; fi
                    local start_sec=$(timestamp_to_seconds "$full_ts")
                    local safe_title=$(sanitize_filename "$track_title")
                    safe_title=${safe_title:-"track"}
                    tracks+=("$start_sec $safe_title")
                 fi
            done <<< "$description"

            if [ ${#tracks[@]} -gt 1 ]; then
                log_message "INFO" "Found ${#tracks[@]} potential timestamped tracks. Sorting..."
                IFS=$'\n' sorted_tracks=($(sort -n -k1,1 <<<"${tracks[*]}"))
                unset IFS
                local temp_segments=()
                for (( i=0; i<${#sorted_tracks[@]}; i++ )); do
                    read -r start_sec safe_title <<< "${sorted_tracks[i]}"
                    local end_sec_str="EOF"
                    if [[ $i -lt $((${#sorted_tracks[@]} - 1)) ]]; then
                        read -r next_start_sec _ <<< "${sorted_tracks[i+1]}"
                        if (( next_start_sec > start_sec )); then end_sec_str="$next_start_sec"; else log_message "WARN" "Timestamped track $i end time ($next_start_sec) <= start time ($start_sec). Using EOF."; fi
                    fi
                    temp_segments+=("$start_sec $end_sec_str $safe_title")
                done
                if [ ${#temp_segments[@]} -gt 0 ]; then
                     segments=("${temp_segments[@]}")
                     split_method="Timestamped Description"
                     log_message "INFO" "Created ${#segments[@]} segments from description timestamps."
                fi
            else
                log_message "INFO" "Did not find enough timestamped tracks (need >= 2) in description."
            fi
        else
             log_message "WARN" "Video description is empty or could not be retrieved for timestamp check."
        fi
    fi # End timestamped description check


    # --- 3. If still no segments, try silence detection + title list matching ---
    if [ "$split_method" == "None" ]; then
        log_message "INFO" "Attempting fallback: Silence detection & description title list."
        # Ensure description is available (fetch if needed)
        if [ -z "$description" ] && [ -n "$video_info_json" ]; then
             description=$(echo "$video_info_json" | jq -r '.description // empty')
        elif [ -z "$description" ]; then
             log_message "DEBUG" "Fetching description separately for title parsing..."
             description=$(yt-dlp --print "%(description)s" --skip-download -- "$target_url" 2>/dev/null)
        fi

        if [ -z "$description" ]; then
            log_message "WARN" "Video description is empty or could not be retrieved. Cannot use silence+title fallback."
        else
            # Parse description for potential titles
            # --- mapfile replaced with while read loop for Bash 3+ compatibility ---
            title_list=()
            while IFS= read -r line; do title_list+=("$line"); done < <(echo "$description" | parse_description_for_titles)
            num_titles=${#title_list[@]}

            if [ "$num_titles" -eq 0 ]; then
                 log_message "WARN" "Could not parse any potential track titles from the description for silence fallback."
            else
                log_message "INFO" "Found ${num_titles} potential titles in description."

                # Detect silence points
                silence_points=()
                detect_rc=1
                local silence_output
                silence_output=$(detect_silence_points "$downloaded_audio_file" "$SILENCE_DB" "$SILENCE_SEC")
                detect_rc=$?

                if [ $detect_rc -eq 0 ] && [ -n "$silence_output" ]; then
                     while IFS= read -r line; do silence_points+=("$line"); done <<< "$silence_output"
                fi
                detected_silences=${#silence_points[@]}

                if [ $detect_rc -eq 0 ] && [ $detected_silences -gt 0 ]; then
                    num_expected_tracks=$((detected_silences + 1))
                    log_message "INFO" "Detected ${detected_silences} silence points, expecting ${num_expected_tracks} tracks."

                    # --- Correlate counts ---
                    if [[ "$num_expected_tracks" -eq "$num_titles" ]]; then
                        log_message "INFO" "Title count matches expected track count. Generating segments based on silence points and titles."
                        # --- Generate Segments using Titles ---
                        local i=0 temp_segments=() start_sec_float=0.0
                        for (( i=0; i < num_titles; i++ )); do
                             local title="${title_list[i]}"
                             local safe_title=$(sanitize_filename "$title"); safe_title=${safe_title:-"track_$((i+1))"}
                             local end_sec_float="EOF" end_sec_str="EOF" end_sec_int="EOF"
                             if [[ $i -lt $detected_silences ]]; then end_sec_float=${silence_points[i]}; end_sec_int=$(printf "%.0f" "$end_sec_float"); fi
                             local start_sec_int=$(printf "%.0f" "$start_sec_float")
                             if [[ "$end_sec_int" != "EOF" ]] && (( end_sec_int <= start_sec_int )); then
                                 log_message "WARN" "Skipping silence segment for '$safe_title' because end time ($end_sec_int) <= start time ($start_sec_int)."
                                 if [[ "$end_sec_float" != "EOF" ]]; then start_sec_float="$end_sec_float"; fi; continue
                             elif [[ "$end_sec_int" != "EOF" ]]; then end_sec_str="$end_sec_int"; fi
                             log_message "DEBUG" "Silence Segment $((i+1)): Start=${start_sec_int}s, End=${end_sec_str}s, Title='${safe_title}'"
                             temp_segments+=("${start_sec_int} ${end_sec_str} ${safe_title}")
                             if [[ "$end_sec_float" != "EOF" ]]; then start_sec_float="$end_sec_float"; fi
                        done
                        if [ ${#temp_segments[@]} -gt 0 ]; then
                             segments=("${temp_segments[@]}")
                             split_method="Silence Detection"
                             log_message "INFO" "Successfully generated ${#temp_segments[@]} segments based on silence detection and titles."
                        fi
                        # --- End Generate Segments using Titles ---
                    else
                        # --- Counts Mismatch ---
                        log_message "WARN" "Mismatch: Found ${num_titles} titles but silence detection implies ${num_expected_tracks} tracks."
                        log_message "WARN" "Cannot reliably split using matched titles."
                        # Let it fall through to the next fallback
                    fi # End correlation check
                else
                     log_message "WARN" "Silence detection failed (code $detect_rc) or found no points ($detected_silences). Cannot use silence+title matching."
                fi # End silence points detected check
            fi # End title list check
        fi # End description available check
    fi # End silence + title check


    # --- 4. NEW Fallback: Silence Points Only (Generic Titles) ---
    # Check if previous methods failed AND silence detection ran successfully AND found points
    if [ "$split_method" == "None" ] && [ $detect_rc -eq 0 ] && [ $detected_silences -gt 0 ]; then
        log_message "INFO" "Fallback: Using detected silence points only (${detected_silences} points -> $((${detected_silences}+1)) tracks) with generic titles."
        split_method="Silence Points Only (Generic Titles)" # Set the method indicator
        local temp_segments=()
        local start_sec_float=0.0

        # Loop N+1 times for N silence points to create N+1 segments
        for (( i=0; i <= detected_silences; i++ )); do
            local safe_title=$(printf "Track_%03d" $((i+1))) # Generic title: Track_001, Track_002...
            local end_sec_float="EOF" end_sec_str="EOF" end_sec_int="EOF"

            # Get end time from silence points array for all but the last track
            if [[ $i -lt $detected_silences ]]; then
                end_sec_float=${silence_points[i]}
                end_sec_int=$(printf "%.0f" "$end_sec_float") # Round for comparison and ffmpeg -to
            fi

            local start_sec_int=$(printf "%.0f" "$start_sec_float") # Round start time for comparison and ffmpeg -ss

            # Basic check to prevent zero or negative length segments if start/end are identical after rounding
            if [[ "$end_sec_int" != "EOF" ]] && (( end_sec_int <= start_sec_int )); then
                 log_message "WARN" "Skipping generic segment $i ('$safe_title') because end time ($end_sec_int) <= start time ($start_sec_int)."
                 # Still advance start time for the next potential segment
                 if [[ "$end_sec_float" != "EOF" ]]; then start_sec_float="$end_sec_float"; fi
                 continue # Skip adding this segment
            elif [[ "$end_sec_int" != "EOF" ]]; then
                 end_sec_str="$end_sec_int" # Use the rounded integer for the -to parameter if valid
            fi

            log_message "DEBUG" "Generic Segment $((i+1)): Start=${start_sec_int}s, End=${end_sec_str}s, Title='${safe_title}'"
            temp_segments+=("${start_sec_int} ${end_sec_str} ${safe_title}")

            # Advance start time for the next iteration using the precise float value
            if [[ "$end_sec_float" != "EOF" ]]; then start_sec_float="$end_sec_float"; fi
        done

        # Assign generated segments if any were valid
        if [ ${#temp_segments[@]} -gt 0 ]; then
            segments=("${temp_segments[@]}") # Assign to main segments array
            log_message "INFO" "Successfully generated ${#segments[@]} generic segments based on silence points."
        else
             log_message "WARN" "Failed to generate any valid generic segments despite having silence points (check for overlapping times)."
             split_method="None" # Reset split method if segment generation failed
        fi
    fi # End Silence Points Only Fallback


    # --- Execute Splitting if Segments were Found (by any method) ---
    if [ "$split_method" != "None" ] && [ ${#segments[@]} -gt 0 ]; then
        log_message "INFO" "Proceeding to split audio into ${#segments[@]} segments using method: $split_method"
        local split_failed_count=0
        local i=1
        for segment in "${segments[@]}"; do
            read -r start_sec end_sec safe_title <<< "$segment"

            # Ensure safe_title is not empty after sanitization before formatting
            if [ -z "$safe_title" ]; then
                log_message "WARN" "Segment $i has an empty title after sanitization, using 'generic_track_$i'."
                safe_title="generic_track_$i"
            fi
            local output_filename
            output_filename=$(printf "%s/%03d - %s.mp3" "$sanitized_output_dir" "$i" "$safe_title")

            local ffmpeg_end_time_opt=()
            # Add -to option only if end_sec is not EOF (already checked > start_sec)
            if [[ "$end_sec" != "EOF" ]]; then
                ffmpeg_end_time_opt=(-to "$end_sec")
            fi

            log_message "INFO" "Splitting segment $i: '$safe_title' ($start_sec -> $end_sec) -> $(basename "$output_filename")"

            ffmpeg -hide_banner -loglevel error \
                -i "$downloaded_audio_file" \
                -ss "$start_sec" \
                "${ffmpeg_end_time_opt[@]}" \
                -vn -acodec copy \
                -metadata track="$i/${#segments[@]}" \
                -metadata title="$safe_title" \
                -metadata album="$video_title" \
                 -y \
                "$output_filename"

            local ffmpeg_rc=$?
            if [ $ffmpeg_rc -ne 0 ]; then
                log_message "ERROR" "ffmpeg failed (code $ffmpeg_rc) for segment $i ('$safe_title')."
                log_message "ERROR" "Input: '$downloaded_audio_file'"
                log_message "ERROR" "Output attempt: '$output_filename'"
                log_message "ERROR" "Start: $start_sec, End: $end_sec"
                ((split_failed_count++))
                overall_rc=1
            fi
            ((i++))
        done

        if [ $split_failed_count -eq 0 ]; then
            log_message "INFO" "Splitting completed successfully for all segments."
            split_success=1
        else
            log_message "WARN" "Splitting failed for $split_failed_count out of ${#segments[@]} segment(s)."
            # Keep overall_rc=1 if splitting was attempted but failed partially
            if [ $split_failed_count -gt 0 ]; then overall_rc=1; fi
        fi

        # Remove original file only if splitting occurred AND was fully successful
        if [ "$split_success" -eq 1 ]; then
            log_message "INFO" "Removing original file: $downloaded_audio_file"
            rm -f "$downloaded_audio_file"
            if [ $? -ne 0 ]; then
                 log_message "WARN" "Could not remove original file '$downloaded_audio_file'."
            fi
        else
             log_message "WARN" "Original file kept due to splitting errors or no segments defined/matched for splitting."
             if [ ${#segments[@]} -gt 0 ] && [ "$split_success" -eq 0 ]; then
                 overall_rc=1 # Ensure non-zero exit if we expected to split but failed partially
             fi
        fi
    else
        # Message about no splitting occurred (covers all failures)
        if [ "$split_method" == "None" ]; then # Only log if no method ever succeeded
             log_message "INFO" "No chapters, parsable timestamps, or usable silence points found/matched. Keeping the original downloaded file."
        fi
    fi # --- End of the main splitting IF/ELSE block ---

    # --- Cleanup --- # <<< CORRECTLY PLACED BLOCK
    log_message "DEBUG" "Cleaning up stray thumbnail files (e.g., .webp)..."
    # Use find with -name to catch different thumbnail extensions yt-dlp might leave
    find "$sanitized_output_dir" -maxdepth 1 \( -name "*.webp" -o -name "*.jpg" -o -name "*.png" \) -delete 2>/dev/null || true

    log_message "INFO" "Processing finished for '$video_title'."
    return $overall_rc # Return the overall success/failure code

} # --- End of the rip function ---

# --- Argument Check & Execution ---
if [ $# -eq 0 ]; then
    log_message "ERROR" "Usage: ./rip_audio.sh <youtube_url_or_id>"
    log_message "ERROR" "Please provide a YouTube video URL or ID as the first argument."
    exit 1
fi

# Call rip function with the first script argument ($1)
rip "$1"

# Exit with the final return code from rip()
exit $?