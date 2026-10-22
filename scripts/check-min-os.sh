#!/bin/bash
#
# Guards macOS 14 compatibility without needing a macOS 14 machine.
#
#   scripts/check-min-os.sh path/to/TokenMeter.app
#
# What this script does:
#   1. Reads LSMinimumSystemVersion from the app's Info.plist and requires it to be exactly 14.0.
#   2. Splits the main executable into each architecture slice (lipo -thin) and reads its
#      deployment target (minos) with `vtool -show-build`; every slice must be 14.0 or older.
#   Exits 0 if all checks pass, 1 otherwise. Prints what it found. Read-only apart from a temp dir.
#
# No network access.

set -euo pipefail

say()  { printf '==> %s\n' "$*"; }
fail() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

# ver_le A B: success if dotted version A <= B (numeric, missing parts are 0).
ver_le() {
  local i a b
  local -a pa pb
  IFS=. read -r -a pa <<<"$1"
  IFS=. read -r -a pb <<<"$2"
  for i in 0 1 2; do
    a="${pa[$i]:-0}"; b="${pb[$i]:-0}"
    [ "$a" -lt "$b" ] && return 0
    [ "$a" -gt "$b" ] && return 1
  done
  return 0
}

TMP=""
main() {
  [ $# -eq 1 ] || { echo "Usage: check-min-os.sh path/to/TokenMeter.app" >&2; exit 2; }
  local app="$1"
  [ -d "$app" ] || fail "$app is not a directory."

  local plist="$app/Contents/Info.plist" exe min
  min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || true)"
  say "LSMinimumSystemVersion = ${min:-<missing>}"
  [ "$min" = "14.0" ] || fail "LSMinimumSystemVersion must be exactly 14.0."

  exe="$app/Contents/MacOS/TokenMeter"
  [ -f "$exe" ] || fail "$exe not found."
  local archs arch
  archs="$(lipo -archs "$exe")"
  say "architectures: $archs"
  [ -n "$archs" ] || fail "could not read architectures."

  TMP="$(mktemp -d "${TMPDIR:-/tmp}/tokenmeter-minos.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  for arch in $archs; do
    local slice="$TMP/$arch" minos
    if [ "$(printf '%s\n' $archs | wc -l | tr -d ' ')" -eq 1 ]; then cp "$exe" "$slice"; else lipo -thin "$arch" -output "$slice" "$exe"; fi
    minos="$(vtool -show-build "$slice" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')"
    say "$arch: minos = ${minos:-<missing>}"
    [ -n "$minos" ] || fail "$arch: could not read minos (vtool -show-build)."
    ver_le "$minos" "14.0" || fail "$arch: minos $minos is newer than 14.0, the app would not launch on macOS 14."
  done
  say "OK: deployment target is 14.0 or older for every slice."
}

main "$@"
