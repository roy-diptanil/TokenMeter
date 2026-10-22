#!/bin/bash
#
# TokenMeter installer
#
#   curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh | bash
#
# What this script does (read it before piping to bash):
#   Path 1, PREBUILT (tried first, needs no Swift, git or Xcode):
#     1. Checks you are on macOS 14 or newer.
#     2. Downloads TokenMeter.commit, TokenMeter.zip and TokenMeter.zip.sha256 from the
#        latest GitHub release (built by GitHub Actions from main, universal arm64 + x86_64).
#     3. Asks GitHub which commit main is at. If the release is BEHIND main, it skips the
#        prebuilt and builds from source instead. (If GitHub cannot be asked, it uses the release.)
#     4. Verifies the SHA-256 checksum, unzips, and checks the app: its embedded commit equals
#        the release's commit marker, it is not a dirty build, its bundle id is
#        com.local.tokenmeter, and its code signature is intact. Any failure prints one line
#        and falls back to Path 2. An unverified bundle is never installed.
#   Path 2, SOURCE (used if the prebuilt is skipped, behind, or fails to verify):
#     1. Checks for the Swift toolchain. If missing, it starts `xcode-select --install`
#        and exits so you can re-run it afterwards.
#     2. Clones (or updates) the source into  $TOKENMETER_SRC  (default ~/.tokenmeter-src).
#        That folder is a throwaway build checkout owned by this script: an existing
#        git checkout there is fetched and hard-reset to origin/main.
#     3. Runs ./build.sh there (swift build, ad-hoc signed app bundle), logging to a temp file.
#        If the build fails because the Command Line Tools cannot build SwiftUI apps
#        (the SwiftUI macro plugin ships only with Xcode), it explains that and exits
#        BEFORE touching any installed app.
#   Then, for both paths:
#     - Picks where to install, and checks it is usable, BEFORE touching the running
#       app. In order: (1) $TOKENMETER_DEST (default /Applications) if writable;
#       (2) an existing, user-owned $TOKENMETER_DEST/TokenMeter.app is updated in
#       place with rsync (works even when the folder itself is not writable);
#       (3) sudo, only if it can really work (passwordless, or a terminal to prompt on);
#       (4) otherwise ~/Applications, and it tells you so.
#     - Quits a running TokenMeter and installs the new copy. If the install step
#       fails, the previous app is relaunched. Then it removes the quarantine flag
#       and opens the installed app.
#
# It never touches ~/Library/Application Support/TokenMeter or WebKit data, so
# your sign-ins survive updates. The only network access is downloading from GitHub
# releases, one request to the GitHub API for main's commit SHA, and (source path
# only) git clone/fetch of the repository. No telemetry.
#
# Environment overrides:
#   TOKENMETER_FROM_SOURCE=1  skip the prebuilt release and always build from source
#   TOKENMETER_RELEASE_BASE   prebuilt download base URL
#                             (default: https://github.com/roy-diptanil/TokenMeter/releases/download/latest)
#   TOKENMETER_MAIN_SHA       treat this as main's commit instead of asking the GitHub API (testing)
#   TOKENMETER_SRC   source checkout dir   (default: $HOME/.tokenmeter-src)
#   TOKENMETER_DEST  install parent dir    (default: /Applications)
#   TOKENMETER_REPO  git URL               (default: https://github.com/roy-diptanil/TokenMeter.git)
#   TOKENMETER_NO_LAUNCH=1  skip quitting and opening the app (for testing only)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [-h|--help]

Installs TokenMeter to /Applications: a verified prebuilt release if one is
available and current, otherwise built from source.

Environment:
  TOKENMETER_FROM_SOURCE=1  skip the prebuilt release, build from source
  TOKENMETER_RELEASE_BASE   prebuilt download base URL (default: the GitHub "latest" release)
  TOKENMETER_MAIN_SHA       main's commit, instead of asking the GitHub API (testing)
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

# plist_get APP KEY: print an Info.plist value (empty if missing).
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# fetch_sha URL [curl args...]: print a validated 40-hex SHA fetched from URL, else nothing.
fetch_sha() {
  local url="$1" out; shift
  out="$(curl -fsSL --max-time 20 "$@" "$url" </dev/null 2>/dev/null | tr -d '[:space:]')" || return 1
  printf '%s' "$out" | grep -Eq '^[0-9a-f]{40}$' || return 1
  printf '%s' "$out"
}

