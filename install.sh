#!/bin/bash
#
# TokenMeter installer
#
#   curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh | bash
#
# What this script does (read it before piping to bash):
#   1. Checks you are on macOS 14 or newer and have the Swift toolchain
#      (Xcode Command Line Tools). If not, it starts `xcode-select --install`
#      and exits so you can re-run it afterwards.
#   2. Clones (or updates) the source into  $TOKENMETER_SRC  (default ~/.tokenmeter-src).
#      That folder is a throwaway build checkout owned by this script: an existing
#      git checkout there is fetched and hard-reset to origin/main.
#   3. Runs ./build.sh there (swift build, ad-hoc signed app bundle).
#   4. Picks where to install, and checks it is usable, BEFORE touching the running
#      app. In order: (1) $TOKENMETER_DEST (default /Applications) if writable;
#      (2) an existing, user-owned $TOKENMETER_DEST/TokenMeter.app is updated in
#      place with rsync (works even when the folder itself is not writable);
#      (3) sudo, only if it can really work (passwordless, or a terminal to prompt on);
#      (4) otherwise ~/Applications, and it tells you so.
#   5. Quits a running TokenMeter and installs the new copy. If the install step
#      fails, the previous app is relaunched. Then it removes the quarantine flag
#      and opens the installed app.
#
# It never touches ~/Library/Application Support/TokenMeter or WebKit data, so
# your sign-ins survive updates. The only network access is git clone/fetch of
# the repository. No telemetry.
#
# Environment overrides:
#   TOKENMETER_SRC   source checkout dir   (default: $HOME/.tokenmeter-src)
#   TOKENMETER_DEST  install parent dir    (default: /Applications)
#   TOKENMETER_REPO  git URL               (default: https://github.com/roy-diptanil/TokenMeter.git)
#   TOKENMETER_NO_LAUNCH=1  skip quitting and opening the app (for testing only)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [-h|--help]

Builds TokenMeter from source and installs it to /Applications.

Environment:
  TOKENMETER_SRC   source checkout dir (default: ~/.tokenmeter-src)
  TOKENMETER_DEST  install parent dir  (default: /Applications)
  TOKENMETER_REPO  git URL (default: https://github.com/roy-diptanil/TokenMeter.git)
  TOKENMETER_NO_LAUNCH=1  skip quitting/opening the app (testing only)
EOF
}

say()  { printf '==> %s\n' "$*"; }
fail() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

