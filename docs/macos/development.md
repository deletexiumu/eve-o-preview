# Development

This page is for people who build EVE-O Preview for macOS themselves or work on its code. For what the app does and how to use it, see the [README](../../README.md). The architecture is described in [architecture.md](architecture.md) (in Chinese).

## Requirements

- macOS 14 or later, on Apple Silicon or Intel.
- Xcode or the Command Line Tools (Swift 6).

The repository holds both the macOS and the Windows version. The macOS code is in `macos/` (`Package.swift`, `Sources/`, `Tests/`, `VERSION`), the map data in `shared/static/`, and the scripts that check both platforms in `scripts/`. Run `swift` commands in the `macos/` folder, and run the scripts from the repository root.

## Build the app

1. In the repository root, run `macos/scripts/build-app.sh`. The script builds the release configuration, then assembles and signs `dist/EVE-O Preview.app`.
2. Drag `dist/EVE-O Preview.app` into the Applications folder.
3. Open the app.

The script reads these environment variables:

| Variable | Purpose | Default |
| --- | --- | --- |
| `VERSION` | Version number written into `Info.plist` | Contents of the `macos/VERSION` file |
| `SIGN_IDENTITY` | Code signing identity | `EVEO Preview Dev` if it is in the keychain, otherwise ad-hoc (`-`) |
| `UNIVERSAL` | `1` builds arm64 and x86_64 separately and merges them with `lipo` into a universal binary | Unset: native architecture only |

If `macos/packaging/AppIcon.png` exists, the script uses it to generate the app icon.

`macos/scripts/package-release.sh` runs `build-app.sh`, then writes the dmg, the source archives and `SHA256SUMS.txt` to `dist/release/`. The CI uses this script.

