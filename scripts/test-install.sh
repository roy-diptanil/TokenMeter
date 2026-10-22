#!/bin/bash
#
# Tests for install.sh. Uses only temp dirs, file:// release bases and a fake app bundle.
# Never touches /Applications, ~/Applications, ~/.tokenmeter-src or ~/Library, never launches
# the app, and makes no network calls (TOKENMETER_MAIN_SHA is always set).
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

# make_release DIR PLIST_COMMIT MARKER_COMMIT: fake bundle + zip + sha256 + commit marker in DIR.
make_release() {
  local dir="$1" plist_commit="$2" marker="$3"
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
  <key>TokenMeterCommit</key><string>$plist_commit</string>
  <key>TokenMeterDirty</key><string>false</string>
</dict></plist>
PLIST
  codesign --force --deep -s - "$app" >/dev/null 2>&1
  ( cd "$dir/stage" && ditto -c -k --keepParent TokenMeter.app ../TokenMeter.zip )
  ( cd "$dir" && shasum -a 256 TokenMeter.zip > TokenMeter.zip.sha256 )
  printf '%s\n' "$marker" > "$dir/TokenMeter.commit"
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

REL="$T/release"

# (i) happy path
make_release "$REL" "$SHA_A" "$SHA_A"
run_install happy TOKENMETER_RELEASE_BASE="file://$REL" TOKENMETER_MAIN_SHA="$SHA_A"
check "(i) prebuilt: exit 0" test "$RC" -eq 0
check "(i) prebuilt: says it used the prebuilt release" has "Using the prebuilt release (aaaaaaa)"
check "(i) prebuilt: app installed" test -x "$DEST/TokenMeter.app/Contents/MacOS/TokenMeter"
check "(i) prebuilt: no source checkout created" test ! -e "$SRC"
check "(i) prebuilt: temp work dir removed" sh -c "! ls '$T'/run-happy | grep -q tokenmeter-install"

# (i-b) main SHA lookup unavailable -> use the release as is (bogus value is treated as unknown)
run_install nomain TOKENMETER_RELEASE_BASE="file://$REL" TOKENMETER_MAIN_SHA="not-a-sha"
check "(i-b) unknown main: installs release with a note" sh -c "[ $RC -eq 0 ]"
check "(i-b) unknown main: note printed" has "could not look up main"

# (ii) checksum mismatch -> fallback, source fails, destination untouched
make_release "$REL" "$SHA_A" "$SHA_A"
printf '%s  TokenMeter.zip\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$REL/TokenMeter.zip.sha256"
mkdir -p "$T/pre-dest/TokenMeter.app" && printf 'old' > "$T/pre-dest/TokenMeter.app/sentinel"
run_install badsum TOKENMETER_RELEASE_BASE="file://$REL" TOKENMETER_MAIN_SHA="$SHA_A"
check "(ii) checksum: fallback message" has "Prebuilt download failed (checksum mismatch); building from source instead."
check "(ii) checksum: exits non-zero (source also fails)" test "$RC" -ne 0
check "(ii) checksum: destination untouched" test -z "$(ls -A "$DEST")"
# same, with an existing installed app that must survive untouched
mkdir -p "$T/run-badsum2/dest/TokenMeter.app"; printf 'old' > "$T/run-badsum2/dest/TokenMeter.app/sentinel"
sb="$T/run-badsum2"; RC=0
OUT="$(env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb" TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$sb/dest" \
  TOKENMETER_SRC="$sb/src" TOKENMETER_REPO="$sb/nope" TOKENMETER_RELEASE_BASE="file://$REL" \
  TOKENMETER_MAIN_SHA="$SHA_A" bash "$INSTALL" </dev/null 2>&1)" || RC=$?
check "(ii) checksum: existing app left in place" test "$(cat "$sb/dest/TokenMeter.app/sentinel")" = "old"

# (iii) marker != plist commit
make_release "$REL" "$SHA_B" "$SHA_A"
run_install mismatch TOKENMETER_RELEASE_BASE="file://$REL" TOKENMETER_MAIN_SHA="$SHA_A"
check "(iii) marker mismatch: fallback message" has "Prebuilt download failed (app commit does not match the release marker); building from source instead."
check "(iii) marker mismatch: bundle not installed" test ! -e "$DEST/TokenMeter.app"

