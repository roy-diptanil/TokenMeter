# TokenMeter

A macOS menu-bar app that shows your Claude and Codex usage caps, with per-model usage, for one or more accounts.

![TokenMeter popover (sample data)](docs/screenshot.png)

- Claude: the monthly spend cap (tested on an Enterprise account) or, for personal Pro/Max plans, the 5-hour and weekly limits (written from the documented shape of the data, not yet tested against a real personal account). Extra usage is shown only when it adds information beyond the cap, and per-model spend (1d, 7d, month-to-date) appears where the plan provides it.
- Codex: the monthly credit cap (Business) or a weekly limit (personal plans such as Prolite), plus per-model usage (1d, 7d, month-to-date).
- Menu-bar label: remaining % for the two accounts closest to their cap, or for up to 3 accounts you choose (⋯ → Show in menu bar). `C` is Claude, `X` is Codex; amber under 25% remaining, red under 10%.

![Menu-bar label on light and dark menu bars (sample values)](docs/menubar.png)

## Install

Requires macOS 14 (Sonoma) or later.

    curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh | bash

What the script does (it is short, read it first if you like):

- Installs the newest stable release: a prebuilt universal (Apple silicon + Intel) app. No Xcode, Swift or git needed.
- Falls back to building `main` from source (checkout in `~/.tokenmeter-src`) if the prebuilt download or any of its checks fails. See Troubleshooting.
- Installs to `~/Applications` by default (no admin rights needed). If a copy already exists in `/Applications` (and none in `~/Applications`), it is updated there in place. For a system-wide install use `TOKENMETER_DEST=/Applications`; to move an existing `/Applications` copy, run `uninstall.sh` and install again.
- Never touches your sign-ins or data in `~/Library`.
- Safe to re-run to update.
- The installer never uses `sudo` unless you set `TOKENMETER_DEST` to a folder you can't write to.

Pin or roll back to a specific release, or build the tip of `main` yourself:

    curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh | TOKENMETER_VERSION=v1.0.0 bash
    curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/install.sh | TOKENMETER_FROM_SOURCE=1 bash

Releases are built by GitHub Actions (`.github/workflows/release.yml`). Before installing a prebuilt app the installer verifies its
SHA-256 checksum, checks that the commit and version embedded in the app match the release's markers, and checks the bundle id and
code signature. If any check fails it falls back to building from source. These checks catch corruption and mismatches; they do not
protect against a compromised publisher, so the trust you place in the release is the trust you place in this repository.

Environment variables (all optional): `TOKENMETER_VERSION` (e.g. `v1.0.0`), `TOKENMETER_FROM_SOURCE=1` (skip the prebuilt),
`TOKENMETER_RELEASE_BASE` (download base URL), `TOKENMETER_DEST` (install dir), `TOKENMETER_SRC` (source checkout dir),
`TOKENMETER_REPO` (git URL), `TOKENMETER_NO_LAUNCH=1` (testing).

Then click the gauge icon in the menu bar and choose "Add account...".

### Compatibility

macOS 14 (Sonoma) or later is supported, for the prebuilt app and for source builds. The prebuilt app is a universal binary built on
macOS 15 (Xcode 16-series). It is smoke-tested (it must report its version and run `--login-item status`) on macOS 14, 15 and 26 for as
long as GitHub provides a macOS 14 runner (GitHub retires that image on 2026-11-02, so the macOS 14 CI job switches itself off after that date).
From then on a CI guard (`scripts/check-min-os.sh`) verifies that the app's deployment target stays at 14.0, and compile-time API availability
checks enforce the rest.

Source builds need Swift 6, i.e. Xcode 16 or newer (the full Xcode app, not just the Command Line Tools). On macOS 14 that means
macOS 14.5 or later for Xcode 16; check Apple's system requirements for the Xcode version you want. The installer picks the newest
installed Xcode automatically.

### Uninstalling

To uninstall (quits the app and removes it from `~/Applications` and `/Applications`; keeps your accounts and sign-ins):

    curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/uninstall.sh | bash