A build you make yourself cannot update itself from GitHub releases, because it is not signed with the release certificate. Use a release from the [Releases](https://github.com/deletexiumu/eve-o-preview-macos/releases) page if you want in-app updates.

### Sign with a self-signed certificate

macOS identifies an app by its code signature when it records permissions. An ad-hoc signature has no stable identity, so after every rebuild macOS treats the app as a different one and both permissions are lost. When you build it yourself, use a self-signed certificate:

1. Open Keychain Access and choose Keychain Access > Certificate Assistant > Create a Certificate.
2. Enter the name `EVEO Preview Dev`, set Identity Type to "Self-Signed Root" and Certificate Type to "Code Signing", then create it.
3. Run `macos/scripts/build-app.sh`. The script uses this certificate automatically when it finds it in the keychain; you can also run `SIGN_IDENTITY="EVEO Preview Dev" macos/scripts/build-app.sh`.
4. If macOS asks whether `codesign` may use the private key in the keychain, choose "Always Allow".

**Note:** When you run the executable directly with `swift run`, macOS records permissions under your terminal app, not under `EVE-O Preview.app`.

## Commands

Run the `swift` commands in `macos/` and the others from the repository root.

| Command | Purpose |
| --- | --- |
| `swift build` | Build all targets |
| `swift test` | Run the Core unit tests (swift-testing) |
| `EVEO_FAKE=1 swift run EVEOPreview` | Demo mode: 3 fake clients with generated animated images, needing neither EVE nor any permission |
| `python3 scripts/check_quality.py` | Check comment ratio, file length and function length |
| `python3 scripts/check_release_notes.py` | Check the language markers and rules of the release notes |
| `python3 scripts/check_links.py` | Check the relative links between the Markdown files |
| `macos/scripts/build-app.sh` | Assemble and sign the `.app` |
| `macos/scripts/package-release.sh` | Build the dmg, source archives and checksums in `dist/release/` |
| `swift run EVEOProbe gamelog [dir] [--follow seconds]` | Count each kind of combat line in the game logs, to diagnose combat alerts |
| `swift run EVEOProbe mousetap <seconds> [--swallow <button>]` | Print mouse button numbers, to diagnose mouse hotkeys |
| `swift run EVEOProbe update feed [url]` | Fetch and parse the release feed |
| `swift run EVEOProbe update verify <new app> <base app>` | Check whether a new app satisfies the base app's designated requirement |
| `swift run EVEOProbe update prepare <url> [--cache dir]` | Download and verify an update without installing it |
| `macos/scripts/make-update-test-feed.sh [version]` | Write a `feed.json` for a local update test from `dist/release/` |
| `swift run EVEOProbe staticdata` | Show where the map data file was found, its SDE build, record counts and the time for one 15-jump distance table |
| `swift run EVEOProbe chatlog [dir] [--follow seconds]` | Show the chat log folder, channel kinds, message and location line counts, without names or message text |
| `swift run EVEOProbe intel [dir] [--resolve-sample] [--resolve]` | Count intel messages, systems, ships and pilot names in recent chat logs; `--resolve-sample` sends three made-up names to ESI, `--resolve` sends the pilot names from your logs to ESI |
| `swift run EVEOProbe translate [--provider id] [--model name] [--base-url url] [--target language] [--dry-run]` | Send one fixed sample to a model service, with the key taken only from `EVEO_TRANSLATION_API_KEY`. Without `--dry-run` this is a real request that may cost money |
| `python3 shared/static/build-sde-data.py [--check]` | Download CCP's SDE and regenerate `shared/static/eve-static.json`; `--check` only compares the SDE build |

## Demo mode and debugging

Demo mode writes its configuration to `config-fake.json` in the same folder, leaving the real configuration untouched. It also feeds two fake chat channels, `intel.Demo` and `chat.Demo`, translates with a fake service that prefixes each line with 〔译〕, and checks pilot names without a network connection. These environment variables help with debugging:

| Variable | Purpose |
| --- | --- |
| `EVEO_CONFIG_PATH` | Use the given configuration file |
| `EVEO_LANG` | `en`, `zh`, `ru`, `ja`, `ko`, `fr`, `de` or `es`; overrides the UI language in the configuration |
| `EVEO_FAKE_DENY` | In demo mode, pretend a permission is missing: `screen`, `ax` or `screen,ax` |
| `EVEO_FAKE_STOP_AFTER` | In demo mode, pretend the user stopped the second client's capture after this many seconds |
| `EVEO_SETTINGS_PAGE` | Open a settings page directly on launch, such as `previews` |
| `EVEO_LOG_DIR` | Write the log files to another folder (default `~/Library/Logs/EVE-O Preview/`) |
| `EVEO_STATE_DIR` | Keep `state.json` and `session.json` in another folder |
| `EVEO_LOG_PRIVATE` | `1` shows private values in the system log (Console) only; log files always contain `<private>` |
| `EVEO_UPDATE_FEED_URL` | Check this address for updates instead of GitHub; only `https` or `http` on a loopback host. Builds signed with a local certificate may install from it; the signature check is not relaxed |
| `EVEO_UPDATE_UI_STATE` | In demo mode, show the update UI in a sample state: `available`, `notifyonly`, `downloading`, `ready`, `failed` or `uptodate` |
| `EVEO_FAKE_CRASH` | `1` in demo mode pretends the previous run crashed, to show the crash report prompt |
| `EVEO_STATIC_DATA` | Use this map data file instead of the one inside the app |
| `EVEO_TRANSLATION_API_KEY` | API key for `EVEOProbe translate` only; the app never reads it |

## Code layout

The source has 3 modules:

- `EVEOPreviewCore` is the pure logic layer, covered by the unit tests.
- `EVEOPreviewPlatform` wraps AppKit, ScreenCaptureKit, Accessibility and Carbon hotkeys.
- `EVEOPreview` is the app itself.

The map and ship data used by the intel and translation overlays (systems, regions, stargates, ship groups and ships, with their names in the 8 UI languages) is generated from CCP's static data export (SDE) by `shared/static/build-sde-data.py` and shipped inside the app as `eve-static.json` (kept in `shared/static/`); `macos/scripts/build-app.sh` copies it into the app. The app does not download it at run time. To try a newer file without rebuilding, put it at `~/Library/Application Support/EVE-O Preview/eve-static.json`.

Code rules (section 8 of the architecture document): files stay under 1,000 lines, functions under 500 lines, and the comment ratio above 20%. `scripts/check_quality.py` checks them in CI.

## CI

`.github/workflows/macos.yml` runs on GitHub-hosted macOS runners:

- Every pull request to `main` that changes `macos/`, `shared/`, `scripts/`, `docs/release-notes/macos/` or the workflow, and every such push to `main`, runs the quality gate, the release-notes check and the unit tests, then builds a universal dmg and the source archives. They are uploaded as a workflow artifact named `EVE-O-Preview-<version>-pr.<number>.<commit>` (or `-dev.<commit>` for pushes) and kept for 30 days.
- Pushing a `v*` tag builds the same files and publishes them as a GitHub Release. The tag must match the `macos/VERSION` file. If `docs/release-notes/macos/<tag>.md` exists, it becomes the release notes.

Release builds are signed with the project's fixed self-signed certificate "EVE-O Preview Release", so macOS keeps the Screen Recording and Accessibility permissions across updates. Pull requests from forks cannot read the signing secret and fall back to an ad-hoc signature.

## Releasing a version

1. In a pull request, change the `macos/VERSION` file and add `docs/release-notes/macos/v<version>.md`.
2. Merge the pull request into `main`.
3. Tag `main` and push the tag: `git tag -a v<version> -m v<version> && git push origin v<version>`.

The workflow then publishes the GitHub Release, and installed copies pick it up through the in-app updater.

The asset names (`EVE-O-Preview-<version>.dmg`, `SHA256SUMS.txt`), the dmg layout, the signing certificate and the release-notes format are a contract with the in-app updater; CI checks them on every build. Details are in sections 9.5 to 9.7 of [architecture.md](architecture.md).

### Release notes

The release notes are shown both on the GitHub Release page and in the app's update window. When a user skips versions, the window shows the notes of every skipped version one after another, so:

- Describe only the changes in this version.
- Do not add an "Upgrading" section, installation steps or signing notes. Those are covered once in the README, and repeating them in every version clutters the update window. `scripts/check_release_notes.py` rejects such a section.
- Put English first between `<!-- lang:en -->` and `<!-- /lang:en -->`, followed by collapsible `zh`, `ja`, `ko`, `ru`, `fr`, `de` and `es` blocks marked the same way, each wrapped in `<details>`. The app picks the block for the interface language and falls back to English.