# (iv) release behind main
make_release "$REL" "$SHA_A" "$SHA_A"
run_install behind TOKENMETER_RELEASE_BASE="file://$REL" TOKENMETER_MAIN_SHA="$SHA_B"
check "(iv) behind main: message" has "The prebuilt release is behind main; building from source instead."
check "(iv) behind main: bundle not installed" test ! -e "$DEST/TokenMeter.app"

# (v) FROM_SOURCE skips prebuilt entirely
run_install fromsrc TOKENMETER_FROM_SOURCE=1 TOKENMETER_RELEASE_BASE="file://$REL" TOKENMETER_MAIN_SHA="$SHA_A"
check "(v) from source: prebuilt skipped" test "$RC" -ne 0
check "(v) from source: no prebuilt messages" sh -c "! printf '%s' \"\$1\" | grep -q 'prebuilt'" _ "$(printf '%s' "$OUT" | grep -v 'TOKENMETER_FROM_SOURCE')"
check "(v) from source: announces source build" has "TOKENMETER_FROM_SOURCE=1"

# (vi) toolchain error text, via the function and end-to-end with a fake repo whose build.sh fails
printf 'error: external macro implementation type X could not be found\nplugin for module SwiftUIMacros not found\n' > "$T/macro.log"
printf 'error: something else broke\n' > "$T/other.log"
FUNC_OUT="$(TOKENMETER_SOURCE_ONLY=1 bash -c ". '$INSTALL'; build_failed_for_toolchain '$T/macro.log' && echo MATCH; build_failed_for_toolchain '$T/other.log' || echo NOMATCH; report_build_failure '$T/macro.log'; report_build_failure '$T/other.log'" 2>&1)"
check "(vi) log matcher: macro log matches" sh -c "printf '%s' \"\$1\" | grep -q '^MATCH'" _ "$FUNC_OUT"
check "(vi) log matcher: other log does not match" sh -c "printf '%s' \"\$1\" | grep -q '^NOMATCH'" _ "$FUNC_OUT"
check "(vi) explanation mentions Xcode + xcode-select" sh -c "printf '%s' \"\$1\" | grep -q 'sudo xcode-select -s /Applications/Xcode.app'" _ "$FUNC_OUT"
check "(vi) other failure shows tail + log path" sh -c "printf '%s' \"\$1\" | grep -q 'something else broke'" _ "$FUNC_OUT"

FAKE="$T/fakerepo"; mkdir -p "$FAKE"
printf '#!/bin/bash\necho "building..."\necho "error: plugin for module '"'"'SwiftUIMacros'"'"' not found"\nexit 1\n' > "$FAKE/build.sh"
chmod +x "$FAKE/build.sh"
git -C "$FAKE" init -q -b main
git -C "$FAKE" -c user.name=t -c user.email=t@example.com add build.sh
git -C "$FAKE" -c user.name=t -c user.email=t@example.com commit -q -m fake
sb="$T/run-e2e"; mkdir -p "$sb/home" "$sb/dest/TokenMeter.app"; printf 'old' > "$sb/dest/TokenMeter.app/sentinel"; RC=0
OUT="$(env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb" TOKENMETER_NO_LAUNCH=1 TOKENMETER_DEST="$sb/dest" \
  TOKENMETER_SRC="$sb/src" TOKENMETER_REPO="$FAKE" TOKENMETER_FROM_SOURCE=1 bash "$INSTALL" </dev/null 2>&1)" || RC=$?
check "(vi) e2e: fails with exit 1" test "$RC" -eq 1
check "(vi) e2e: Xcode explanation printed" has "Your Command Line Tools cannot build SwiftUI apps"
check "(vi) e2e: build progress still visible" has "building..."
check "(vi) e2e: log path printed" has "Build log: "
check "(vi) e2e: installed app untouched" test "$(cat "$sb/dest/TokenMeter.app/sentinel")" = "old"

printf '\n%s passed, %s failed\n' "$PASS" "$FAILS"
[ "$FAILS" -eq 0 ]
