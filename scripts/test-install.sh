#!/bin/bash
#
# Tests for install.sh. Uses only temp dirs, file:// release bases and a fake app bundle.
# Never touches /Applications, ~/Applications, ~/.tokenmeter-src or ~/Library, never launches
# the app, and makes no network calls.
#
#   scripts/test-install.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/tokenmeter-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0; FAILS=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$*"; }
check() { # check DESC CMD...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# make_release DIR PLIST_COMMIT MARKER_COMMIT PLIST_VERSION MARKER_VERSION:
# fake bundle + zip + sha256 + commit marker + version marker in DIR (the four release assets).
make_release() {
  local dir="$1" plist_commit="$2" marker="$3" plist_ver="$4" marker_ver="$5"
  local app="$dir/stage/TokenMeter.app"
  rm -rf "$dir"; mkdir -p "$app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/TokenMeter"
  chmod +x "$app/Contents/MacOS/TokenMeter"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.tokenmeter</string>
  <key>CFBundleExecutable</key><string>TokenMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$plist_ver</string>
  <key>TokenMeterCommit</key><string>$plist_commit</string>
  <key>TokenMeterDirty</key><string>false</string>
</dict></plist>
PLIST
  codesign --force --deep -s - "$app" >/dev/null 2>&1
  ( cd "$dir/stage" && ditto -c -k --keepParent TokenMeter.app ../TokenMeter.zip )
  ( cd "$dir" && shasum -a 256 TokenMeter.zip > TokenMeter.zip.sha256 )
  printf '%s\n' "$marker" > "$dir/TokenMeter.commit"
  printf '%s\n' "$marker_ver" > "$dir/TokenMeter.version"
}

# run_install NAME ENV...: run install.sh in a clean sandbox; sets OUT (combined output), RC, DEST, SRC.
run_install() {
  local name="$1"; shift
  local sb="$T/run-$name"
  rm -rf "$sb"; mkdir -p "$sb/home" "$sb/dest"
  DEST="$sb/dest"; SRC="$sb/src"
  RC=0
  OUT="$(env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb" \
      TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$DEST" TOKENMETER_SRC="$SRC" \
      TOKENMETER_REPO="$sb/no-such-repo" \
      "$@" bash "$INSTALL" </dev/null 2>&1)" || RC=$?
}

has() { printf '%s' "$OUT" | grep -Fq -- "$1"; }
hasnt() { ! printf '%s' "$OUT" | grep -Fq -- "$1"; }
# fn NAME ARGS...: call a function from install.sh without running the installer.
fn() { env -u DEVELOPER_DIR TOKENMETER_SOURCE_ONLY=1 bash -c '. "$0"; "$@"' "$INSTALL" "$@"; }
fn_dev() { local dd="$1"; shift; env DEVELOPER_DIR="$dd" TOKENMETER_SOURCE_ONLY=1 bash -c '. "$0"; "$@"' "$INSTALL" "$@"; }

REL="$T/release"

# (1) stable happy path: default URL layout <root>/latest/download/..., newest release installed
RR="$T/rr"; rm -rf "$RR"; mkdir -p "$RR/latest"
make_release "$RR/latest/download" "$SHA_A" "$SHA_A" "2.0.0" "2.0.0"
run_install happy TOKENMETER_RELEASES_URL="file://$RR"
check "(1) stable: exit 0" test "$RC" -eq 0
check "(1) stable: says which version it used" has "Using TokenMeter 2.0.0 (prebuilt release)"
check "(1) stable: app installed" test -x "$DEST/TokenMeter.app/Contents/MacOS/TokenMeter"
check "(1) stable: no source checkout created" test ! -e "$SRC"
check "(1) stable: no main-SHA comparison any more" hasnt "behind main"
check "(1) stable: temp work dir removed" sh -c "! ls '$T'/run-happy | grep -q tokenmeter-install"

# (2) pinned version via TOKENMETER_VERSION: <root>/download/v1.0.0/...
mkdir -p "$RR/download"
make_release "$RR/download/v1.0.0" "$SHA_B" "$SHA_B" "1.0.0" "1.0.0"
run_install pinned TOKENMETER_RELEASES_URL="file://$RR" TOKENMETER_VERSION=v1.0.0
check "(2) pinned: installs the pinned release, not the newest" has "Using TokenMeter 1.0.0 (prebuilt release)"
check "(2) pinned: exit 0 and app installed" test "$RC" -eq 0 -a -x "$DEST/TokenMeter.app/Contents/MacOS/TokenMeter"
make_release "$RR/download/v1.0.1" "$SHA_B" "$SHA_B" "1.0.2" "1.0.2"
run_install pinned2 TOKENMETER_RELEASES_URL="file://$RR" TOKENMETER_VERSION=v1.0.1
check "(2) pinned: release whose version differs from the requested tag is refused" has "not the requested v1.0.1"
run_install pinned3 TOKENMETER_RELEASES_URL="file://$RR" TOKENMETER_VERSION=main
check "(2) pinned: malformed TOKENMETER_VERSION is rejected" sh -c "[ $RC -ne 0 ] && printf '%s' \"\$1\" | grep -q 'must look like v1.0.0'" _ "$OUT"
check "(2) release_base: default is the GitHub latest/download redirect" test "$(fn release_base)" = "https://github.com/roy-diptanil/TokenMeter/releases/latest/download"
check "(2) release_base: pinned tag" test "$(TOKENMETER_VERSION=v1.0.0 fn release_base)" = "https://github.com/roy-diptanil/TokenMeter/releases/download/v1.0.0"
check "(2) release_base: explicit base wins" test "$(TOKENMETER_VERSION=v1.0.0 TOKENMETER_RELEASE_BASE=file:///x fn release_base)" = "file:///x"

# (3) version marker mismatch (app says 1.0.0, marker says 1.0.1) -> fallback, nothing installed
make_release "$REL" "$SHA_A" "$SHA_A" "1.0.0" "1.0.1"
run_install vermismatch TOKENMETER_RELEASE_BASE="file://$REL"
check "(3) version mismatch: fallback message" has "Prebuilt download failed (app version does not match the release version marker); building from source instead."
check "(3) version mismatch: bundle not installed" test ! -e "$DEST/TokenMeter.app"

# (4) malformed version marker
make_release "$REL" "$SHA_A" "$SHA_A" "1.0" "1.0"
run_install badver TOKENMETER_RELEASE_BASE="file://$REL"
check "(4) malformed version: fallback message" has "Prebuilt download failed (no valid release version marker); building from source instead."
check "(4) malformed version: bundle not installed" test ! -e "$DEST/TokenMeter.app"

# (5) checksum mismatch -> fallback, source also fails, destination (and an existing app) untouched
make_release "$REL" "$SHA_A" "$SHA_A" "1.0.0" "1.0.0"
printf '%s  TokenMeter.zip\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$REL/TokenMeter.zip.sha256"
sb="$T/run-badsum"; rm -rf "$sb"; mkdir -p "$sb/home" "$sb/dest/TokenMeter.app"; printf 'old' > "$sb/dest/TokenMeter.app/sentinel"; RC=0
OUT="$(env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb" TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$sb/dest" \
  TOKENMETER_SRC="$sb/src" TOKENMETER_REPO="$sb/nope" TOKENMETER_RELEASE_BASE="file://$REL" bash "$INSTALL" </dev/null 2>&1)" || RC=$?
check "(5) checksum: fallback message" has "Prebuilt download failed (checksum mismatch); building from source instead."
check "(5) checksum: exits non-zero (source also fails)" test "$RC" -ne 0
check "(5) checksum: existing app left in place" test "$(cat "$sb/dest/TokenMeter.app/sentinel")" = "old"

# (5b) commit marker != plist commit
make_release "$REL" "$SHA_B" "$SHA_A" "1.0.0" "1.0.0"
run_install commitmismatch TOKENMETER_RELEASE_BASE="file://$REL"
check "(5b) commit mismatch: fallback message" has "Prebuilt download failed (app commit does not match the release marker); building from source instead."
check "(5b) commit mismatch: bundle not installed" test ! -e "$DEST/TokenMeter.app"

# (6) FROM_SOURCE skips prebuilt entirely
make_release "$REL" "$SHA_A" "$SHA_A" "1.0.0" "1.0.0"
run_install fromsrc TOKENMETER_FROM_SOURCE=1 TOKENMETER_RELEASE_BASE="file://$REL"
check "(6) from source: prebuilt skipped (source fails here, no repo)" test "$RC" -ne 0
check "(6) from source: prebuilt never attempted" hasnt "Using TokenMeter"
check "(6) from source: announces source build of main" has "TOKENMETER_FROM_SOURCE=1: building main from source."
check "(6) from source: app not installed" test ! -e "$DEST/TokenMeter.app"

# (7) Xcode auto-selection (pure functions with a fake Xcode tree)
XA="$T/xc/Applications"; XH="$T/xc/home/Applications"
mkdir -p "$XA/Xcode.app/Contents/Developer" "$XA/Xcode-26.0.app/Contents/Developer" "$XA/Xcode-9.app/Contents/Developer" "$XA/Xcode-broken.app/Contents" "$XH/Xcode-beta.app/Contents/Developer"
setver() { printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>' "$2" > "$1/Contents/Info.plist"; }
setver "$XA/Xcode.app" 16.4; setver "$XA/Xcode-26.0.app" 26.0; setver "$XA/Xcode-9.app" 9.4; setver "$XA/Xcode-broken.app" 99.0; setver "$XH/Xcode-beta.app" 26.1
CLT="/Library/Developer/CommandLineTools"
check "(7) ver_gt: 26.0 > 16.4, 16.4 > 9.4, 10.0 > 9.9, not equal" sh -c "TOKENMETER_SOURCE_ONLY=1 . '$INSTALL'; ver_gt 26.0 16.4 && ver_gt 16.4 9.4 && ver_gt 10.0 9.9 && ! ver_gt 1.2 1.2 && ! ver_gt 9.4 16.4"
check "(7) xcode: CLT selected -> picks the highest version" test "$(fn xcode_for_build "$CLT" "$XA")" = "$XA/Xcode-26.0.app/Contents/Developer"
check "(7) xcode: searches all given directories" test "$(fn xcode_for_build "$CLT" "$XA" "$XH")" = "$XH/Xcode-beta.app/Contents/Developer"
check "(7) xcode: ignores bundles without Contents/Developer" test "$(fn xcode_for_build "$CLT" "$XA")" != "$XA/Xcode-broken.app/Contents/Developer"
check "(7) xcode: Xcode already selected -> nothing to do" test -z "$(fn xcode_for_build "/Applications/Xcode.app/Contents/Developer" "$XA")"
check "(7) xcode: respects an existing DEVELOPER_DIR" test -z "$(fn_dev /some/where xcode_for_build "$CLT" "$XA")"
check "(7) xcode: no Xcode installed -> nothing" test -z "$(fn xcode_for_build "$CLT" "$T/nothing-here")"

# (8) retry decision on the macro-plugin log
printf 'error: external macro implementation type X could not be found\nplugin for module SwiftUIMacros not found\n' > "$T/macro.log"
printf 'error: something else broke\n' > "$T/other.log"
printf 'Agreeing to the Xcode license is required. Please run: sudo xcodebuild -license\n' > "$T/license.log"
BEST="$XA/Xcode-26.0.app/Contents/Developer"
check "(8) retry: macro failure on CLT -> retry with Xcode" test "$(fn xcode_for_retry "$T/macro.log" "$CLT" "$XA")" = "$BEST"
check "(8) retry: macro failure on an older selected Xcode -> retry with the best one" test "$(fn xcode_for_retry "$T/macro.log" "$XA/Xcode-9.app/Contents/Developer" "$XA")" = "$BEST"
check "(8) retry: already tried the best Xcode -> no retry" test -z "$(fn xcode_for_retry "$T/macro.log" "$BEST" "$XA")"
check "(8) retry: unrelated failure -> no retry" test -z "$(fn xcode_for_retry "$T/other.log" "$CLT" "$XA")"
check "(8) retry: no Xcode installed -> no retry" test -z "$(fn xcode_for_retry "$T/macro.log" "$CLT" "$T/nothing-here")"
check "(8) retry: user DEVELOPER_DIR -> no retry" test -z "$(fn_dev /some/where xcode_for_retry "$T/macro.log" "$CLT" "$XA")"

# (9) message selection
check "(9) macro log recognised" fn build_failed_for_toolchain "$T/macro.log"
check "(9) other log is not a toolchain problem" sh -c "! TOKENMETER_SOURCE_ONLY=1 . '$INSTALL'; ! build_failed_for_toolchain '$T/other.log'"
check "(9) license log recognised" fn build_failed_for_license "$T/license.log"
check "(9) macro log is not a license problem" sh -c "TOKENMETER_SOURCE_ONLY=1 . '$INSTALL'; ! build_failed_for_license '$T/macro.log'"
M="$(fn report_build_failure "$T/macro.log" 2>&1)"
check "(9) macro message: install Xcode, open once, no xcode-select change needed" sh -c "printf '%s' \"\$1\" | grep -q 'Install Xcode from the App Store, open it once to accept the license' && printf '%s' \"\$1\" | grep -q 'do not need to change xcode-select'" _ "$M"
check "(9) macro message: names the commands to include when asking for help" sh -c "printf '%s' \"\$1\" | grep -q 'xcode-select -p' && printf '%s' \"\$1\" | grep -q 'xcodebuild -version'" _ "$M"
L="$(fn report_build_failure "$T/license.log" 2>&1)"
check "(9) license message" sh -c "printf '%s' \"\$1\" | grep -q 'Open Xcode once, or run: sudo xcodebuild -license accept'" _ "$L"
O="$(fn report_build_failure "$T/other.log" 2>&1)"
check "(9) other failure shows the log tail and path" sh -c "printf '%s' \"\$1\" | grep -q 'something else broke' && printf '%s' \"\$1\" | grep -q 'Full build log:'" _ "$O"

# (10) end-to-end source failure with a fake repo whose build.sh reports the macro-plugin error
FAKE="$T/fakerepo"; mkdir -p "$FAKE"
printf '#!/bin/bash\necho "building..."\necho "error: plugin for module '"'"'SwiftUIMacros'"'"' not found"\nexit 1\n' > "$FAKE/build.sh"
chmod +x "$FAKE/build.sh"
git -C "$FAKE" init -q -b main
git -C "$FAKE" -c user.name=t -c user.email=t@example.com add build.sh
git -C "$FAKE" -c user.name=t -c user.email=t@example.com commit -q -m fake
sb="$T/run-e2e"; mkdir -p "$sb/home" "$sb/dest/TokenMeter.app"; printf 'old' > "$sb/dest/TokenMeter.app/sentinel"; RC=0
OUT="$(env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb" TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$sb/dest" \
  TOKENMETER_SRC="$sb/src" TOKENMETER_REPO="$FAKE" TOKENMETER_FROM_SOURCE=1 bash "$INSTALL" </dev/null 2>&1)" || RC=$?
check "(10) e2e: fails with exit 1" test "$RC" -eq 1
check "(10) e2e: explanation printed" has "Your Command Line Tools cannot build SwiftUI apps"
check "(10) e2e: toolchain version printed before the build" has "Toolchain:"
check "(10) e2e: build progress still visible" has "building..."
check "(10) e2e: log path printed" has "Build log: "
check "(10) e2e: installed app untouched" test "$(cat "$sb/dest/TokenMeter.app/sentinel")" = "old"

# (11) default destination is ~/Applications (fake HOME), system copies, explicit overrides, ordering.
# Stubs stand in for sudo/pgrep/osascript/open/pkill so nothing real is quit, opened or elevated.
STUB="$T/stubs"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/sudo"
printf '#!/bin/sh\necho "pgrep" >> "$STUBLOG"\nif [ -e "$STUBLOG.q" ]; then exit 1; fi\nexit 0\n' > "$STUB/pgrep"
printf '#!/bin/sh\necho "osascript" >> "$STUBLOG"\ntouch "$STUBLOG.q"\nexit 0\n' > "$STUB/osascript"
printf '#!/bin/sh\necho "open $*" >> "$STUBLOG"\nexit 0\n' > "$STUB/open"
printf '#!/bin/sh\necho "pkill" >> "$STUBLOG"\nexit 0\n' > "$STUB/pkill"
chmod +x "$STUB"/*
make_release "$REL" "$SHA_A" "$SHA_A" "1.0.0" "1.0.0"

# run_default SANDBOX ENV...: install.sh with no TOKENMETER_DEST in sandbox dir SANDBOX (pre-populate it first).
# Sets OUT, RC, UAPPS (fake ~/Applications), SYS (fake /Applications), LOG (stub call log).
run_default() {
  local sb="$1"; shift
  mkdir -p "$sb/home" "$sb/sys"
  UAPPS="$sb/home/Applications"; SYS="$sb/sys"; LOG="$sb/stub.log"; : > "$LOG"
  RC=0
  OUT="$(env -i PATH="$STUB:$PATH" HOME="$sb/home" TMPDIR="$sb" STUBLOG="$LOG" \
      TOKENMETER_SYSTEM_APPS="$SYS" TOKENMETER_SRC="$sb/src" TOKENMETER_REPO="$sb/no-such-repo" \
      TOKENMETER_RELEASE_BASE="file://$REL" "$@" bash "$INSTALL" </dev/null 2>&1)" || RC=$?
}

# fresh machine: installs to ~/Applications, quits the running app, then opens the new one
sb="$T/d-fresh"; rm -rf "$sb"; mkdir -p "$sb"
run_default "$sb"
check "(11) default: installs to ~/Applications" test "$RC" -eq 0 -a -x "$UAPPS/TokenMeter.app/Contents/MacOS/TokenMeter"
check "(11) default: nothing in the system folder" test -z "$(ls -A "$SYS")"
check "(11) default: no sudo mentioned" hasnt "sudo"
check "(11) default: running app quit, then new app opened" sh -c "grep -q osascript '$LOG' && grep -q '^open ' '$LOG'"

# existing system copy only -> updated where it is
sb="$T/d-sysonly"; rm -rf "$sb"; mkdir -p "$sb/sys/TokenMeter.app/Contents"; printf old > "$sb/sys/TokenMeter.app/sentinel"
run_default "$sb" TOKENMETER_NO_LAUNCH=1
check "(11) system copy: updated where it is" test "$RC" -eq 0 -a -x "$SYS/TokenMeter.app/Contents/MacOS/TokenMeter"
check "(11) system copy: no new copy in ~/Applications" test ! -e "$UAPPS/TokenMeter.app"
check "(11) system copy: explanatory message" has "Updating the existing copy in /Applications. New installs go to ~/Applications; to move it, run uninstall.sh and install again."

# copies in both places -> ~/Applications updated, warning printed, system copy untouched
sb="$T/d-both"; rm -rf "$sb"; mkdir -p "$sb/home/Applications/TokenMeter.app" "$sb/sys/TokenMeter.app"; printf old > "$sb/sys/TokenMeter.app/sentinel"
run_default "$sb" TOKENMETER_NO_LAUNCH=1
check "(11) both copies: ~/Applications updated" test "$RC" -eq 0 -a -x "$UAPPS/TokenMeter.app/Contents/MacOS/TokenMeter"
check "(11) both copies: warns about the second copy" has "a second copy exists at $SYS/TokenMeter.app"
check "(11) both copies: system copy untouched" test "$(cat "$SYS/TokenMeter.app/sentinel")" = "old"

# explicit TOKENMETER_DEST overrides everything
sb="$T/d-explicit"; rm -rf "$sb"; mkdir -p "$sb"
run_default "$sb" TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$sb/custom"
check "(11) explicit dest: installs there" test "$RC" -eq 0 -a -x "$sb/custom/TokenMeter.app/Contents/MacOS/TokenMeter"
check "(11) explicit dest: not in ~/Applications" test ! -e "$UAPPS/TokenMeter.app"

# explicit non-writable dest, no tty, sudo unusable -> fails; destination verified BEFORE quitting anything
sb="$T/d-nowrite"; rm -rf "$sb"; mkdir -p "$sb/locked"; chmod 555 "$sb/locked"
run_default "$sb" TOKENMETER_DEST="$sb/locked"
chmod 755 "$sb/locked"
check "(11) unwritable explicit dest: fails" test "$RC" -ne 0
check "(11) unwritable explicit dest: clear message" has "Cannot write to $sb/locked. Nothing was changed."
check "(11) unwritable explicit dest: nothing installed" test -z "$(ls -A "$sb/locked")"
check "(11) unwritable explicit dest: app never quit (checked before quitting)" test ! -s "$LOG"
check "(11) unwritable explicit dest: no fallback to ~/Applications" test ! -e "$UAPPS"

# existing system copy that cannot be updated -> clear message, never sudo, nothing quit or changed
sb="$T/d-sysro"; rm -rf "$sb"; mkdir -p "$sb/sys/TokenMeter.app/Contents"
chmod 555 "$sb/sys/TokenMeter.app/Contents" "$sb/sys/TokenMeter.app" "$sb/sys"
run_default "$sb"
chmod 755 "$sb/sys" "$sb/sys/TokenMeter.app" "$sb/sys/TokenMeter.app/Contents"
check "(11) unwritable system copy: tells the user to run uninstall.sh" has "Run uninstall.sh, then re-run this installer"
check "(11) unwritable system copy: fails without quitting or changing anything" test "$RC" -ne 0 -a ! -s "$LOG" -a ! -e "$UAPPS"

# (12) Swift toolchain too old (Xcode 15.x has Swift 5.10; the package needs Swift 6 / Xcode 16+)
printf "error: package 'tokenmeter' is using Swift tools version 6.0.0 but the installed version is 5.10.0\n" > "$T/swiftver.log"
check "(12) swift-version log recognised" fn build_failed_for_swift_version "$T/swiftver.log"
check "(12) other logs are not swift-version problems" sh -c "TOKENMETER_SOURCE_ONLY=1 . '$INSTALL'; ! build_failed_for_swift_version '$T/macro.log' && ! build_failed_for_swift_version '$T/other.log'"
XM="$T/xc14/Applications"
mkdir -p "$XM/Xcode_15.4.app/Contents/Developer" "$XM/Xcode_16.2.app/Contents/Developer" "$XM/Xcode_16.1.app/Contents/Developer"
setver "$XM/Xcode_15.4.app" 15.4; setver "$XM/Xcode_16.2.app" 16.2; setver "$XM/Xcode_16.1.app" 16.1
check "(12) retry: Swift-version failure on Xcode 15.4 -> retry with Xcode 16.2" test "$(fn xcode_for_retry "$T/swiftver.log" "$XM/Xcode_15.4.app/Contents/Developer" "$XM")" = "$XM/Xcode_16.2.app/Contents/Developer"
check "(12) retry: Swift-version failure on CLT -> retry with Xcode 16.2" test "$(fn xcode_for_retry "$T/swiftver.log" "$CLT" "$XM")" = "$XM/Xcode_16.2.app/Contents/Developer"
check "(12) retry: 16.2 already tried -> no retry" test -z "$(fn xcode_for_retry "$T/swiftver.log" "$XM/Xcode_16.2.app/Contents/Developer" "$XM")"
check "(12) xcode: CLT selected -> 16.2 preferred over 15.4 and 16.1" test "$(fn xcode_for_build "$CLT" "$XM")" = "$XM/Xcode_16.2.app/Contents/Developer"
XO="$T/xc15/Applications"; mkdir -p "$XO/Xcode_15.4.app/Contents/Developer"; setver "$XO/Xcode_15.4.app" 15.4
check "(12) xcode: only 15.4 installed -> still returned (the build then reports it is too old)" test "$(fn xcode_for_build "$CLT" "$XO")" = "$XO/Xcode_15.4.app/Contents/Developer"
check "(12) retry: only 15.4 installed and already tried -> no retry" test -z "$(fn xcode_for_retry "$T/swiftver.log" "$XO/Xcode_15.4.app/Contents/Developer" "$XO")"
SV="$(fn report_build_failure "$T/swiftver.log" 2>&1)"
check "(12) message: Swift 6.0 / Xcode 16 / macOS 14.5 / license / toolchain line / log path" sh -c "printf '%s' \"\$1\" | grep -q 'Your Swift toolchain is too old: TokenMeter needs Swift 6.0, which comes with Xcode 16 or newer.' && printf '%s' \"\$1\" | grep -q 'Xcode 16 needs macOS 14.5 or later' && printf '%s' \"\$1\" | grep -q 'accept the license' && printf '%s' \"\$1\" | grep -q 'Your toolchain: ' && printf '%s' \"\$1\" | grep -q 'Build log: '" _ "$SV"

# end-to-end: only Xcode 15.4 installed (in the fake home), build.sh reports the old Swift -> message, exit non-zero, installed app untouched
FAKE2="$T/fakerepo2"; mkdir -p "$FAKE2"
printf '#!/bin/bash\necho "building..."\necho "error: package '"'"'tokenmeter'"'"' is using Swift tools version 6.0.0 but the installed version is 5.10.0"\nexit 1\n' > "$FAKE2/build.sh"
chmod +x "$FAKE2/build.sh"
git -C "$FAKE2" init -q -b main
git -C "$FAKE2" -c user.name=t -c user.email=t@example.com add build.sh
git -C "$FAKE2" -c user.name=t -c user.email=t@example.com commit -q -m fake
sb="$T/run-old15"; rm -rf "$sb"; mkdir -p "$sb/home/Applications/Xcode_15.4.app/Contents/Developer" "$sb/dest/TokenMeter.app"
setver "$sb/home/Applications/Xcode_15.4.app" 15.4; printf 'old' > "$sb/dest/TokenMeter.app/sentinel"; RC=0
OUT="$(env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb" TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$sb/dest" \
  TOKENMETER_SRC="$sb/src" TOKENMETER_REPO="$FAKE2" TOKENMETER_FROM_SOURCE=1 bash "$INSTALL" </dev/null 2>&1)" || RC=$?
check "(12) e2e: fails with exit 1" test "$RC" -eq 1
check "(12) e2e: too-old message printed" has "Your Swift toolchain is too old"
check "(12) e2e: installed app untouched" test "$(cat "$sb/dest/TokenMeter.app/sentinel")" = "old"

printf '\n%s passed, %s failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
