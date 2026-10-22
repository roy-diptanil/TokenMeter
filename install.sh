#!/bin/bash
#
# TokenMeter installer
#
#   curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh | bash
#
# What this script does (read it before piping to bash):
#   Path 1, PREBUILT STABLE RELEASE (tried first, needs no Swift, git or Xcode):
#     1. Checks you are on macOS 14 or newer.
#     2. Downloads TokenMeter.commit, TokenMeter.version, TokenMeter.zip and TokenMeter.zip.sha256
#        from the newest versioned GitHub release (GitHub redirects ".../releases/latest/download"
#        to the newest non-prerelease). Releases are built by GitHub Actions, universal arm64 + x86_64.
#     3. Verifies the SHA-256 checksum, unzips, and checks the app: its embedded commit equals
#        the release's commit marker, its version equals the release's version marker (MAJOR.MINOR.PATCH),
#        it is not a dirty build, its bundle id is com.local.tokenmeter, and its code signature
#        is intact. Any failure prints one line and falls back to Path 2. An unverified bundle
#        is never installed. (These checks catch corruption and mismatches, not a compromised publisher.)
#   Path 2, SOURCE (used if the prebuilt is skipped or fails to verify; builds the tip of main):
#     1. Checks for the Swift toolchain. If missing, it starts `xcode-select --install`
#        and exits so you can re-run it afterwards.
#     2. Clones (or updates) the source into  $TOKENMETER_SRC  (default ~/.tokenmeter-src).
#        That folder is a throwaway build checkout owned by this script: an existing
#        git checkout there is fetched and hard-reset to origin/main.
#     3. Runs ./build.sh there (swift build, ad-hoc signed app bundle), logging to a temp file.
#        SwiftUI on recent macOS SDKs needs the FULL Xcode app. If the Command Line Tools are
#        the selected toolchain and an Xcode app is installed, the build uses that Xcode through
#        DEVELOPER_DIR for that one command only (no sudo, your xcode-select choice is unchanged).
#        If the build fails because the SwiftUI macro plugin is missing, it retries once with
#        another installed Xcode if there is one; otherwise it explains what to install and exits
#        BEFORE touching any installed app.
#   Then, for both paths:
#     - Picks where to install, and checks it is usable, BEFORE touching the running
#       app. Without TOKENMETER_DEST (no admin rights, no sudo, ever):
#       (1) if /Applications/TokenMeter.app already exists and ~/Applications/TokenMeter.app
#           does not, that copy is updated where it is (copied if the folder is writable,
#           otherwise updated in place with rsync when the bundle is user-owned; if neither
#           works it stops and tells you to run uninstall.sh and re-run);
#       (2) otherwise it installs to ~/Applications (created if needed). If copies exist in
#           both places it updates the ~/Applications one and warns about the other.
#       With TOKENMETER_DEST set (e.g. /Applications for a system-wide install) it uses that
#       folder if writable, else updates an existing user-owned bundle there in place, else
#       uses sudo, only if it can really work (passwordless, or a terminal to prompt on).
#     - Quits a running TokenMeter and installs the new copy. If the install step
#       fails, the previous app is relaunched. Then it removes the quarantine flag
#       and opens the installed app.
#
# It never touches ~/Library/Application Support/TokenMeter or WebKit data, so
# your sign-ins survive updates. The only network access is downloading from GitHub
# releases and (source path only) git clone/fetch of the repository. No telemetry.
#
# Environment overrides:
#   TOKENMETER_VERSION=v1.0.0  install that release instead of the newest (pin / roll back)
#   TOKENMETER_FROM_SOURCE=1   skip the prebuilt release and build main from source
#   TOKENMETER_RELEASE_BASE    prebuilt download base URL (default: the newest GitHub release's assets)
#   TOKENMETER_RELEASES_URL    releases root used with TOKENMETER_VERSION (testing; default
#                              https://github.com/roy-diptanil/TokenMeter/releases)
#   TOKENMETER_SRC   source checkout dir   (default: $HOME/.tokenmeter-src)
#   TOKENMETER_DEST  install parent dir    (default: ~/Applications; see above)
#   TOKENMETER_SYSTEM_APPS  where an existing system-wide copy is looked for (testing; default /Applications)
#   TOKENMETER_REPO  git URL               (default: https://github.com/roy-diptanil/TokenMeter.git)
#   TOKENMETER_NO_LAUNCH=1  skip quitting and opening the app (for testing only)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [-h|--help]