# install_app MODE SUDO BUILT APP: copy = stage + swap (old bundle restored on failure); inplace = rsync into the user-owned bundle.
install_app() {
  local mode="$1" S="$2" built="$3" app="$4"
  if [ "$mode" = "inplace" ]; then
    rsync -a --delete "$built/" "$app/"
    return
  fi
  local dir stage old
  dir="$(dirname "$app")"; stage="$dir/.TokenMeter.new.$$"; old="$dir/.TokenMeter.old.$$"
  $S mkdir -p "$dir" || return 1
  $S rm -rf "$stage" "$old"
  $S cp -R "$built" "$stage" || { $S rm -rf "$stage"; return 1; }
  if [ -e "$app" ]; then $S mv "$app" "$old" || { $S rm -rf "$stage"; return 1; }; fi
  if ! $S mv "$stage" "$app"; then
    if [ -e "$old" ]; then $S mv "$old" "$app" || true; fi
    $S rm -rf "$stage"; return 1
  fi
  $S rm -rf "$old"
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac

  local SRC="${TOKENMETER_SRC:-$HOME/.tokenmeter-src}"
  local DEST="${TOKENMETER_DEST:-/Applications}"
  local REPO="${TOKENMETER_REPO:-https://github.com/roy-diptanil/TokenMeter.git}"
  local APP="$DEST/TokenMeter.app"

  trap 'rc=$?; if [ "$rc" -ne 0 ]; then printf "==> Install did not finish (exit %s). Fix the issue above and re-run; it is safe to repeat.\n" "$rc" >&2; fi' EXIT

  # (a) platform
  [ "$(uname -s)" = "Darwin" ] || fail "TokenMeter is a macOS app."
  local ver major arch
  ver="$(sw_vers -productVersion)"
  major="${ver%%.*}"
  arch="$(uname -m)"
  case "$arch" in arm64|x86_64) ;; *) fail "Unsupported architecture: $arch" ;; esac
  [ "$major" -ge 14 ] 2>/dev/null || fail "macOS 14 or newer is required (found $ver)."
  say "macOS $ver ($arch)"

  # (b) Swift toolchain
  if ! { xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; } </dev/null; then
    say "Swift toolchain not found. Starting Xcode Command Line Tools install..."
    xcode-select --install </dev/null >/dev/null 2>&1 || true
    fail "Finish the Command Line Tools install dialog, then re-run this installer."
  fi
  command -v git >/dev/null 2>&1 || fail "git not found."

  # (c) source checkout
  if [ -d "$SRC/.git" ]; then
    say "Updating source in $SRC"
    git -C "$SRC" remote set-url origin "$REPO" </dev/null
    git -C "$SRC" fetch --quiet origin main </dev/null
    git -C "$SRC" checkout --quiet -B main origin/main </dev/null
    git -C "$SRC" reset --quiet --hard origin/main </dev/null
  elif [ -e "$SRC" ]; then
    fail "$SRC exists but is not a git checkout. Move it away or set TOKENMETER_SRC."
  else
    say "Cloning $REPO into $SRC"
    git clone --quiet --depth 1 --branch main "$REPO" "$SRC" </dev/null
  fi

  # (d) build
  say "Building (this takes a minute or two)..."
  ( cd "$SRC" && ./build.sh </dev/null )
  local BUILT="$SRC/build/TokenMeter.app"
  [ -d "$BUILT" ] || fail "Build finished but $BUILT was not produced."

  # (e) decide where to install and verify it BEFORE quitting anything
  local MODE="" SUDO="" NOLAUNCH="${TOKENMETER_NO_LAUNCH:-0}"
  local parent
  parent="$(dirname "$DEST")"
  if { [ -d "$DEST" ] && [ -w "$DEST" ]; } || { [ ! -e "$DEST" ] && [ -w "$parent" ]; }; then
    MODE="copy"
  elif [ -d "$APP" ] && [ -w "$APP" ] && [ -w "$APP/Contents" ] && command -v rsync >/dev/null 2>&1; then
    MODE="inplace"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    MODE="sudo"
  elif command -v sudo >/dev/null 2>&1 && { [ -t 0 ] || { [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; }; }; then
    say "$DEST is not writable; asking for your password (sudo) for the install step only."
    if sudo -v; then MODE="sudo"; fi
  fi
  if [ "$MODE" = "sudo" ]; then SUDO="sudo"; fi
  if [ -z "$MODE" ]; then
    local HOME_DEST="$HOME/Applications"
    say "$DEST is not writable and sudo is not usable here; installing to $HOME_DEST instead."
    mkdir -p "$HOME_DEST" 2>/dev/null && [ -w "$HOME_DEST" ] || fail "Cannot write to $DEST or $HOME_DEST. Nothing was changed."
    DEST="$HOME_DEST"; APP="$DEST/TokenMeter.app"; MODE="copy"
  fi
  say "Install mode: $MODE ($APP)"

  # (f) quit running app (only now that the destination is known to work)
  local WAS_RUNNING=0 PREV=""
  if [ -d "/Applications/TokenMeter.app" ]; then PREV="/Applications/TokenMeter.app"; fi
  if [ -d "$HOME/Applications/TokenMeter.app" ] && [ -z "$PREV" ]; then PREV="$HOME/Applications/TokenMeter.app"; fi
  if [ "$NOLAUNCH" != "1" ] && pgrep -x TokenMeter >/dev/null 2>&1; then
    WAS_RUNNING=1
    say "Quitting running TokenMeter"
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

  # (g) install
  say "Installing to $APP"
  if ! install_app "$MODE" "$SUDO" "$BUILT" "$APP"; then
    if [ "$WAS_RUNNING" = "1" ]; then
      local back="$APP"; [ -d "$back" ] || back="$PREV"
      if [ -n "$back" ] && [ -d "$back" ]; then say "Relaunching the previous TokenMeter"; open "$back" >/dev/null 2>&1 || true; fi
    fi
    fail "Could not install to $APP. The previous version (if any) was left in place."
  fi
  $SUDO xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true

  # (h) launch
  if [ "$NOLAUNCH" != "1" ]; then open "$APP"; fi
  say "Done. TokenMeter is installed at $APP$([ "$NOLAUNCH" = "1" ] && printf ' (not launched)')."
  if [ "$NOLAUNCH" != "1" ]; then say "Look for the gauge icon in the menu bar, click it, then choose Add account..."; fi
  say "To update later, re-run the same install command."
}

main "$@"