To also delete your accounts, cache and saved sign-ins. Run through a pipe there is no terminal to confirm on, so `--yes` is required:

    curl -fsSL https://raw.githubusercontent.com/roy-diptanil/TokenMeter/main/uninstall.sh | bash -s -- --purge-data --yes

(`~/.tokenmeter-src/uninstall.sh` also exists, but only if you ever built from source; a normal prebuilt install does not create that folder.)

If you enabled "Launch at login", you may also need to remove TokenMeter from System Settings > General > Login Items & Extensions.

### Launch at login

Launch at login only works for the installed copy (in `~/Applications` or `/Applications`); the checkbox is disabled for builds run from a source folder.
TokenMeter remembers that you turned it on and re-registers it at launch after an update or reinstall. If macOS asks for approval, use the
"Open Login Items settings" button (System Settings > General > Login Items & Extensions). To diagnose, run
`~/Applications/TokenMeter.app/Contents/MacOS/TokenMeter --login-item status`.

### Updating

TokenMeter checks for a newer release about once a day in the background (or when you click "Check for updates" in the popover footer).
It asks GitHub which release is newest (a single request to `github.com/roy-diptanil/TokenMeter/releases/latest`; no git, no login) and
compares it with its own version ("Version 1.0.0" in the footer). "Update available — v1.0.1" appears only when a newer release exists,
never because `main` moved. "Update now" runs the install command above in the background, then restarts the app. Progress goes to
`~/Library/Logs/TokenMeter-update.log`; if the app is still running after about five minutes, the footer says so and offers "Open log".
A failed install leaves the old app in place. Builds from a local checkout (or with local changes) show as "Dev build" and never prompt.

### Releasing

The version lives in the `VERSION` file (semantic versioning, `MAJOR.MINOR.PATCH`, starting at `1.0.0`). To release: bump `VERSION` in a pull
request and merge it. The `release` workflow then builds the universal app, tags `v<VERSION>` and publishes the GitHub release with
`TokenMeter.zip`, `TokenMeter.zip.sha256`, `TokenMeter.commit` and `TokenMeter.version`. Release notes are generated from the merged pull
request titles. Re-running the workflow for an existing tag does nothing. There is no rolling build of `main`.

### Troubleshooting

Source builds need the full Xcode app: on recent macOS SDKs SwiftUI's `@State` is a macro whose plugin ships only with Xcode, not with the
Command Line Tools. A failure looks like `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found` or
`plugin for module 'SwiftUIMacros' not found`. The installer uses an installed Xcode automatically even when the Command Line Tools are
selected (it sets `DEVELOPER_DIR` for the build only; it never runs `sudo` or changes `xcode-select`), and retries once with another
installed Xcode if needed. If there is no Xcode, install it from the App Store, open it once to accept the license, then re-run the
installer. If the license has not been accepted, open Xcode once or run `sudo xcodebuild -license accept`. The installer keeps the build
log and prints its path. When asking for help, include the output of `xcode-select -p` and `xcodebuild -version`.

A different failure, `package 'tokenmeter' is using Swift tools version 6.0.0 but the installed version is 5.10.0`, means the selected
toolchain is too old (Xcode 15 or older, Swift 5.10). TokenMeter needs Swift 6, which comes with Xcode 16 or newer. The installer retries once
with a newer installed Xcode; if there is none, install Xcode 16 or newer (on macOS 14, check that your macOS version meets Apple's
requirement for it). The prebuilt app has no such requirement and runs on macOS 14 or later.

### Development

    ./build.sh                                          # builds build/TokenMeter.app (ad-hoc signed); version from VERSION
    UNIVERSAL=1 ./build.sh                              # universal arm64 + x86_64 (one native build per architecture, then lipo)
    build/TokenMeter.app/Contents/MacOS/TokenMeter --version   # TokenMeter 1.0.0 (<short commit or dev>)
    scripts/package-release.sh                          # zip + sha256 + commit + version in build/ (clean tree only)
    scripts/test-install.sh                             # installer tests (temp dirs only)
    swift run SelfTest                                  # parser/logic tests (synthetic fixtures only)
    build/TokenMeter.app/Contents/MacOS/TokenMeter --dump   # one-shot fetch, prints numbers only