Installs the newest TokenMeter release to ~/Applications (no admin rights needed): a verified prebuilt
app if available, otherwise built from source (main).

Environment:
  TOKENMETER_VERSION=v1.0.0 install that release instead of the newest
  TOKENMETER_FROM_SOURCE=1  skip the prebuilt release, build main from source
  TOKENMETER_RELEASE_BASE   prebuilt download base URL (default: newest GitHub release)
  TOKENMETER_SRC   source checkout dir (default: ~/.tokenmeter-src)
  TOKENMETER_DEST  install parent dir  (default: ~/Applications; an existing
                   /Applications copy is updated in place; use /Applications for system-wide)
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

# fetch_text URL: print the trimmed body of URL (stdout empty and status 1 on failure).
fetch_text() {
  local out
  out="$(curl -fsSL --max-time 20 "$1" </dev/null 2>/dev/null | tr -d '[:space:]')" || return 1
  printf '%s' "$out"
}

is_semver() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
is_sha()    { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

# release_base: where the release assets live. TOKENMETER_RELEASE_BASE wins; TOKENMETER_VERSION=vX.Y.Z
# pins a release; otherwise GitHub's "latest" redirect (newest non-prerelease).
release_base() {
  local root="${TOKENMETER_RELEASES_URL:-https://github.com/roy-diptanil/TokenMeter/releases}"
  if [ -n "${TOKENMETER_RELEASE_BASE:-}" ]; then printf '%s' "$TOKENMETER_RELEASE_BASE"
  elif [ -n "${TOKENMETER_VERSION:-}" ]; then printf '%s/download/%s' "$root" "$TOKENMETER_VERSION"
  else printf '%s/latest/download' "$root"
  fi
}

# prebuilt_fetch WORKDIR: try to obtain a verified prebuilt app.
#   returns 0 and sets PB_APP / PB_SHA / PB_VER on success; returns 1 and sets PB_WHY otherwise.
#   Never installs anything.
TMPD=""
PB_APP=""; PB_SHA=""; PB_VER=""; PB_WHY=""
prebuilt_fetch() {
  local work="$1" base rel ver
  base="$(release_base)"
  rel="$(fetch_text "$base/TokenMeter.commit")" || rel=""
  is_sha "$rel" || { PB_WHY="no valid release commit marker"; return 1; }
  ver="$(fetch_text "$base/TokenMeter.version")" || ver=""
  is_semver "$ver" || { PB_WHY="no valid release version marker"; return 1; }
  if [ -n "${TOKENMETER_VERSION:-}" ] && [ "v$ver" != "$TOKENMETER_VERSION" ]; then
    PB_WHY="release is $ver, not the requested $TOKENMETER_VERSION"; return 1
  fi

  curl -fsSL --max-time 600 -o "$work/TokenMeter.zip" "$base/TokenMeter.zip" </dev/null 2>/dev/null || { PB_WHY="could not download TokenMeter.zip"; return 1; }
  curl -fsSL --max-time 60 -o "$work/TokenMeter.zip.sha256" "$base/TokenMeter.zip.sha256" </dev/null 2>/dev/null || { PB_WHY="could not download the checksum"; return 1; }
  ( cd "$work" && shasum -a 256 -c TokenMeter.zip.sha256 ) >/dev/null 2>&1 || { PB_WHY="checksum mismatch"; return 1; }
  mkdir -p "$work/x"
  ditto -x -k "$work/TokenMeter.zip" "$work/x" >/dev/null 2>&1 || { PB_WHY="could not unzip"; return 1; }
  local app="$work/x/TokenMeter.app"
  [ -d "$app" ] || { PB_WHY="zip does not contain TokenMeter.app"; return 1; }
  [ "$(plist_get "$app" TokenMeterCommit)" = "$rel" ] || { PB_WHY="app commit does not match the release marker"; return 1; }
  [ "$(plist_get "$app" CFBundleShortVersionString)" = "$ver" ] || { PB_WHY="app version does not match the release version marker"; return 1; }
  [ "$(plist_get "$app" TokenMeterDirty)" = "false" ] || { PB_WHY="app is marked as a dirty build"; return 1; }
  [ "$(plist_get "$app" CFBundleIdentifier)" = "com.local.tokenmeter" ] || { PB_WHY="unexpected bundle identifier"; return 1; }
  codesign --verify --deep "$app" >/dev/null 2>&1 || { PB_WHY="code signature check failed"; return 1; }
  xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
  PB_APP="$app"; PB_SHA="$rel"; PB_VER="$ver"
  return 0
}

# ver_gt A B: success if dotted version A is numerically greater than B.
ver_gt() {
  local i a b
  local -a pa pb
  IFS=. read -r -a pa <<<"$1"
  IFS=. read -r -a pb <<<"$2"
  for i in 0 1 2 3; do
    a="${pa[$i]:-0}"; b="${pb[$i]:-0}"
    a="${a//[!0-9]/}"; b="${b//[!0-9]/}"
    [ "${a:-0}" -gt "${b:-0}" ] && return 0
    [ "${a:-0}" -lt "${b:-0}" ] && return 1
  done
  return 1
}

# best_xcode DIR...: print the Contents/Developer path of the highest-version Xcode*.app in the given
# directories (nothing if none). Highest wins, so an Xcode 16+ is always preferred over an older one
# (TokenMeter needs Swift 6, i.e. Xcode 16+); an older Xcode is still returned when it is the only one,
# and the build then reports the "toolchain too old" message.
best_xcode() {
  local d app v best="" bestv="-1"
  for d in "$@"; do
    for app in "$d"/Xcode*.app; do
      [ -d "$app/Contents/Developer" ] || continue
      v="$(plist_get "$app" CFBundleShortVersionString)"; [ -n "$v" ] || v="0"
      if [ -z "$best" ] || ver_gt "$v" "$bestv"; then best="$app/Contents/Developer"; bestv="$v"; fi
    done
  done
  [ -z "$best" ] || printf '%s' "$best"
}

# xcode_for_build SELECTED_PATH DIR...: the Xcode to use for the build, only when the Command Line
# Tools are selected (SELECTED_PATH is `xcode-select -p`) and the user did not set DEVELOPER_DIR.
xcode_for_build() {
  local sel="$1"; shift
  [ -z "${DEVELOPER_DIR:-}" ] || return 0
  case "$sel" in *CommandLineTools*) best_xcode "$@" ;; esac
}

