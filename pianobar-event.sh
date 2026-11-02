#!/usr/bin/env bash
#
# pianobar-event.sh — event_command handler for rip-pandora.sh
#
# Invoked by pianobar as: pianobar-event.sh <event-name>
# with track metadata on stdin as KEY=value lines.
#
# SILENT-BY-CONSTRUCTION: records ONLY the ripit_pandora null sink's
# .monitor via parec/ffmpeg. Default sink untouched — nothing can leak
# to speakers. No credentials here, no network, just local audio tap.
#
# Env from rip-pandora.sh:
#   RIPIT_PANDORA_OUT    base output dir
#   RIPIT_PANDORA_STATE  per-run state dir (holds current-track fifo/pid)
#
set -u

SINK_NAME="ripit_pandora"
OUT_BASE="${RIPIT_PANDORA_OUT:-$HOME/Music/Pandora}"
STATE_DIR="${RIPIT_PANDORA_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/ripit}"
REC_PID_FILE="$STATE_DIR/rec.pid"
META_FILE="$STATE_DIR/current.meta"

sanitize() {
  local s
  s=$(echo "$1" | sed -e 's#[^a-zA-Z0-9._-]#_#g' -e 's/__\+/_/g' -e 's/^_//' -e 's/_$//')
  s=${s:0:100}
  s=${s%_}
  echo "${s:-untitled}"
}

# Read pianobar's stdin (KEY=value) into vars we care about.
title=""; artist=""; album=""; stationName=""
while IFS= read -r line; do
  case "$line" in
    title=*) title="${line#title=}" ;;
    artist=*) artist="${line#artist=}" ;;
    album=*) album="${line#album=}" ;;
    stationName=*) stationName="${line#stationName=}" ;;
  esac
done < <(grep -e '^\(title\|artist\|album\|stationName\)=' /dev/stdin)

stop_recorder() {
  if [ -f "$REC_PID_FILE" ]; then
    local pid
    pid=$(cat "$REC_PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      # give ffmpeg/parec a moment to flush + close the file cleanly
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$REC_PID_FILE"
  fi
}

case "${1:-}" in
  songstart)
    stop_recorder # safety: never two recorders at once
    safe_artist=$(sanitize "$artist")
    safe_title=$(sanitize "$title")
    track_dir="$OUT_BASE/$safe_artist"
    mkdir -p "$track_dir"
    outfile="$track_dir/${safe_artist} - ${safe_title}.mp3"
    # dedupe: don't overwrite an existing full track
    if [ -f "$outfile" ]; then
      i=2
      while [ -f "$track_dir/${safe_artist} - ${safe_title} ($i).mp3" ]; do i=$((i+1)); done
      outfile="$track_dir/${safe_artist} - ${safe_title} ($i).mp3"
    fi
    printf '%s\n%s\n%s\n%s\n' "$artist" "$title" "$album" "$stationName" > "$META_FILE"
    echo "$outfile" >> "$META_FILE"

    # Record ONLY our silent null sink's monitor → per-track MP3 with tags.
    # parec (raw) piped to ffmpeg (mp3 + id3v2) so a kill mid-track still
    # leaves a playable file; songfinish stops it cleanly.
    # shellcheck disable=SC2086
    ( parec --device="$SINK_NAME.monitor" --format=s16le --rate=44100 --channels=2 2>/dev/null \
      | ffmpeg -hide_banner -loglevel error -y \
        -f s16le -ar 44100 -ac 2 -i - \
        -codec:a libmp3lame -q:a 2 \
        -metadata artist="$artist" -metadata title="$title" \
        -metadata album="$album" -metadata comment="Pandora station: $stationName (rip-pandora)" \
        "$outfile" 2>/dev/null & echo $! > "$REC_PID_FILE" )
    ;;

  songfinish)
    stop_recorder
    rm -f "$META_FILE"
    ;;

  userlogin|usergetstations|stationfetchplaylist|stationfetchinfo)
    # routine events — nothing to do; exit 0 keeps pianobar happy
    ;;

  *)
    # on failures (pRet != 1 handled by pianobar itself) just stop safely
    ;;
esac

exit 0
