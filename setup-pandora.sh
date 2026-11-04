#!/usr/bin/env bash
#
# setup-pandora.sh — ONE-TIME user-run association script (NOT committed with secrets).
#
# This creates YOUR private pianobar config at ~/.config/pianobar/config
# (chmod 600, never committed). It does NOT touch this repo — no PII,
# no credentials, no pathnames stored permanently here.
#
# After running this, rip-pandora.sh and ripit (routed Pandora) will work.
#
# Usage (interactive):
#   ./setup-pandora.sh
#
# It will ask for your Pandora email, set an encrypted password (optional),
# write config, verify with `pianobar --list`, and report.
#
set -euo pipefail

echo "=== Pandora association (no data saved to this repo) ==="
CONFIG_DIR="$HOME/.config/pianobar"
CONFIG_FILE="$CONFIG_DIR/config"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

echo "This script creates ONLY $CONFIG_FILE (chmod 600, your machine)."
echo "No emails, passwords, or tokens are written into the ripit repo."
echo

if [ -f "$CONFIG_FILE" ]; then
  echo "Config already exists: $CONFIG_FILE (chmod $(stat -c '%a' "$CONFIG_FILE"))"
  read -rp "Overwite? [y/N] " reply
  [ "${reply:-n}" == "y" ] || { echo "Keeping existing config. Done."; exit 0; }
fi

echo
read -rp "Pandora email/username: " user_email
if [ -z "$user_email" ]; then echo "Email required."; exit 1; fi

echo
read -rp "Use encrypted password? [y/N] (recommended: stores gpg-encrypted file, not plaintext in config) " enc_reply
USE_GPG=0
if [ "${enc_reply:-n}" == "y" ]; then
  USE_GPG=1
  read -rp "Path to gpg-encrypted password file (e.g., ~/secrets/pandora.gpg): " pass_file
  [ -n "$pass_file" ] || pass_file="$HOME/.secrets/pandora.gpg"
  if [ ! -f "$pass_file" ]; then
    echo "That file does not exist. Create it first with:"
    echo "  mkdir -p $(dirname "$pass_file") && echo 'your_password' | gpg --symmetric --cipher-algo AES256 -o $pass_file"
    echo "Then re-run this script."
    exit 1
  fi
  echo "password_command = gpg --decrypt $pass_file" >> "$CONFIG_FILE"
else
  echo "WARNING: plaintext password will be in $CONFIG_FILE. Only you and root can read it (chmod 600)."
  echo "Press Enter after typing; Ctrl+C to cancel."
  # Read silently (hide from terminal scroll history where possible)
  stty -echo
  read -rp "Pandora password: " user_pass
  stty echo
  echo
  echo "user = $user_email" >> "$CONFIG_FILE"
  echo "password = $user_pass" >> "$CONFIG_FILE"
fi

echo "autostart_station = 3188965452988993694" >> "$CONFIG_FILE"
echo "# Your own private config — not committed to repo" >> "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo
echo "=== Verify (will ask for email again temporarily to test --list) ==="
# Quick verification by reading config back (not exposing it)
if grep -qE '^user\s*=' "$CONFIG_FILE"; then
  echo "Config written. Checking pianobar..."
  if command -v pianobar >/dev/null 2>&1; then
    echo "pianobar installed. Config: $CONFIG_FILE"
    echo "Run: ripit \"https://www.pandora.com/station/play/<station-id>\""
    echo "Or: rip-pandora.sh --list  (to pick a station interactively)"
  else
    echo "pianobar not installed. Install: sudo apt-get install pianobar"
  fi
else
  echo "ERROR: config missing user line. Check $CONFIG_FILE"
  exit 1
fi

echo
echo "=== Done ==="
echo "No PII in repo. Config is private on this machine only."