# xcode_for_retry LOG TRIED_DEVELOPER_DIR DIR...: after a failed build, an Xcode worth retrying with:
# only when the log shows the missing SwiftUI macro plugin or a Swift toolchain that is too old, the user
# did not set DEVELOPER_DIR, and the best installed Xcode is not the toolchain that was just tried.
xcode_for_retry() {
  local log="$1" tried="$2"; shift 2
  [ -z "${DEVELOPER_DIR:-}" ] || return 0
  build_failed_for_toolchain "$log" || build_failed_for_swift_version "$log" || return 0
  local best; best="$(best_xcode "$@")"
  if [ -n "$best" ] && [ "$best" != "$tried" ]; then printf '%s' "$best"; fi
}

# build_failed_for_toolchain LOG: success if LOG shows the missing SwiftUI macro plugin (no full Xcode).
build_failed_for_toolchain() {
  grep -Eq 'SwiftUIMacros|plugin for module|external macro implementation' "$1" 2>/dev/null
}

# build_failed_for_swift_version LOG: success if LOG shows the Swift toolchain is older than the package needs.
build_failed_for_swift_version() {
  grep -Eiq 'using Swift tools version [0-9.]+ but the installed version is [0-9.]+|requires a minimum Swift tools' "$1" 2>/dev/null
}

# build_failed_for_license LOG: success if LOG shows the Xcode license has not been accepted.
build_failed_for_license() {
  grep -Eiq 'Xcode license|xcodebuild -license' "$1" 2>/dev/null
}

