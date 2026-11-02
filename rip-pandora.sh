#!/usr/bin/env bash
#
# rip-pandora.sh — Silently record a Pandora station in the background.
#
# HOW IT WORKS
#   Uses pianobar (console Pandora client) for authenticated playback and
#   records its audio to per-track MP3s via a PulseAudio null sink, so
#   nothing ever reaches your speakers and your terminal stays free.
#
# PRIVACY / NO-PII DESIGN
#   This repo ships ONLY generic scripts. Credentials NEVER live here:
#     - Pandora login goes in  ~/.config/pianobar/config  (your machine only,
#       chmod 600; pianobar also supports `password_command = gpg ...` so the
#       password itself never sits in plaintext).
#     - This script reads the station ID from its CLI arg or from your local
#       config; it never writes credentials anywhere and never prints them.
#   Safe to commit/push this file: grep it — no emails, passwords, tokens.
#
# PREREQUISITES (installed once on your machine, NOT in repo)
#   pianobar, ffmpeg, PulseAudio utils (pactl/parec), jq (for track metadata)
#
# USAGE
#   rip-pandora.sh <station-id> [-o dir] [-t minutes] [-q]    # foreground test
#   rip-pandora.sh <station-id> --detach [-o dir] [-t min]   # background, terminal free
#   rip-pandora.sh --stop                                    # stop background recording
#   rip-pandora.sh --status                                  # show if recording
#   rip-pandora.sh --list                                    # list your stations (needs login)
#
#   Find your station ID: run `rip-pandora.sh --list`, or copy the number
#   from a pandora.com/station/play/<id> URL.
#
# OUTPUT
#   $OUT_DIR/<Artist>/<Title>.mp3 with ID3 tags (artist/title/album/station),
#   one file per songstart..songfinish event. No splitting needed — pianobar
#   tells us exact track boundaries via event_command.
#
# SILENT-BY-CONSTRUCTION
#   pianobar plays into a dedicated null sink (ripit_pandora, auto-created);
#   parec/ffmpeg taps ONLY that sink's .monitor. Your default sink is never
#   touched, so even a bug cannot leak audio to speakers.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIANOBAR_EVENT="$SCRIPT_DIR/pianobar-event.sh"

SINK_NAME="ripit_pandora"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ripit"
PID_FILE="$STATE_DIR/pandora.pid"
LOG_FILE="$STATE_DIR/pandora.log"
DEFAULT_OUT="$HOME/Music/Pandora"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed 's/^# \?//'
}

die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install: sudo apt-get install $2"
}

sanitize() {
  local s
  s=$(echo "$1" | sed -e 's#[^a-zA-Z0-9._-]#_#g' -e 's/__\+/_/g' -e 's/^_//' -e 's/_$//')
  s=${s:0:100}
  s=${s%_}
  echo "${s:-untitled}"
}

ensure_sink() {
  if ! pactl list sinks short 2>/dev/null | grep -q "^[0-9]*[[:space:]]$SINK_NAME[[:space:]]"; then
    pactl load-module module-null-sink sink_name="$SINK_NAME" \
      sink_properties=device.description="ripit_pandora_silent" >/dev/null \
      || die "could not create null sink (is PulseAudio running?)"
  fi
}

pianobar_config_ok() {
  local cfg="$HOME/.config/pianobar/config"
  [ -f "$cfg" ] || die "no pianobar config at $cfg — create it with your login (see pianobar docs / config-example), chmod 600"
  grep -qE '^\s*user\s*=' "$cfg" || die "pianobar config missing 'user =' line"
  grep -qE '^\s*(password|password_command)\s*=' "$cfg" || die "pianobar config missing 'password =' (or 'password_command =') line"
}

do_list() {
  pianobar_config_ok
  echo "Your stations (select one, Esc to quit):"
  exec pianobar
}

do_status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "recording (pid $(cat "$PID_FILE")). Log: $LOG_FILE"
  else
    echo "not recording."
  fi
}

