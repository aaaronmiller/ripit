#!/bin/bash

# Function to remove characters problematic for filenames/paths
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

# Function to convert HH:MM:SS or MM:SS to seconds
# Handles cases like "1:30:15" and "75:15" correctly
timestamp_to_seconds() {
    local ts=$1
    local seconds=0
    IFS=: read -ra parts <<< "$ts"
    local count=${#parts[@]}
    if [[ $count -eq 3 ]]; then # HH:MM:SS
        # Ensure parts are treated as decimal
        seconds=$((10#${parts[0]} * 3600 + 10#${parts[1]} * 60 + 10#${parts[2]}))
    elif [[ $count -eq 2 ]]; then # MM:SS
        seconds=$((10#${parts[0]} * 60 + 10#${parts[1]}))
    elif [[ $count -eq 1 ]]; then # SS (e.g., if timestamp was just "30")
        seconds=$((10#${parts[0]}))
    fi
    echo $seconds
}


rip() {
    # Check if a URL argument was provided
    if [ -z "$1" ]; then
        echo "Usage: rip <youtube_url>"
        echo "Error: No YouTube URL provided."
        return 1
    fi

    local target_url="$1"
    local base_dir="${YT_DOWNLOAD_DIR:-$HOME/music/YTdownloads}" # Allow override via env var
    local archive_file="$base_dir/downloaded_archive.txt"
    local overall_rc=0 # Track overall success/failure

    # Ensure directories exist
    mkdir -p "$base_dir" || { echo "Error: Could not create base directory '$base_dir'."; return 1; }
    touch "$archive_file" || { echo "Error: Could not create archive file '$archive_file'."; return 1; }

    echo "Processing URL: $target_url"

    # Get video title using --print to avoid filename interpretation issues early
    local video_title
    video_title=$(yt-dlp --no-warnings --print "%(title)s" "$target_url" 2>/dev/null)
    local yt_dlp_exit_code=$?

    if [ $yt_dlp_exit_code -ne 0 ] || [ -z "$video_title" ]; then
        echo "Error: Could not retrieve video title for URL: $target_url (yt-dlp exit code: $yt_dlp_exit_code)."
        # Attempt fallback title retrieval if needed (less common now)
        if [ $yt_dlp_exit_code -eq 0 ]; then
           video_title=$(yt-dlp --no-warnings --get-filename -o "%(title)s" "$target_url" 2>/dev/null)
           if [ -z "$video_title" ]; then
              echo "Error: Fallback title retrieval also failed."
              return 1
           fi
           echo "Warning: Used fallback method to get title."
        else
            return 1
        fi
    fi

    local sanitized_video_title
    sanitized_video_title=$(sanitize_filename "$video_title")
    if [ -z "$sanitized_video_title" ]; then
        echo "Error: Sanitized video title is empty. Using 'untitled'."
        sanitized_video_title="untitled"
    fi

    local sanitized_output_dir="$base_dir/$sanitized_video_title"
    # Define the expected output path based on yt-dlp's template
    # yt-dlp might do its own minor sanitization on the final component, but this is our target
    local expected_download_path="$sanitized_output_dir/$sanitized_video_title.mp3"

    echo "Video Title: $video_title"
    echo "Sanitized Title: $sanitized_video_title"
    echo "Output Directory: $sanitized_output_dir"
    echo "Expected File: $expected_download_path"
    echo "Using Archive File: $archive_file"

    # Create the specific output directory
    mkdir -p "$sanitized_output_dir" || { echo "Error: Could not create output directory '$sanitized_output_dir'."; return 1; }

    # Download the audio with yt-dlp
    # Use a specific output template matching our expected path base
    echo "Starting download..."
    yt-dlp \
        -f bestaudio -x \
        --audio-format mp3 \
        --audio-quality 0 \
        --embed-metadata \
        --add-metadata \
        --embed-thumbnail \
        --download-archive "$archive_file" \
        --no-overwrites \
        -o "$sanitized_output_dir/$sanitized_video_title.%(ext)s" \
        --no-part \
        -- "$target_url"

    local yt_dlp_download_code=$?

    # Use the expected path variable from now on
    local downloaded_audio_file="$expected_download_path"

    if [ $yt_dlp_download_code -ne 0 ]; then
        echo "Warning: yt-dlp download command failed with exit code $yt_dlp_download_code."
        # Check if the file exists anyway (e.g., from archive or previous run)
        if [ ! -f "$downloaded_audio_file" ]; then
           echo "Error: Download command failed AND expected audio file '$downloaded_audio_file' not found."
           return $yt_dlp_download_code
        else
           echo "Warning: Found existing file '$downloaded_audio_file'. Attempting to proceed with splitting."
        fi
    else
         echo "yt-dlp download command finished successfully."
         # Basic check that the expected file now exists
         if [ ! -f "$downloaded_audio_file" ]; then
             echo "Error: Download successful but expected file '$downloaded_audio_file' not found!"
             # Maybe yt-dlp sanitized the filename differently? Try a simple wildcard find
             local actual_file=$(find "$sanitized_output_dir" -maxdepth 1 -name "$sanitized_video_title*.mp3" -print -quit)
              if [ -n "$actual_file" ] && [ -f "$actual_file" ]; then
                  echo "Found file with slightly different name: '$actual_file'. Using it."
                  downloaded_audio_file="$actual_file"
              else
                  echo "Cannot locate the downloaded MP3 file in '$sanitized_output_dir'."
                  return 1
              fi
         else
            echo "Confirmed expected file exists: $downloaded_audio_file"
         fi
    fi


    # --- Splitting Logic ---
    local segments=() # Array to hold segment info: "start_sec end_sec title"
    local split_success=0 # Flag to track if splitting occurred and succeeded

    # 1. Try parsing chapters from JSON
    echo "Checking for chapters..."
    local chapter_info_json
    chapter_info_json=$(yt-dlp --print-json --skip-download "$target_url" 2>/dev/null)

    local chapters_array_json='[]'
    if echo "$chapter_info_json" | jq -e '.chapters' > /dev/null; then
        chapters_array_json=$(echo "$chapter_info_json" | jq -c '.chapters // []')
    fi

    local chapters_count
    chapters_count=$(echo "$chapters_array_json" | jq 'length')

    if [[ "$chapters_count" -gt 0 ]]; then
        echo "Found $chapters_count chapters. Parsing..."
        local i=1
        while IFS= read -r chapter_line; do
            local start_time_float=$(echo "$chapter_line" | jq -r '.start_time // 0')
            local end_time_float=$(echo "$chapter_line" | jq -r '.end_time // "null"') # Keep null distinction
            # Ensure title is fetched correctly even if null
            local chapter_title=$(echo "$chapter_line" | jq -r '.title // empty')
            chapter_title=${chapter_title:-"Chapter_$i"} # Provide default if empty string

            local start_sec=${start_time_float%.*} # Convert float to int seconds
            local end_sec="EOF" # Default to End Of File
            if [[ "$end_time_float" != "null" ]]; then
                end_sec=${end_time_float%.*}
            fi

            # Apply enhanced sanitization to the title
            local safe_title=$(sanitize_filename "$chapter_title")
            safe_title=${safe_title:-"chapter_$i"} # Ensure title isn't empty after sanitize

            segments+=("$start_sec $end_sec $safe_title")
            ((i++))
        done < <(echo "$chapters_array_json" | jq -c '.[]')
        echo "Parsed chapters into segments."

    else
        echo "No chapters found in video metadata."
        # 2. Fallback: Try parsing description for timestamps
        echo "Attempting to parse tracklist from description..."
        local description
        description=$(echo "$chapter_info_json" | jq -r '.description // ""' 2>/dev/null)

        if [ -z "$description" ]; then
            echo "Fetching description separately..."
            description=$(yt-dlp --print "%(description)s" --skip-download "$target_url" 2>/dev/null)
        fi

        if [ -n "$description" ]; then
            local tracks=()
            local timestamp_regex='^[[:space:]]*(([0-9]+):)?([0-9]+:[0-9]{2})[[:space:]]+(.+)$'

            echo "Scanning description for timestamps (Format: [HH:]MM:SS Title)..."
            while IFS= read -r line; do
                 if [[ "$line" =~ $timestamp_regex ]]; then
                    local hh_part="${BASH_REMATCH[2]}"
                    local mm_ss_part="${BASH_REMATCH[3]}"
                    local track_title="${BASH_REMATCH[4]}"

                    local full_ts
                    if [[ -n "$hh_part" ]]; then
                        full_ts="${hh_part}:${mm_ss_part}"
                    else
                        full_ts="${mm_ss_part}"
                    fi

                    local start_sec
                    start_sec=$(timestamp_to_seconds "$full_ts")
                    # Apply enhanced sanitization
                    local safe_title=$(sanitize_filename "$track_title")
                    safe_title=${safe_title:-"track"}

                    tracks+=("$start_sec $safe_title")
                 fi
            done <<< "$description"

            if [ ${#tracks[@]} -gt 1 ]; then
                echo "Found ${#tracks[@]} potential tracks in description. Sorting and creating segments..."
                IFS=$'\n' sorted_tracks=($(sort -n -k1,1 <<<"${tracks[*]}"))
                unset IFS

                segments=() # Reset segments array
                for (( i=0; i<${#sorted_tracks[@]}; i++ )); do
                    read -r start_sec safe_title <<< "${sorted_tracks[i]}"
                    local end_sec="EOF"
                    if [[ $i -lt $((${#sorted_tracks[@]} - 1)) ]]; then
                        read -r next_start_sec _ <<< "${sorted_tracks[i+1]}"
                        end_sec=$next_start_sec
                    fi
                    segments+=("$start_sec $end_sec $safe_title")
                done
                 echo "Created ${#segments[@]} segments from description."
            elif [ ${#tracks[@]} -eq 1 ]; then
                 echo "Found only one timestamp in description. Cannot determine end time for splitting."
            else
                echo "Did not find enough timestamped tracks (need >= 2 ideally) in description."
            fi
        else
            echo "Video description is empty or could not be retrieved."
        fi
    fi

    # --- Execute Splitting if Segments were Found ---
    if [ ${#segments[@]} -gt 0 ]; then
        echo "Proceeding to split audio into ${#segments[@]} segments..."
        local split_failed_count=0
        local i=1
        for segment in "${segments[@]}"; do
            read -r start_sec end_sec safe_title <<< "$segment"

            local output_filename
            # Ensure safe_title is used here after being sanitized above
            output_filename=$(printf "%s/%03d - %s.mp3" "$sanitized_output_dir" "$i" "$safe_title")

            local ffmpeg_end_time_opt=()
            if [[ "$end_sec" != "EOF" ]] && (( end_sec > start_sec )); then
                ffmpeg_end_time_opt=(-to "$end_sec")
            elif [[ "$end_sec" != "EOF" ]]; then
                 echo "Warning: Segment $i end time ($end_sec) is not after start time ($start_sec). Skipping -to."
            fi

            echo "Splitting segment $i: '$safe_title' ($start_sec -> $end_sec) -> $(basename "$output_filename")"

            # Use simplified metadata, ensure output filename is quoted
            ffmpeg -hide_banner -loglevel error \
                -i "$downloaded_audio_file" \
                -ss "$start_sec" \
                "${ffmpeg_end_time_opt[@]}" \
                -vn -acodec copy \
                -metadata track="$i" \
                -metadata title="$safe_title" \
                -metadata album="$video_title" \
                 -y \
                "$output_filename" # Output filename MUST be the last argument typically

            local ffmpeg_rc=$?
            if [ $ffmpeg_rc -ne 0 ]; then
                # Provide more context on ffmpeg failure
                echo "Error: ffmpeg failed (code $ffmpeg_rc) for segment $i ('$safe_title')."
                echo "Input: '$downloaded_audio_file'"
                echo "Output attempt: '$output_filename'"
                echo "Start: $start_sec, End: $end_sec"
                ((split_failed_count++))
                overall_rc=1 # Mark that something went wrong
            fi
            ((i++))
        done

        if [ $split_failed_count -eq 0 ]; then
            echo "Splitting completed successfully for all segments."
            split_success=1
        else
            echo "Warning: Splitting failed for $split_failed_count out of ${#segments[@]} segment(s)."
        fi

        # Remove original file only if splitting occurred AND was fully successful
        if [ "$split_success" -eq 1 ]; then
            echo "Removing original file: $downloaded_audio_file"
            rm -f "$downloaded_audio_file"
            if [ $? -ne 0 ]; then
                 echo "Warning: Could not remove original file '$downloaded_audio_file'."
            fi
        else
             echo "Original file kept due to splitting errors or no segments defined for splitting."
             if [ ${#segments[@]} -gt 0 ] && [ "$split_success" -eq 0 ]; then
                 overall_rc=1
             fi
        fi

    else
        echo "No chapters or parsable description tracklist found. Keeping the original downloaded file."
    fi

    # Clean up any stray thumbnail files (yt-dlp might leave .webp)
    find "$sanitized_output_dir" -maxdepth 1 -name "*.webp" -delete 2>/dev/null || true

    echo "Processing finished for '$video_title'."
    return $overall_rc
}

# Execute the function with the first script argument
rip "$1"