# report_build_failure LOG: explain a failed source build (stderr). Does not exit.
report_build_failure() {
  local log="$1"
  if build_failed_for_toolchain "$log"; then
    {
      printf '==> ERROR: Your Command Line Tools cannot build SwiftUI apps with this macOS SDK (the SwiftUI macro plugin ships only with Xcode).\n'
      printf '    Install Xcode from the App Store, open it once to accept the license, then re-run this installer.\n'
      printf '    You do not need to change xcode-select: the installer finds Xcode itself.\n'
      printf '    (If a prebuilt release is available the installer uses that automatically.)\n'
      printf '    If you ask for help, include the output of: xcode-select -p   and   xcodebuild -version\n'
      printf '    Build log: %s\n' "$log"
    } >&2
  elif build_failed_for_swift_version "$log"; then
    local sv; sv="$(swift --version 2>&1 </dev/null | head -n 1 || true)"
    {
      printf '==> ERROR: Your Swift toolchain is too old: TokenMeter needs Swift 6.0, which comes with Xcode 16 or newer.\n'
      printf "    Install Xcode 16 or newer (see Apple's system requirements for your macOS version; Xcode 16 needs macOS 14.5 or later), open it once to accept the license, then re-run this installer.\n"
      printf '    Your toolchain: %s.\n' "${sv:-unknown}"
      printf '    If you ask for help, include the output of: xcode-select -p   and   xcodebuild -version\n'
      printf '    Build log: %s\n' "$log"
    } >&2
  elif build_failed_for_license "$log"; then
    {
      printf '==> ERROR: The Xcode license has not been accepted.\n'
      printf '    Open Xcode once, or run: sudo xcodebuild -license accept\n'
      printf '    then re-run this installer.\n'
      printf '    Build log: %s\n' "$log"
    } >&2
  else
    printf '==> ERROR: The build failed. Last lines of the log:\n' >&2
    tail -n 15 "$log" >&2 || true
    printf '    If you ask for help, include the output of: xcode-select -p   and   xcodebuild -version\n' >&2
    printf '    Full build log: %s\n' "$log" >&2
  fi
}

# run_build SRC LOG [DEVELOPER_DIR]: run ./build.sh in SRC, showing and logging its output.
# DEVELOPER_DIR applies to this one command only.
run_build() {
  local src="$1" log="$2" dev="${3:-}"
  if [ -n "$dev" ]; then
    { ( cd "$src" && DEVELOPER_DIR="$dev" ./build.sh </dev/null ) 2>&1 | tee "$log"; }
  else
    { ( cd "$src" && ./build.sh </dev/null ) 2>&1 | tee "$log"; }
  fi
}

