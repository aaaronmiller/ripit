rip() {
    # Check if a URL argument was provided
    if [ -z "$1" ]; then
        echo "Usage: rip <youtube_url>"
        echo "Error: No YouTube URL provided."
        return 1
    fi

    local target_url="$1"
    local base_dir="$HOME/music/YTdownloads"
    local archive_file="$base_dir/downloaded_archive.txt"

    # Ensure directories exist
    [ ! -d "$base_dir" ] && mkdir -p "$base_dir"
    [ ! -f "$archive_file" ] && touch "$archive_file"

    echo "Processing URL: $target_url"
    local video_title=$(yt-dlp --get-filename -o "%(title)s" "$target_url")
    local output_dir="$base_dir/$video_title"
    echo "Output directory: $output_dir"
    echo "Using archive file: $archive_file"

    # Create the output directory if it doesn't exist
    [ ! -d "$output_dir" ] && mkdir -p "$output_dir"

    # Download the audio with yt-dlp
    yt-dlp \
        -f bestaudio \
        -x \
        --audio-format mp3 \
        --audio-quality 0 \
        --embed-metadata \
        --add-metadata \
        --embed-thumbnail \
        --download-archive "$archive_file" \
        --no-overwrites \
        -o "$output_dir/%(title)s.%(ext)s" \
        --no-part \
        -- "$target_url"

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo "yt-dlp initial download finished successfully (exit code 0)."

        # Get chapter information in JSON format
        local chapter_info=$(yt-dlp --print-json -c --skip-download "$target_url")

        # Process each chapter and split the audio
        local i=1
        for chapter in $(echo "$chapter_info" | jq -r '.chapters[]'); do
            local start_time=$(echo "$chapter" | jq -r '.start_time')
            local end_time=$(echo "$chapter" | jq -r '.end_time')
            # Sanitize chapter title to remove problematic characters for filenames
            local chapter_title=$(echo "$chapter" | jq -r '.title | @json')
            local safe_chapter_title=$(echo "$chapter_title")

            # Extract audio segment using ffmpeg
           ffmpeg -ss "$start_time" -to "$end_time" \
                -i "$output_dir/$video_title.mp3" \
                -vn -acodec libmp3lame -q:a 0 \
                "$output_dir/$(printf "%03d" "$i") - $(echo "$safe_chapter_title" | sed 's/[^a-zA-Z0-9._ -]//g' | sed 's/["\\\\]/\\\\&/g' | jq -r '.').mp3"

            ((i++))
        done

        # Remove residual .webp file
        find "$output_dir" -name "*.webp" -delete

        # Remove the original unsplit file
        rm -f "$output_dir/$video_title.mp3"
        echo "Removed original file: $output_dir/$video_title.mp3"

    else
        echo "yt-dlp process failed (exit code: $exit_code)."
    fi

    # Return the captured exit status
    return $exit_code
}