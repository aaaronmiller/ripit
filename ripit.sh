#!/usr/bin/env bash

cat <<'EOF'
  _______    __       _______   __  ___________                                               
 /"      \  |" \     |   __ "\ |" \("     _   ")                                              
|:        | ||  |    (. |__) :)||  |)__/  \\__/                                               
|_____/   ) |:  |    |:  ____/ |:  |   \\_ /                                                  
 //      /  |.  |    (|  /     |.  |   |.  |                                                  
|:  __   \  /\  |\  /|__/ \    /\  |\  \:  |                                                  
|__|  \___)(__\_|_)(_______)  (__\_|_)  \__|                                                  
                                                                                              
          __      ___       _______   ____  ____  ___      ___                                
         /""\    |"  |     |   _  "\ ("  _||_ " ||"  \    /"  |                               
        /    \   ||  |     (. |_)  :)|   (  ) : | \   \  //   |                               
       /' /\  \  |:  |     |:     \/ (:  |  | . ) /\\  \/.    |                               
      //  __'  \  \  |___  (|  _  \\  \\ \__/ // |: \.        |                               
     /   /  \\  \( \_|:  \ |: |_)  :) /\\ __ //\ |.  \    /:  |                               
    (___/    \___)\_______)(_______/ (__________)|___|\__/|___|                               
                                                                                              
          _______    _______        __       _______   _______    _______   _______      ___  
         /" _   "|  /"      \      /""\     |   _  "\ |   _  "\  /"     "| /"      \    |"  | 
        (: ( \___) |:        |    /    \    (. |_)  :)(. |_)  :)(: ______)|:        |   ||  | 
         \/ \      |_____/   )   /' /\  \   |:     \/ |:     \/  \/    |  |_____/   )   |:  | 
         //  \ ___  //      /   //  __'  \  (|  _  \\ (|  _  \\  // ___)_  //      /   _|  /  
        (:   _(  _||:  __   \  /   /  \\  \ |: |_)  :)|: |_)  :)(:      "||:  __   \  / |_/ ) 
         \_______) |__|  \___)(___/    \___)(_______/ (_______/  \_______)|__|  \___)(_____/  
EOF
echo

# --- Logging Function ---
log_message() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_line="[$timestamp] [$level] $message"
  echo "$log_line" >&2
  if [ -n "$LOG_FILE" ]; then
    echo "$log_line" >> "$LOG_FILE"
  fi
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
if [[ -n "${BASH_VERSINFO[0]}" ]] && (( BASH_VERSINFO[0] < 4 )); then
  log_message "WARN" "Bash version ${BASH_VERSINFO[0]} detected. macOS default Bash is often 3.x. This script uses features compatible with older versions (like replaced mapfile), but be aware if making modifications."
fi

# --- Sanitization Function ---
sanitize_filename() {
  echo "$1" | sed \
    -e 's/[\\/:\*\?"<>|$'"'"']\+/_/g' \
    -e 's/[[:space:]]\+/_/g' \
    -e 's/__\+/_/g' \
    -e 's/^_//' \
    -e 's/_$//'
}

# --- Timestamp Conversion Function ---
timestamp_to_seconds() {
  local ts=$1
  local seconds=0
  IFS=: read -ra parts <<< "$ts"
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
  echo "$seconds"
}

# --- Description Parsing for Titles Function ---
parse_description_for_titles() {
  local line cleaned_line
  local title_found=0
  local skip_patterns='^(tracklist|track list|timestamps):?$|^https?:|^[-=_*#[:space:]]+$'
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    if echo "$line" | grep -iqE "$skip_patterns"; then
      continue
    fi
    cleaned_line=$(echo "$line" | sed -E 's/^[[:space:]]*([0-9]+[\.\)]?|-|\*)[[:space:]]+//')
    if [ "$cleaned_line" != "$line" ]; then
      line="$cleaned_line"
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
  local noise_db="$2"
  local duration_s="$3"
  local ffmpeg_output silence_points_unsorted exit_code

  log_message "INFO" "Running silence detection (noise=${noise_db}, duration=${duration_s}s) on: $(basename "$audio_file")"
  ffmpeg_output=$(ffmpeg -hide_banner -nostats \
    -i "$audio_file" \
    -af silencedetect=noise="${noise_db}":duration="${duration_s}" \
    -f null - 2>&1)
  exit_code=$?

  log_message "DEBUG" "ffmpeg silencedetect output:\n$ffmpeg_output"

  if [ "$exit_code" -ne 0 ]; then
    if echo "$ffmpeg_output" | grep -Eq "Error|Invalid|Cannot|Could not"; then
      log_message "ERROR" "ffmpeg failed during silence detection (code $exit_code). Check debug output above."
      return 1
    else
      log_message "DEBUG" "ffmpeg exited non-zero ($exit_code) but no explicit error found; likely normal for '-f null -'."
    fi
  fi

  log_message "DEBUG" "Using sed for parsing silence detection output."
  silence_points_unsorted=$(echo "$ffmpeg_output" | sed -n 's/.*silence_start: \([0-9.]*\).*/\1/p')
  if [ -z "$silence_points_unsorted" ]; then
    log_message "WARN" "Silence detection ran but found no silence points matching criteria (noise=${noise_db}, duration=${duration_s}s)."
    return 1
  fi

  echo "$silence_points_unsorted" | sort -n
  return 0
}

# --- Main Rip Function ---
rip() {
  # Usage/help function
  usage() {
    cat <<EOF >&2
Usage: $0 [-o <output_dir>] [-d <silence_db>] [-s <silence_sec>] [-l <log_file>] <youtube_url_or_id>

Options:
  -o <output_dir>     Specify output directory (optional)
  -d <silence_db>     Silence detection threshold, e.g. -30dB (optional)
  -s <silence_sec>    Minimum silence duration in seconds (optional)
  -l <log_file>       Log file path (optional)

Arguments:
  youtube_url_or_id   YouTube video URL or ID (required)
EOF
  }

  # If no arguments, print usage and exit with error
  if [ $# -eq 0 ]; then
    usage
    return 1
  fi

  # Defaults
  BASE_MUSIC_DIR="$HOME/music/YTdownloads"
  SILENCE_DB="-30dB"
  SILENCE_SEC="2"
  LOG_FILE=""

  # Parse options
  while getopts ":o:d:s:l:" opt; do
    case $opt in
      o) BASE_MUSIC_DIR="$OPTARG" ;;
      d) SILENCE_DB="$OPTARG" ;;
      s) SILENCE_SEC="$OPTARG" ;;
      l) LOG_FILE="$OPTARG" ;;
      \?) log_message "ERROR" "Invalid option: -$OPTARG"; usage; return 1 ;;
      :) log_message "ERROR" "Option -$OPTARG requires an argument."; usage; return 1 ;;
    esac
  done
  shift $((OPTIND -1))

  # Now $1 should be the YouTube URL or ID
  if [ -z "$1" ]; then
    log_message "ERROR" "No YouTube URL or Video ID provided."
    usage
    return 1
  fi

  local target_url="$1"
  shift

  # --- Temporary Files ---
  TMP_DIR=$(mktemp -d)
  cleanup() {
    rm -rf "$TMP_DIR"
  }
  trap cleanup EXIT INT TERM HUP

  # File storing the list of downloaded video IDs to avoid re-downloading
  ARCHIVE_FILE="$BASE_MUSIC_DIR/downloaded_archive.txt"

  log_message "INFO" "Output directory set to: $BASE_MUSIC_DIR"
  log_message "INFO" "Silence detection threshold: $SILENCE_DB"
  log_message "INFO" "Silence detection minimum duration: $SILENCE_SEC"
  [ -n "$LOG_FILE" ] && log_message "INFO" "Logging to file: $LOG_FILE"

  mkdir -p "$BASE_MUSIC_DIR" || { log_message "ERROR" "Could not create base directory '$BASE_MUSIC_DIR'. Check permissions."; return 1; }
  touch "$ARCHIVE_FILE" || { log_message "ERROR" "Could not create/touch archive file '$ARCHIVE_FILE'. Check permissions."; return 1; }

  log_message "INFO" "Processing URL/ID: $target_url"

  local video_info_json
  local video_title description

  video_info_json=$(yt-dlp --print-json --skip-download -- "$target_url" 2>/dev/null)
  local json_fetch_rc=$?

  if [ "$json_fetch_rc" -ne 0 ] || [ -z "$video_info_json" ]; then
    log_message "WARN" "Could not fetch initial JSON metadata (yt-dlp exit code: $json_fetch_rc). Will try fetching title/desc separately."
    if ! video_title=$(yt-dlp --print "%(title)s" --skip-download -- "$target_url" 2>/dev/null) || [ -z "$video_title" ]; then
      log_message "ERROR" "Failed to retrieve video title using yt-dlp. Cannot proceed. Check URL/ID and yt-dlp."
      return 1
    fi
    description=""
    log_message "INFO" "Using fallback method to get title."
  else
    log_message "DEBUG" "JSON metadata fetched successfully."
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

  mkdir -p "$sanitized_output_dir" || { log_message "ERROR" "Could not create output directory '$sanitized_output_dir'. Check permissions."; return 1; }

  yt-dlp -f bestaudio -x \
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

  local downloaded_audio_file="$expected_download_path"

  if [ "$yt_dlp_download_code" -eq 101 ]; then
    log_message "INFO" "Video already present in download archive. Checking if file exists..."
    if [ ! -f "$downloaded_audio_file" ]; then
      log_message "WARN" "Video in archive, but expected file not found: $downloaded_audio_file. Will attempt split if possible, but download may be incomplete."
    else
      log_message "INFO" "Existing file found: $downloaded_audio_file"
    fi
    yt_dlp_download_code=0
  elif [ "$yt_dlp_download_code" -ne 0 ]; then
    log_message "WARN" "yt-dlp download command failed or was interrupted (code $yt_dlp_download_code)."
    if [ ! -f "$downloaded_audio_file" ]; then
      log_message "ERROR" "Download command failed AND expected audio file '$downloaded_audio_file' not found."
      return "$yt_dlp_download_code"
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

  local segments=()
  local split_success=0
  local split_method="None"

  local title_list=()
  local silence_points=()
  local detected_silences=0
  local num_titles=0
  local detect_rc=1

  if [ ! -f "$downloaded_audio_file" ]; then
    log_message "ERROR" "Cannot proceed with splitting - audio file not found: $downloaded_audio_file"
    return 1
  fi

  # --- Chapters ---
  local chapters_array_json='[]'
  local chapters_count=0

  if [ -n "$video_info_json" ] && echo "$video_info_json" | jq -e '.chapters' > /dev/null 2>&1; then
    chapters_array_json=$(echo "$video_info_json" | jq -c '.chapters // []')
    chapters_count=$(echo "$chapters_array_json" | jq 'length')
  fi

  if (( chapters_count > 0 )); then
    log_message "INFO" "Found $chapters_count chapters. Parsing..."
    local i=1
    local temp_segments=()
    while IFS= read -r chapter_line; do
      local start_time_float
      start_time_float=$(echo "$chapter_line" | jq -r '.start_time // 0')

      local end_time_float
      end_time_float=$(echo "$chapter_line" | jq -r '.end_time // "null"')

      local chapter_title
      chapter_title=$(echo "$chapter_line" | jq -r '.title // empty')
      chapter_title=${chapter_title:-"Chapter_$i"}

      local start_sec
      start_sec=$(printf "%.0f" "$start_time_float")

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

      local safe_title
      safe_title=$(sanitize_filename "$chapter_title")
      safe_title=${safe_title:-"chapter_$i"}

      temp_segments+=("$start_sec $end_sec_str $safe_title")
      ((i++))
    done < <(echo "$chapters_array_json" | jq -c '.[]')

    if [ ${#temp_segments[@]} -gt 0 ]; then
      segments=("${temp_segments[@]}")
      split_method="Chapters"
      log_message "INFO" "Parsed chapters into ${#segments[@]} segments."
    fi
  fi

  # --- Timestamped Description ---
  if [ "$split_method" == "None" ]; then
    log_message "INFO" "No chapters found. Checking description for timestamped tracks..."
    local tracks=()
    local timestamp_regex='^[[:space:]]*(([0-9]+):)?([0-9]+:[0-9]{2})[[:space:]]+(.+)$'

    if [ -z "$description" ] && [ -n "$video_info_json" ]; then
      description=$(echo "$video_info_json" | jq -r '.description // empty')
    elif [ -z "$description" ]; then
      log_message "DEBUG" "Fetching description separately for timestamp check..."
      description=$(yt-dlp --print "%(description)s" --skip-download -- "$target_url" 2>/dev/null)
    fi

    if [ -n "$description" ]; then
      while IFS= read -r line; do
        if [[ "$line" =~ $timestamp_regex ]]; then
          local hh_part="${BASH_REMATCH[2]}"
          local mm_ss_part="${BASH_REMATCH[3]}"
          local track_title="${BASH_REMATCH[4]}"
          local full_ts
          if [[ -n "$hh_part" ]]; then full_ts="${hh_part}:${mm_ss_part}"; else full_ts="${mm_ss_part}"; fi

          local start_sec
          start_sec=$(timestamp_to_seconds "$full_ts")

          local safe_title
          safe_title=$(sanitize_filename "$track_title")
          safe_title=${safe_title:-"track"}

          tracks+=("$start_sec $safe_title")
        fi
      done <<< "$description"

      if (( ${#tracks[@]} > 1 )); then
        IFS=$'\n' read -r -d '' -a sorted_tracks < <(printf "%s\n" "${tracks[@]}" | sort -n -k1,1 && printf '\0')
        local temp_segments=()
        for (( i=0; i<${#sorted_tracks[@]}; i++ )); do
          read -r start_sec safe_title <<< "${sorted_tracks[i]}"
          local end_sec_str="EOF"
          if (( i < ${#sorted_tracks[@]} - 1 )); then
            read -r next_start_sec _ <<< "${sorted_tracks[i+1]}"
            if (( next_start_sec > start_sec )); then
              end_sec_str="$next_start_sec"
            else
              log_message "WARN" "Timestamped track $i end time ($next_start_sec) <= start time ($start_sec). Using EOF."
            fi
          fi
          temp_segments+=("$start_sec $end_sec_str $safe_title")
        done
        if [ ${#temp_segments[@]} -gt 0 ]; then
          segments=("${temp_segments[@]}")
          split_method="Timestamped Description"
          log_message "INFO" "Created ${#segments[@]} segments from description timestamps."
        fi
      fi
    fi
  fi

  # --- Silence Detection ---
  if [ "$split_method" == "None" ]; then
    log_message "INFO" "No chapters or timestamped tracks. Trying silence detection..."
    detect_silence_points "$downloaded_audio_file" "$SILENCE_DB" "$SILENCE_SEC"
    detect_rc=$?
    if [ "$detect_rc" -eq 0 ]; then
      while IFS= read -r silence_point; do
        silence_points+=("$silence_point")
      done < <(detect_silence_points "$downloaded_audio_file" "$SILENCE_DB" "$SILENCE_SEC")
      detected_silences=${#silence_points[@]}
      if [ "$detected_silences" -gt 0 ]; then
        log_message "INFO" "Silence detection found ${detected_silences} points. Attempting to use them for splitting..."
        if parse_description_for_titles <<< "$description"; then
          readarray -t title_list < <(parse_description_for_titles <<< "$description")
          num_titles=${#title_list[@]}
          if [ "$num_titles" -eq "$((detected_silences + 1))" ]; then
            split_method="Silence Detection with Description Titles"
            local temp_segments=()
            local i=0
            while (( i <= detected_silences )); do
              local end_sec_float
              if (( i < detected_silences )); then
                end_sec_float="${silence_points[$i]}"
              else
                end_sec_float="EOF"
              fi
              local title="${title_list[$i]}"
              local safe_title
              safe_title=$(sanitize_filename "$title")
              safe_title=${safe_title:-"track_$((i+1))"}
              local start_sec_float=0
              if (( i > 0 )); then
                start_sec_float="${silence_points[$((i-1))]}"
              fi
              local start_sec_int
              start_sec_int=$(printf "%.0f" "$start_sec_float")
              temp_segments+=("$start_sec_int $end_sec_float $safe_title")
              ((i++))
            done
            segments=("${temp_segments[@]}")
          else
            split_method="Silence Detection with Generic Titles"
            local temp_segments=()
            local i=0
            while (( i <= detected_silences )); do
              local end_sec_float
              if (( i < detected_silences )); then
                end_sec_float="${silence_points[$i]}"
              else
                end_sec_float="EOF"
              fi
              local safe_title
              safe_title=$(printf "Track_%03d" $((i+1)))
              local start_sec_float=0
              if (( i > 0 )); then
                start_sec_float="${silence_points[$((i-1))]}"
              fi
              local start_sec_int
              start_sec_int=$(printf "%.0f" "$start_sec_float")
              temp_segments+=("$start_sec_int $end_sec_float $safe_title")
              ((i++))
            done
            segments=("${temp_segments[@]}")
          fi
        else
          split_method="Silence Detection with Generic Titles"
          local temp_segments=()
          local i=0
          while (( i <= detected_silences )); do
            local end_sec_float
            if (( i < detected_silences )); then
              end_sec_float="${silence_points[$i]}"
            else
              end_sec_float="EOF"
            fi
            local safe_title
            safe_title=$(printf "Track_%03d" $((i+1)))
            local start_sec_float=0
            if (( i > 0 )); then
              start_sec_float="${silence_points[$((i-1))]}"
            fi
            local start_sec_int
            start_sec_int=$(printf "%.0f" "$start_sec_float")
            temp_segments+=("$start_sec_int $end_sec_float $safe_title")
            ((i++))
          done
          segments=("${temp_segments[@]}")
        fi
      else
        log_message "INFO" "Fallback to full track due to no identified silence."
      fi
    else
      log_message "WARN" "Silence detection failed. Cannot proceed with silence splitting."
    fi
  fi

  # --- Perform Splitting ---
  local num_segments=${#segments[@]}

  if (( num_segments > 0 )) && [[ "$split_method" != "None" ]]; then
    split_success=1
    log_message "INFO" "Splitting into $num_segments tracks using method: $split_method"
    local i=0
    while (( i < num_segments )); do
      local start_sec end_sec_str track_title
      read -r start_sec end_sec_str track_title <<< "${segments[$i]}"
      local track_num=$((i+1))
      local output_file
      output_file="$sanitized_output_dir/$(printf "%03d" "$track_num") - $track_title.mp3"
      log_message "DEBUG" "Track $track_num: start=$start_sec, end=$end_sec_str, title='$track_title', output='$output_file'"
      if [[ "$end_sec_str" == "EOF" ]]; then
        ffmpeg -hide_banner -nostats -ss "$start_sec" -i "$downloaded_audio_file" -vn -acodec copy "$output_file"
      else
        ffmpeg -hide_banner -nostats -ss "$start_sec" -to "$end_sec_str" -i "$downloaded_audio_file" -vn -acodec copy "$output_file"
      fi
      local ffmpeg_rc=$?
      if [ "$ffmpeg_rc" -ne 0 ]; then
        log_message "ERROR" "ffmpeg split command failed for track $track_num (code $ffmpeg_rc). Aborting split."
        split_success=0
        break
      fi
      ((i++))
    done

    if [ "$split_success" -eq 1 ]; then
      log_message "INFO" "Splitting completed successfully! Removing original audio file: $(basename "$downloaded_audio_file")"
      rm -f "$downloaded_audio_file"
    else
      log_message "WARN" "Splitting failed (one or more tracks). Keeping original audio file."
    fi
  else
    log_message "INFO" "No segments found using any method. Keeping full audio track."
  fi

  # --- Completion Banner ---
  cat <<'EOF'
 ___________  __    __       __  ___________                    
("     _   ")/" |  | "\     /""\("     _   ")                   
 )__/  \\__/(:  (__)  :)   /    \)__/  \\__/                    
    \\_ /    \/      \/   /' /\  \  \\_ /                       
    |.  |    //  __  \\  //  __'  \ |.  |                       
    \:  |   (:  (  )  :)/   /  \\  \\:  |                       
     \__|    \__|  |__/(___/    \___)\__|                       
                                                                
      ________  __    __   __  ___________  ____  ________      
     /"       )/" |  | "\ |" \("     _   ")))_ ")/"       )     
    (:   \___/(:  (__)  :)||  |)__/  \\__/(____((:   \___/      
     \___  \   \/      \/ |:  |   \\_ /          \___  \        
      __/  \\  //  __  \\ |.  |   |.  |           __/  \\       
     /" \   :)(:  (  )  :)/\  |\  \:  |          /" \   :)      
    (_______/  \__|  |__/(__\_|_)  \__|         (_______/       
                                                                
         ________      ______    _____  ___    _______     ___  
        |"      "\    /    " \  (\"   \|"  \  /"     "|   |"  | 
        (.  ___  :)  // ____  \ |.\\   \    |(: ______)   ||  | 
        |: \   ) || /  /    ) :)|: \.   \\  | \/    |     |:  | 
        (| (___\ ||(: (____/ // |.  \    \. | // ___)_   _|  /  
        |:       :) \        /  |    \    \ |(:      "| / |_/ ) 
        (________/   \"_____/    \___|\____\) \_______)(_____/  
EOF
  echo
}

# --- Script entrypoint ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rip "$@"
fi