Needs a Swift 6 toolchain.

## Sign-in and data (local only)

You sign in to claude.ai or chatgpt.com in a window inside the app ("Add account..." or "Sign in..."). The app reads usage by
making requests from inside that web session, so it never sees or stores your password, tokens or cookies.

- Browser sessions live in a per-account WebKit data store on your Mac (`~/Library/WebKit/com.local.tokenmeter/`).
  Removing an account deletes its store.
- `~/Library/Application Support/TokenMeter/accounts.json`: account labels and store IDs.
- `~/Library/Application Support/TokenMeter/cache.json` (mode 0600): last usage numbers, the last 4 characters of an account id and a short hash used to detect duplicate accounts. No tokens.
- The only network traffic is to claude.ai and chatgpt.com from the sign-in web view. No telemetry, no server, nothing hosted.
- Credentials are never logged and never written to disk by the app. The CLI and Keychain are not used.

Saved passwords from Safari or the Passwords app do not autofill in the in-app sign-in window, and passkeys (including signing in to Google with a passkey) are not supported there: Apple allows passkeys in embedded web views only for apps with a special browser entitlement, which this app does not have. Paste a password from your password manager (Cmd+V works), or use the email one-time code where the site offers it. Sessions expire on the providers' schedule; an expired account shows a "Sign in" button.

## Account status

Each account card has a status dot, with two states:

- Green: the most recent refresh succeeded.
- Red: the most recent refresh failed for any reason (signed out, network error, endpoint changed, timeout, or per-model data unavailable), or the account was never signed in. The card keeps the last good numbers (dimmed) and shows the reason with "last synced ...". Auth problems get a "Sign in" button; anything else gets "Retry". Hover the dot for details.

Use ⋯ → Show in menu bar to pick up to 3 accounts for the menu-bar label; by default it shows the two closest to their cap (those start ticked; untick everything to go back to that default).

When any account is red, a summary row appears at the top of the popover and the menu-bar label gets a red `!` after the percentages.
Besides the 5-minute timer, TokenMeter refreshes when the Mac wakes, when the network comes back, and when you open the popover after a minute. None of these ever opens a sign-in window.
"Refresh now" shows a one-line result for a few seconds. `--dump` prints a `health:` line per account.

## Layout

- `Sources/UsageCore`: models, parsers, web session, store, menu-bar label logic
- `Sources/TokenMeter`: SwiftUI views and app entry, plus the `--dump`, `--probe-*` and `--selftest-ui` debug flags
- `Sources/SelfTest`: tests
- `scripts/`: `package-release.sh` (builds the release files), `check-min-os.sh` (deployment-target guard), `test-install.sh` (installer tests)
- `.github/workflows/`: `ci.yml` (build and tests on macOS 14, 15 and 26, plus smoke tests of the packaged app) and `release.yml` (publishes a release when `VERSION` changes)
- `VERSION`: the app version; bumping it in a merged pull request publishes a release
- `install.sh`, `uninstall.sh`: the installer and uninstaller

Gauge icon from Lucide (ISC), see `THIRD_PARTY_NOTICES.md`.

## License and disclaimer

TokenMeter is free, open-source software released under the [MIT License](LICENSE). You may use, copy, modify and
redistribute it. It is provided "as is", with no warranty of any kind, and the author accepts no responsibility or
liability for anything that results from using it.

- **Unofficial.** TokenMeter is an independent project. It is not affiliated with, endorsed by, or supported by Anthropic or OpenAI.
  "Claude" and "Codex" are used only to describe what the app reads.
- **Undocumented endpoints.** It reads usage from web endpoints that are not public APIs. They can change or stop working at any
  time, and the numbers shown may be wrong or out of date. Do not rely on them for billing or budgeting.
- **Your accounts, your responsibility.** The app signs in through a web session you create, the same way a browser does.
  Check that automated or scripted use of your account is allowed by the terms of the service and by your employer's policies.
  You are solely responsible for how you use it.