do_stop() {
  if [ ! -f "$PID_FILE" ]; then echo "not recording."; return 0; fi
  local pid
  pid=$(cat "$PID_FILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    # also stop any child recorder tied to this run
    pkill -P "$pid" 2>/dev/null || true
    echo "stopped recording (was pid $pid)."
  else
    echo "stale pid file; cleaning up."
  fi
  rm -f "$PID_FILE"
}

record_session() {
  # Args: station_id out_dir minutes(boolean 0=unlimited)
  local station_id="$1" out_dir="$2" limit_min="$3"
  mkdir -p "$out_dir" "$STATE_DIR"
  ensure_sink
  pianobar_config_ok
  [ -x "$PIANOBAR_EVENT" ] || die "event handler missing: $PIANOBAR_EVENT"

  local ctl_dir
  ctl_dir=$(mktemp -d)
  local fifo="$ctl_dir/ctl"
  mkfifo "$fifo"

  # Per-run config: points pianobar at OUR fifo + event handler + autostart.
  # Credentials stay in the user's own config (included), never copied here —
  # `include` is supported by pianobar >= 2020.
  local run_cfg="$ctl_dir/pianobar.cfg"
  {
    echo "include = $HOME/.config/pianobar/config"
    echo "fifo = $fifo"
    echo "event_command = $PIANOBAR_EVENT"
    echo "autostart_station = $station_id"
    echo "audio_quality = high"
  } > "$run_cfg"
  chmod 600 "$run_cfg"

  # Event handler env: where to write tracks.
  export RIPIT_PANDORA_OUT="$out_dir"
  export RIPIT_PANDORA_STATE="$ctl_dir"

  echo "[rip-pandora] station $station_id → $out_dir (silent sink: $SINK_NAME)"
  echo "[rip-pandora] log: $LOG_FILE"

  # Tell pianobar to use ONLY our silent sink.
  export PULSE_SINK="$SINK_NAME"

  if [ "$limit_min" -gt 0 ] 2>/dev/null; then
    ( sleep $((limit_min * 60)); do_stop ) &
  fi

  # pianobar in background of this session; ctl fifo lets --stop reach it.
  # NOTE: pianobar reads config from XDG path; override via symlink-free
  # approach: XDG_CONFIG_HOME pointing at our ctl dir layout.
  mkdir -p "$ctl_dir/pianobar"
  cp "$run_cfg" "$ctl_dir/pianobar/config"
  chmod 600 "$ctl_dir/pianobar/config"
  # shellcheck disable=SC2034
  XDG_CONFIG_HOME="$ctl_dir" RIPIT_PANDORA_OUT="$out_dir" RIPIT_PANDORA_STATE="$ctl_dir" \
    PULSE_SINK="$SINK_NAME" nohup pianobar >>"$LOG_FILE" 2>&1 &
  local pb_pid=$!
  echo "$pb_pid" > "$PID_FILE"
  echo "[rip-pandora] pianobar pid $pb_pid. Detach with --detach, stop with --stop."
  wait "$pb_pid"
  local rc=$?
  rm -f "$PID_FILE"
  rm -rf "$ctl_dir"
  return $rc
}

main() {
  need_cmd pianobar pianobar
  need_cmd ffmpeg ffmpeg
  need_cmd pactl pulseaudio-utils
  need_cmd parec pulseaudio-utils

  local station="" out_dir="$DEFAULT_OUT" limit_min=0 detach=0

  [ $# -eq 0 ] && { usage; exit 1; }
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --stop) do_stop; exit 0 ;;
    --status) do_status; exit 0 ;;
    --list) shift; do_list ;;
  esac

  station="$1"; shift
  [[ "$station" =~ ^[0-9]+$ ]] || die "station ID must be numeric (from pandora.com/station/play/<id> or --list). Got: $station"

  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out_dir="$2"; shift 2 ;;
      -t) limit_min="$2"; shift 2 ;;
      --detach) detach=1; shift ;;
      -q) ;; # accepted for ripit.sh flag parity; recording is always quiet
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"

  if [ "$detach" -eq 1 ]; then
    # Fully detached: survives terminal close, gives prompt straight back.
    setsid nohup bash "$0" "$station" -o "$out_dir" -t "$limit_min" >>"$LOG_FILE" 2>&1 < /dev/null &
    echo "detached (pid $!). Terminal is free. --status / --stop to manage."
    echo "log: $LOG_FILE"
    exit 0
  fi

  record_session "$station" "$out_dir" "$limit_min"
}

main "$@"