# print_toolchain [DEVELOPER_DIR]: show which Swift/Xcode the build will use.
print_toolchain() {
  local dev="${1:-}" s x
  if [ -n "$dev" ]; then
    s="$(DEVELOPER_DIR="$dev" swift --version 2>&1 </dev/null | head -n 1 || true)"
    x="$(DEVELOPER_DIR="$dev" xcodebuild -version 2>/dev/null </dev/null | head -n 1 || true)"
  else
    s="$(swift --version 2>&1 </dev/null | head -n 1 || true)"
    x="$(xcodebuild -version 2>/dev/null </dev/null | head -n 1 || true)"
  fi
  say "Toolchain: ${s:-swift unknown}${x:+ / $x}"
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") ;;
    *) usage >&2; exit 2 ;;
  esac

  local SRC="${TOKENMETER_SRC:-$HOME/.tokenmeter-src}"
  local REPO="${TOKENMETER_REPO:-https://github.com/roy-diptanil/TokenMeter.git}"

  if [ -n "${TOKENMETER_VERSION:-}" ]; then
    printf '%s' "$TOKENMETER_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || fail "TOKENMETER_VERSION must look like v1.0.0 (got '$TOKENMETER_VERSION')."
  fi

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

  # (b) prebuilt stable release first: needs no Swift, git or Xcode
  local BUILT=""
  if [ "${TOKENMETER_FROM_SOURCE:-0}" = "1" ]; then
    say "TOKENMETER_FROM_SOURCE=1: building main from source."
  elif prebuilt_fetch "$TMPD"; then
    BUILT="$PB_APP"
    say "Using TokenMeter $PB_VER (prebuilt release)"
  else
    say "Prebuilt download failed ($PB_WHY); building from source instead."
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

    # (d2) build with the right toolchain, keeping a log (visible progress is preserved via tee)
    local SEL XDEV="" LOG
    SEL="$(xcode-select -p 2>/dev/null </dev/null || true)"
    XDEV="$(xcode_for_build "$SEL" /Applications "$HOME/Applications")"
    if [ -n "$XDEV" ]; then
      say "Using Xcode at ${XDEV%/Contents/Developer} for this build (the Command Line Tools are selected; your selection is not changed)."
    fi
    print_toolchain "$XDEV"
    say "Building (this takes a minute or two)..."
    LOG="$(mktemp "${TMPDIR:-/tmp}/tokenmeter-build.XXXXXX")"
    if ! run_build "$SRC" "$LOG" "$XDEV"; then
      local RX
      RX="$(xcode_for_retry "$LOG" "${XDEV:-$SEL}" /Applications "$HOME/Applications")"
      if [ -n "$RX" ]; then
        say "The build needs the full Xcode toolchain; retrying once with Xcode at ${RX%/Contents/Developer}."
        print_toolchain "$RX"
        LOG="$(mktemp "${TMPDIR:-/tmp}/tokenmeter-build.XXXXXX")"
        if ! run_build "$SRC" "$LOG" "$RX"; then report_build_failure "$LOG"; exit 1; fi
      else
        report_build_failure "$LOG"
        exit 1
      fi
    fi
    rm -f "$LOG"
    BUILT="$SRC/build/TokenMeter.app"
    [ -d "$BUILT" ] || fail "Build finished but $BUILT was not produced."
  fi

  # (e) decide where to install and verify it BEFORE quitting anything
  local MODE="" SUDO="" NOLAUNCH="${TOKENMETER_NO_LAUNCH:-0}"
  local SYSAPPS="${TOKENMETER_SYSTEM_APPS:-/Applications}" UAPPS="$HOME/Applications"
  local DEST APP EXPLICIT=0 EXISTING_SYS=0
  if [ -n "${TOKENMETER_DEST:-}" ]; then
    EXPLICIT=1; DEST="$TOKENMETER_DEST"
  elif [ -d "$SYSAPPS/TokenMeter.app" ] && [ ! -d "$UAPPS/TokenMeter.app" ]; then
    EXISTING_SYS=1; DEST="$SYSAPPS"
    say "Updating the existing copy in /Applications. New installs go to ~/Applications; to move it, run uninstall.sh and install again."
  else
    DEST="$UAPPS"
    if [ -d "$SYSAPPS/TokenMeter.app" ]; then
      say "Warning: a second copy exists at $SYSAPPS/TokenMeter.app. Updating $UAPPS/TokenMeter.app only. To remove the other one: run uninstall.sh (it removes both) and install again, or delete it yourself."
    fi
  fi
  APP="$DEST/TokenMeter.app"
  local parent
  parent="$(dirname "$DEST")"
  if { [ -d "$DEST" ] && [ -w "$DEST" ]; } || { [ ! -e "$DEST" ] && [ -w "$parent" ]; }; then
    MODE="copy"
  elif [ -d "$APP" ] && [ -w "$APP" ] && [ -w "$APP/Contents" ] && command -v rsync >/dev/null 2>&1; then
    MODE="inplace"
  elif [ "$EXPLICIT" = "1" ]; then
    # sudo only for an explicit TOKENMETER_DEST that is not writable
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      MODE="sudo"
    elif command -v sudo >/dev/null 2>&1 && { [ -t 0 ] || { [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; }; }; then
      say "$DEST is not writable; asking for your password (sudo) for the install step only."
      if sudo -v; then MODE="sudo"; fi
    fi
  fi
  if [ "$MODE" = "sudo" ]; then SUDO="sudo"; fi
  if [ -z "$MODE" ]; then
    if [ "$EXISTING_SYS" = "1" ]; then
      fail "Cannot update $APP (not writable and not owned by you). Run uninstall.sh, then re-run this installer to install to ~/Applications. Nothing was changed."
    fi
    fail "Cannot write to $DEST. Nothing was changed."
  fi
  if [ "$MODE" = "copy" ]; then mkdir -p "$DEST" 2>/dev/null || fail "Cannot create $DEST. Nothing was changed."; fi
  say "Install mode: $MODE ($APP)"

  # (f) quit running app (only now that the destination is known to work)
  local WAS_RUNNING=0 PREV=""
  if [ -d "$APP" ]; then PREV="$APP"; fi
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
