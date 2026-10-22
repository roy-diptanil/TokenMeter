#!/bin/bash
#
# TokenMeter uninstaller
#
#   curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/uninstall.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/uninstall.sh | bash -s -- --purge-data --yes
#   ~/.tokenmeter-src/uninstall.sh [--purge-data] [--yes]   (only exists if you ever built from source)
#
# Run through a pipe there is no terminal to confirm on, so --purge-data needs --yes.
#
# What this script does:
#   - Quits TokenMeter (gracefully, force-kill only as a last resort).
#   - Removes ~/Applications/TokenMeter.app (the default install location; no sudo needed)
#     and $TOKENMETER_DEST/TokenMeter.app (default /Applications, for system-wide installs),
#     using sudo only if that /Applications folder is not writable.
#   - Removes the source checkout $TOKENMETER_SRC (default ~/.tokenmeter-src).
#   - By default KEEPS your data (accounts, cache, WebKit sign-in sessions).
#   - With --purge-data it also deletes that data. It lists exactly what will be
#     deleted and asks you to type `yes` unless --yes is given.
#
# No network access.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--purge-data] [--yes] [-h|--help]

  --purge-data  also delete TokenMeter's saved accounts, cache and WebKit sign-in data
  --yes         skip the confirmation prompt for --purge-data
EOF
}

say() { printf '==> %s\n' "$*"; }

main() {
  local PURGE=0 YES=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-data) PURGE=1 ;;
      --yes|-y) YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done

  local SRC="${TOKENMETER_SRC:-$HOME/.tokenmeter-src}"
  local DEST="${TOKENMETER_DEST:-/Applications}"
  local APP="$DEST/TokenMeter.app"
  local BID="com.local.tokenmeter"

  trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "==> Uninstall did not finish (exit %s).\n" "$rc" >&2; fi' EXIT

  # Run from a neutral dir: this script may live inside the checkout being removed.
  cd "$HOME"

  # Decide on data purge first, so a declined prompt changes nothing.
  local DATA=()
  if [ "$PURGE" -eq 1 ]; then
    local c
    for c in \
      "$HOME/Library/Application Support/TokenMeter" \
      "$HOME/Library/WebKit/$BID" \
      "$HOME/Library/Caches/$BID" \
      "$HOME/Library/HTTPStorages/$BID" \
      "$HOME/Library/Preferences/$BID.plist" \
      "$HOME/Library/Saved Application State/$BID.savedState"; do
      if [ -e "$c" ]; then DATA+=("$c"); fi
    done
    if [ "${#DATA[@]}" -gt 0 ]; then
      say "--purge-data will delete:"
      local d
      for d in "${DATA[@]}"; do printf '      %s\n' "$d"; done
      if [ "$YES" -ne 1 ]; then
        local answer=""
        if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
          printf '==> Type yes to confirm: ' >/dev/tty
          read -r answer </dev/tty || answer=""
        else
          say "No terminal available to confirm; re-run with --yes to proceed."
          exit 1
        fi
        if [ "$answer" != "yes" ]; then
          say "Cancelled. Nothing was changed."
          exit 1
        fi
      fi
    else
      say "No TokenMeter data found to purge."
    fi
  fi

  # Quit app
  if pgrep -x TokenMeter >/dev/null 2>&1; then
    say "Quitting TokenMeter"
    osascript -e 'tell application "TokenMeter" to quit' >/dev/null 2>&1 || true
    local i=0
    while pgrep -x TokenMeter >/dev/null 2>&1 && [ "$i" -lt 16 ]; do
      sleep 0.5
      i=$((i + 1))
    done
    if pgrep -x TokenMeter >/dev/null 2>&1; then
      pkill -x TokenMeter >/dev/null 2>&1 || true
      sleep 1
    fi
  fi

  # Remove app
  if [ -e "$APP" ]; then
    say "Removing $APP"
    if [ -w "$DEST" ]; then
      rm -rf "$APP"
    else
      say "$DEST is not writable; using sudo for this step only."
      sudo rm -rf "$APP"
    fi
  else
    say "No app at $APP"
  fi

  # Default install location (only this one bundle).
  local HAPP="$HOME/Applications/TokenMeter.app"
  if [ "$HAPP" != "$APP" ] && [ -e "$HAPP" ]; then
    say "Removing $HAPP"
    rm -rf "$HAPP"
  fi

  # Remove source checkout
  if [ -d "$SRC/.git" ] && [ -f "$SRC/build.sh" ] && [ -f "$SRC/Package.swift" ]; then
    say "Removing $SRC"
    rm -rf "$SRC"
  elif [ -e "$SRC" ]; then
    say "Leaving $SRC alone: it does not look like a TokenMeter checkout."
  fi

  # Purge data
  if [ "$PURGE" -eq 1 ] && [ "${#DATA[@]}" -gt 0 ]; then
    local d
    for d in "${DATA[@]}"; do
      say "Deleting $d"
      rm -rf "$d"
    done
  elif [ "$PURGE" -eq 0 ]; then
    say "Kept your data (~/Library/Application Support/TokenMeter and WebKit sessions). Use --purge-data to delete it."
  fi

  say "Done. If you enabled 'Launch at login', also remove TokenMeter under System Settings > General > Login Items if it still appears."
}

main "$@"