# prebuilt_fetch WORKDIR: try to obtain a verified prebuilt app.
#   returns 0 and sets PB_APP / PB_SHA on success;
#   returns 2 and sets PB_BEHIND=1 if the release is older than main;
#   returns 1 and sets PB_WHY otherwise. Never installs anything.
TMPD=""
PB_APP=""; PB_SHA=""; PB_WHY=""; PB_BEHIND=0
prebuilt_fetch() {
  local work="$1"
  local base="${TOKENMETER_RELEASE_BASE:-https://github.com/roy-diptanil/TokenMeter/releases/download/latest}"
  local rel main
  rel="$(fetch_sha "$base/TokenMeter.commit")" || { PB_WHY="no valid release commit marker"; return 1; }

  if [ -n "${TOKENMETER_MAIN_SHA:-}" ]; then
    main="$(printf '%s' "$TOKENMETER_MAIN_SHA" | tr -d '[:space:]')"
    printf '%s' "$main" | grep -Eq '^[0-9a-f]{40}$' || main=""
  else
    main="$(fetch_sha "https://api.github.com/repos/roy-diptanil/TokenMeter/commits/main" \
      -H "Accept: application/vnd.github.sha" -H "X-GitHub-Api-Version: 2022-11-28")" || main=""
  fi
  if [ -z "$main" ]; then
    say "Note: could not look up main's latest commit; using the release as is."
  elif [ "$main" != "$rel" ]; then
    PB_BEHIND=1
    return 2
  fi

  curl -fsSL --max-time 600 -o "$work/TokenMeter.zip" "$base/TokenMeter.zip" </dev/null 2>/dev/null || { PB_WHY="could not download TokenMeter.zip"; return 1; }
  curl -fsSL --max-time 60 -o "$work/TokenMeter.zip.sha256" "$base/TokenMeter.zip.sha256" </dev/null 2>/dev/null || { PB_WHY="could not download the checksum"; return 1; }
  ( cd "$work" && shasum -a 256 -c TokenMeter.zip.sha256 ) >/dev/null 2>&1 || { PB_WHY="checksum mismatch"; return 1; }
  mkdir -p "$work/x"
  ditto -x -k "$work/TokenMeter.zip" "$work/x" >/dev/null 2>&1 || { PB_WHY="could not unzip"; return 1; }
  local app="$work/x/TokenMeter.app"
  [ -d "$app" ] || { PB_WHY="zip does not contain TokenMeter.app"; return 1; }
  [ "$(plist_get "$app" TokenMeterCommit)" = "$rel" ] || { PB_WHY="app commit does not match the release marker"; return 1; }
  [ "$(plist_get "$app" TokenMeterDirty)" = "false" ] || { PB_WHY="app is marked as a dirty build"; return 1; }
  [ "$(plist_get "$app" CFBundleIdentifier)" = "com.local.tokenmeter" ] || { PB_WHY="unexpected bundle identifier"; return 1; }
  codesign --verify --deep "$app" >/dev/null 2>&1 || { PB_WHY="code signature check failed"; return 1; }
  xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
  PB_APP="$app"; PB_SHA="$rel"
  return 0
}

# build_failed_for_toolchain LOG: success if LOG shows the missing SwiftUI macro plugin (CLT-only machine).
build_failed_for_toolchain() {
  grep -Eq 'SwiftUIMacros|plugin for module|external macro implementation' "$1" 2>/dev/null
}

# report_build_failure LOG: explain a failed source build (stderr). Does not exit.
report_build_failure() {
  local log="$1"
  if build_failed_for_toolchain "$log"; then
    {
      printf '==> ERROR: Your Command Line Tools cannot build SwiftUI apps with this macOS SDK (the SwiftUI macro plugin ships only with Xcode).\n'
      printf '    Install Xcode from the App Store, open it once, run: sudo xcode-select -s /Applications/Xcode.app\n'
      printf '    then re-run this installer. (If a prebuilt release is available the installer uses that automatically.)\n'
      printf '    Build log: %s\n' "$log"
    } >&2
  else
    printf '==> ERROR: The build failed. Last lines of the log:\n' >&2
    tail -n 15 "$log" >&2 || true
    printf '    Full build log: %s\n' "$log" >&2
  fi
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

  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tokenmeter-install.XXXXXX")"
  trap 'rc=$?; rm -rf "$TMPD"; if [ "$rc" -ne 0 ]; then printf "==> Install did not finish (exit %s). Fix the issue above and re-run; it is safe to repeat.\n" "$rc" >&2; fi' EXIT

  # (a) platform
  [ "$(uname -s)" = "Darwin" ] || fail "TokenMeter is a macOS app."
  local ver major arch
  ver="$(sw_vers -productVersion)"
  major="${ver%%.*}"
  arch="$(uname -m)"
  case "$arch" in arm64|x86_64) ;; *) fail "Unsupported architecture: $arch" ;; esac
  [ "$major" -ge 14 ] 2>/dev/null || fail "macOS 14 or newer is required (found $ver)."
  say "macOS $ver ($arch)"

  # (b) prebuilt release first: needs no Swift, git or Xcode
  local BUILT=""
  if [ "${TOKENMETER_FROM_SOURCE:-0}" = "1" ]; then
    say "TOKENMETER_FROM_SOURCE=1: building from source."
  else
    local prc=0
    prebuilt_fetch "$TMPD" || prc=$?
    if [ "$prc" -eq 0 ]; then
      BUILT="$PB_APP"
      say "Using the prebuilt release (${PB_SHA:0:7})"
    elif [ "$prc" -eq 2 ]; then
      say "The prebuilt release is behind main; building from source instead."
    else
      say "Prebuilt download failed ($PB_WHY); building from source instead."
    fi
  fi

  if [ -z "$BUILT" ]; then
    # (c) Swift toolchain
    if ! { xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; } </dev/null; then
      say "Swift toolchain not found. Starting Xcode Command Line Tools install..."
      xcode-select --install </dev/null >/dev/null 2>&1 || true
      fail "Finish the Command Line Tools install dialog, then re-run this installer."
    fi
    command -v git >/dev/null 2>&1 || fail "git not found."

    # (d) source checkout
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

    # (d2) build, keeping a log (visible progress is preserved via tee)
    say "Building (this takes a minute or two)..."
    local LOG
    LOG="$(mktemp "${TMPDIR:-/tmp}/tokenmeter-build.XXXXXX")"
    if ! { ( cd "$SRC" && ./build.sh </dev/null ) 2>&1 | tee "$LOG"; }; then
      report_build_failure "$LOG"
      exit 1
    fi
    rm -f "$LOG"
    BUILT="$SRC/build/TokenMeter.app"
    [ -d "$BUILT" ] || fail "Build finished but $BUILT was not produced."
  fi

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

# Tests can `source` this file for its functions without running the installer.
if [ "${TOKENMETER_SOURCE_ONLY:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

main "$@"
