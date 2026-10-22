#!/bin/bash
#
# Packages a universal TokenMeter release into build/ (used by CI, runnable locally).
#
# What this script does:
#   1. Runs `UNIVERSAL=1 ./build.sh` (arm64 + x86_64, ad-hoc signed).
#   2. Writes build/TokenMeter.zip          (ditto zip of TokenMeter.app)
#             build/TokenMeter.zip.sha256   ("<hash>  TokenMeter.zip")
#             build/TokenMeter.commit       (full commit SHA stamped into the app)
#             build/TokenMeter.version      (the app's CFBundleShortVersionString, from VERSION)
#   3. Refuses (exit 1) if the app was built from an unknown commit or a dirty tree,
#      so a release always maps to exactly one commit.
#
# TOKENMETER_ALLOW_DIRTY=1 skips that refusal. For LOCAL TESTING ONLY; never use it
# to produce something you publish.
#
# No network access.

set -euo pipefail

say()  { printf '==> %s\n' "$*"; }
fail() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

main() {
  local ROOT
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$ROOT"

  say "Building universal app"
  UNIVERSAL=1 ./build.sh

  local APP="$ROOT/build/TokenMeter.app" PB=/usr/libexec/PlistBuddy
  [ -d "$APP" ] || fail "$APP was not produced."
  local commit dirty version
  version="$($PB -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
  printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "The app has no valid version (found '$version')."
  commit="$($PB -c 'Print :TokenMeterCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
  dirty="$($PB -c 'Print :TokenMeterDirty' "$APP/Contents/Info.plist" 2>/dev/null || echo true)"
  if [ "${TOKENMETER_ALLOW_DIRTY:-0}" != "1" ]; then
    [ "$commit" != "unknown" ] || fail "The app has no known commit (not built from a git checkout). Refusing to package."
    [ "$dirty" != "true" ] || fail "The working tree has uncommitted changes (dirty build). Commit them first. Refusing to package."
    printf '%s' "$commit" | grep -Eq '^[0-9a-f]{40}$' || fail "Unexpected commit value in the app."
  fi

  cd "$ROOT/build"
  rm -f TokenMeter.zip TokenMeter.zip.sha256 TokenMeter.commit TokenMeter.version
  ditto -c -k --keepParent TokenMeter.app TokenMeter.zip
  shasum -a 256 TokenMeter.zip > TokenMeter.zip.sha256
  printf '%s\n' "$commit" > TokenMeter.commit
  printf '%s\n' "$version" > TokenMeter.version

  say "Release files:"
  printf '    %s\n' "$ROOT/build/TokenMeter.zip" "$ROOT/build/TokenMeter.zip.sha256" "$ROOT/build/TokenMeter.commit" "$ROOT/build/TokenMeter.version"
}

main "$@"
