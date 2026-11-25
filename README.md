<p align="center"><img src="macos/packaging/AppIcon.png" width="128" alt="EVE-O Preview icon"></p>

# EVE-O Preview for macOS & Windows

**English** | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Русский](README.ru.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Español](README.es.md)

EVE-O Preview shows a live thumbnail of every running EVE Online client. Click a thumbnail or press a global hotkey to switch to that client.

This repository holds two native apps: one for macOS, written in Swift, and one for Windows, written in Rust. They share the configuration format, the interface text and the test cases in `shared/`, and each is built on its own platform's APIs.

Both re-implement the features of [EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview) (Windows, GPL-3.0). They do not port the upstream C# code, and their UI and configuration format differ from upstream.
The project is licensed under the GNU General Public License version 3 or any later version (GPL-3.0-or-later), matching the SPDX identifiers in the source files; upstream is licensed under GPL-3.0. See [LICENSE](LICENSE) for the full text.

This repository started as a GitHub fork of EveOPlus/eve-o-preview and was moved to a standalone repository for v1.0. It is an independent project: it shares no code with upstream EveOPlus/eve-o-preview and is not maintained by the upstream authors.

## Windows

EVE-O Preview for Windows 1.0 was released on 2026-11-24. It has the same features as the macOS app: live DWM thumbnails, switching and hotkeys (including mouse buttons), layout, visibility rules, combat alerts, the intel and chat translation overlays, profiles, signed updates and problem reports. Differences from the macOS app:

- **Game frame rate** (from 1.1, off by default): the "Game frame rate" group on the General page caps every EVE client at the same frame rate (60 by default) through the graphics driver, which makes switching between clients smoother while multiboxing. It never touches the game clients. With NVIDIA it sets "Max Frame Rate" for exefile.exe, and with Intel a frame rate limit for exefile.exe; the AMD driver can only limit every game on the PC at once. Turning it off restores the previous driver setting. AMD and Intel support has not been tested on real hardware yet.
- **Start when I sign in to Windows**, on the General page.
- A notification-area icon in place of the menu bar icon: left-click opens Settings, right-click opens the menu.
- API keys are stored in Windows Credential Manager instead of the macOS Keychain.

### Installing on Windows

Requires 64-bit Windows 10 22H2 or Windows 11.

1. Download `EVE-O-Preview-<version>-windows-x64.zip` from the [Releases](https://github.com/deletexiumu/eve-o-preview/releases) page. From 1.4.0 on, the macOS and Windows versions are published together in one release tagged `v<version>`; earlier Windows releases are tagged `win-v<version>`.
2. Extract the folder somewhere you can write to, such as Documents or `D:\Games`. Do not use Program Files: updates replace the exe in place.
3. Run `EVE-O Preview.exe`. The exe is not code-signed yet, so Windows SmartScreen may warn on first run: choose "More info", then "Run anyway".

Settings are saved in `%APPDATA%\EVE-O Preview\config.json` and logs in `%LOCALAPPDATA%\EVE-O Preview\logs\`. Settings are not imported from the original EVE-O Preview. To uninstall, quit from the tray menu, turn off "Start when I sign in to Windows" if you turned it on, then delete the app folder and the two folders above. To build from source, see [windows/README.md](windows/README.md).

The rest of this document describes the macOS app.

## Features

- Client discovery: thumbnails update automatically when a client starts, exits, or is renamed after login.
- Live thumbnails: one ScreenCaptureKit stream per client, with adjustable size and frame rate.
- Thumbnail panels: they never take focus, appear on all Spaces, and can optionally stay on top. By default they have a 2-point light grey border so adjacent thumbnails are easy to tell apart; the color and width are adjustable, and the border can be turned off.
- Switching: left-click a thumbnail to switch to its client; Ctrl+click minimizes it. The right-click menu offers Minimize, Minimize All, Skip in Cycle, Hide This Thumbnail and Reset to Default Size.
- Overlays: character name title, a highlight border on the active client (color configurable per character; replaces the light grey border while shown), and a skip-in-cycle marker.
- Zoom on Hover (9 anchor points) and opacity.
- Visibility: hide the active client's thumbnail; hide when EVE is not in front (with a delay); hide per character; hide all.
- Layout: drag to move and resize, snapping to other thumbnails and screen edges, with an optional layout lock. Position and size are saved per character; clients on the login screen use a separate starting position.
- Cycle groups: forward and backward hotkeys, skip for the current session; per-character hotkeys; a hotkey to cycle through login-screen clients; Hide All and Minimize All hotkeys. Hotkeys can use the middle and side mouse buttons, and each hotkey can be global or EVE-only.
- Combat alerts (off by default): reads the game logs and flashes a character's thumbnail when that character is attacked.
- Intel overlay (off by default): reads the chat logs of the intel channels you choose and shows, for the character in the EVE window in front, which systems hostiles are reported in, how many jumps away they are, how many there are and which ships (see [Intel overlay](#intel-overlay)).
- Chat translation overlay (off by default): translates messages in other languages from the channels you choose into your language, using a model service you choose with your own API key (see [Chat translation](#chat-translation)).
- Profiles: create, clone, rename, delete and switch.
- Updates: checks GitHub for new releases and installs them from inside the app after verifying the download and its code signature (see [Updates](#updates)).
- Problem reports: builds a redacted diagnostics zip and opens a prefilled GitHub issue; after an unexpected quit, the next launch offers to report it (see [Reporting a problem](#reporting-a-problem)).
- A menu bar icon in place of the Windows tray icon.
- A 10-page settings window: Clients, Previews & Layout, Switching & Hotkeys, Alerts, Intel, Translation, Profiles, General, Permissions and About.
- UI languages: English (default), Chinese, Russian, Japanese, Korean, French, German and Spanish. Switch on the General page, or choose "Follow System"; the change takes effect immediately. The Russian, Japanese, Korean, French, German and Spanish translations are machine-generated; corrections are welcome.

## Requirements

- macOS 14 or later, on Apple Silicon or Intel. The release dmg contains a universal binary.
- EVE clients work best in windowed mode. Clients in native full screen are supported from 1.1.1 (thumbnails show over them while "Keep thumbnails on top" is on), but each lives in its own Space, so switching to one plays the Space transition animation.

## Installation

### Download a release

1. Download `EVE-O-Preview-<version>.dmg` from the [Releases](https://github.com/deletexiumu/eve-o-preview/releases) page.
2. Open the dmg and drag `EVE-O Preview.app` into the Applications folder.
3. Open the app. Its icon appears in the menu bar, and on first launch the settings window opens on the Permissions page.

Release builds are signed with the project's own self-signed certificate and are not notarized, because the project has no Apple Developer ID. On first launch macOS blocks the app with a message that it cannot verify the developer. To open it:

1. Open System Settings > Privacy & Security.
2. Scroll down to the message about EVE-O Preview and click "Open Anyway", then confirm.

If macOS says the app "is damaged and can't be opened", or as an alternative to the steps above, remove the quarantine attribute in Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/EVE-O Preview.app"
```

**Note:** Every release is signed with the same certificate, so macOS keeps the Screen Recording and Accessibility permissions when you upgrade. If the permissions stop working after an upgrade, reset them with the `tccutil` commands at the end of [Permissions](#permissions) and grant them again.

The app keeps itself up to date: it checks GitHub for new versions and installs them from inside the app (see [Updates](#updates)).

Each release also includes the source code as `.tar.gz` and `.zip`, and a `SHA256SUMS.txt` file. To verify the downloads, run `shasum -a 256 --ignore-missing -c SHA256SUMS.txt` in the download folder.

### Build from source

To build the app yourself, follow [docs/macos/development.md](docs/macos/development.md). It also covers the debugging tools, CI and the release process.

## Permissions

The app uses the system permissions below, all granted in System Settings > Privacy & Security. The Permissions page of the settings window shows their status, with request buttons and links to System Settings.

| Permission | Used for | Without it |
| --- | --- | --- |
| Screen Recording | Capturing client windows and reading window titles | Thumbnails show a placeholder; without Accessibility as well, titles cannot be read and clients show as `EVE (PID)` |
| Accessibility | Restoring, raising and minimizing client windows, reading window titles, intercepting mouse hotkeys | Only the client process can be activated, so minimized windows cannot be restored; Minimize and Minimize All are disabled; mouse hotkeys do not work, keyboard hotkeys still do |
| Documents folder | Combat alerts read `~/Documents/EVE/logs/Gamelogs`; the intel and translation overlays read `~/Documents/EVE/logs/Chatlogs`, and the intel overlay also reads the game logs to find your location | Requested only when one of these features is turned on, or when you click "Refresh" in the "Add from Logs" menu; if denied, that feature's page shows the reason and other features are unaffected |
| Local Network (macOS 15 and later) | Connecting to a translation service on another computer in your local network, such as Ollama | Asked only when the translation service runs on another computer in your local network, not for this Mac or for public services; click "Test" on the Translation page to bring up the prompt first. If denied, requests to that computer fail with a network error. Not shown on the Permissions page |

After you grant Screen Recording, the app usually has to restart for it to take effect; the Permissions page has a Relaunch button. Accessibility takes effect immediately.

If the permission records get into a bad state, run these two commands and grant the permissions again:

```sh
tccutil reset ScreenCapture io.github.deletexiumu.eveopreview-macos
tccutil reset Accessibility io.github.deletexiumu.eveopreview-macos
```

## Usage

### Thumbnail gestures

A left mouse-down switches immediately without waiting for the release, so moving and resizing use a right-drag or an Option+left-drag.

| Action | Gesture |
| --- | --- |
| Switch to the client | Left mouse-down |
| Minimize the client | Ctrl+left mouse-down |
| Open the menu | Right-click (moving less than 4 points between press and release) |
| Move | Right-drag, or Option+left-drag |
| Resize | Same gesture as moving, starting within 12 points of the thumbnail edge |
| Temporarily disable snapping | Hold Shift while dragging; while resizing, Shift also keeps the aspect ratio |

With "Lock layout" turned on, moving and resizing do nothing; switching, minimizing and the menu still work.

### Hotkeys

Record hotkeys on the Switching & Hotkeys page of the settings window: click a button, then press a key combination or mouse button. Esc cancels and Delete clears. One action can have several bindings.

- Cycle groups: each group has forward and backward hotkeys that switch, in order, between the group's characters that are online and not skipped, wrapping around at the end.
- Per-character hotkeys: switch to that character's client.
- General hotkeys: show or hide all thumbnails, minimize all, and cycle through clients on the login screen.

Keyboard hotkeys should include Ctrl, Option or Command; F1–F20 and keypad digits can be used alone. System combinations such as Cmd+Tab, Cmd+Space and Cmd+Q are rejected. When a hotkey has a problem, the settings window shows the reason next to it.

Mouse hotkeys:

- The middle and side buttons can be recorded (written as `Mouse3`–`Mouse32` in the configuration), optionally with modifiers, such as `ctrl+Mouse4`. The left and right buttons cannot be bound.
- When a hotkey fires, that click (press, drag and release) is not passed to the front app, so a game action bound to the same button does not run.
- Mouse hotkeys require the Accessibility permission.

Scope:

- Each hotkey can be "Global" or "Only in EVE", written as the suffix `@global` or `@game` in the configuration. A hotkey without a suffix follows the profile's default scope.
- An "Only in EVE" hotkey works only while an EVE client is in front. In other apps the key press is passed to that app as usual.
- Newly recorded mouse hotkeys default to Only in EVE, so side buttons are not intercepted in every app.
- "Hotkeys Only in EVE" in the menu bar menu toggles the default scope.

### Combat alerts

Turn them on in the Alerts page of the settings window. The app then reads the game logs that clients write to `~/Documents/EVE/logs/Gamelogs`, maps each log to a character by the listener in the log header, and flashes a character's thumbnail border and image for 3 seconds when that character is attacked.

- The EVE client must have game logging enabled (it is by default).
- Misses also trigger an alert by default; this can be turned off. Minimum damage, flash color and duration are configurable.
- With "Hide thumbnails when EVE is not in front" turned on, an attacked character's thumbnail is shown temporarily.
- With "Reduce motion" turned on in System Settings, the flash is replaced by a steady highlight.
- The app only reads the logs. It never writes or modifies them, and sends no input to the game.
- The first time, macOS asks for access to the Documents folder. If your logs are elsewhere, choose the folder on the Alerts page.
- The Chinese client's log format has been checked against real logs. Japanese and Russian damage lines have been checked against real client logs (upstream's recorded samples); their miss lines are inferred from templates only. English, German, French, Spanish and Korean are inferred from upstream's templates and have not been checked against real logs.

### Intel overlay

Turn it on with "Show intel overlay" on the Intel page of the settings window, or with "Show Intel Overlay" in the menu bar menu. The app then reads the chat logs that clients write to `~/Documents/EVE/logs/Chatlogs`, next to the game log folder chosen on the Alerts page. Each line of the overlay is one message from your intel channels: its age, each system with its security status and its distance in jumps from your location, the number of hostiles, the ships and the pilot names.

- The EVE client must be set to log chat to a file.
- With the client language set to anything but English, the EVE client for Mac may write no logs for Local, Corp and Alliance (seen with Chinese), so those channels stay empty in both overlays. Set EVE's language to English and log the character in again; the translation overlay says so on its status line when this happens.
- Channels: choose "Add from Logs" to pick from the channels in your recent chat logs (each shows how many of your characters are in it), or type a channel name and press Return. The log folder is read only when the overlay is on, or when you click "Refresh" in the "Add from Logs" menu; while the overlay is off, the menu at first shows only "Refresh" (and, on the Translation page, the built-in channels). Up to 16 channels. Private conversations are never read and never listed.
- When you turn it on, the overlay fills with the messages of the last 30 minutes ("Keep the last", 5–120 minutes); older lines disappear.
- Location: jumps are counted from the system the active character is in. The app takes it from the jump and undock lines in the game logs and from the system change messages in the Local chat log. If neither is available, type a system name for that character under "My Location" and press Return; an unknown name shows "System not found". The next jump replaces a manual location, and a manual location is kept across restarts. A character with no location at all counts jumps from the "Reference System".
- "Count up to" limits the jump count (1–30, default 15). "Highlight Within" highlights a message when a reported system is that many jumps away or closer (default 5; 0 turns it off). "Show original text" adds the sender and the message as a second line.
- System and ship names are shown in the interface language.
- Pilot names are what is left of a message after systems, ships and counts are recognized, so names with spaces that run together are ambiguous. With "Check pilot names online (ESI)" turned on (the default), the app asks CCP's ESI which of those words are real character names and splits them accordingly (see [Privacy](#privacy)). A match only means a character with that name exists, not that it is the one meant. A matched name gets a zKillboard link under "Open in Browser" in the right-click menu. "Clear Name Cache" deletes the saved names.

### Chat translation

Turn it on with "Show translation overlay" on the Translation page, or with "Show Translation Overlay" in the menu bar menu. It translates messages in the chosen channels that are not already in the target language.

1. Choose channels as for the intel overlay; "Add from Logs" also lists the built-in Local, Corp, Alliance and Fleet channels.
2. Under "Translate into", choose a language, or "Same as interface language" (the default).
3. Choose a "Service": DeepSeek (the default), Claude (Anthropic), OpenAI, Qwen (DashScope), Kimi (Moonshot), Ollama, or "Other (OpenAI-compatible)". "API Address" and "Model Name" show the preset values; type in them to override.
4. Paste your API key and click "Save". The key is stored in the macOS Keychain; "Delete Key" removes it. Ollama needs no key.
5. Click "Test" to translate one fixed sample sentence.

- Only messages received by the active client's character are sent to the model. The same sentence is translated once and then taken from the cache. Messages that contain only systems and ships are not sent. When the target language is Chinese, Japanese, Korean or Russian, messages already in that language are not sent either. When it is English, German, French or Spanish, every such message goes to the model, which decides whether it is already in the target language. System, region and ship names use their official names in the target language.
- Each line shows the EVE time, the channel (only when you translate more than one), the sender and the translation. "Also show original text" adds the original below it; "Only show translated messages" hides the messages skipped because they are already in the target language, including those the model judged to be in it.
- If the service rejects the key or the quota runs out, translation pauses and the status line says why; "Retry Now" tries again.
- Public addresses must use `https`; `http` is accepted only for this Mac or the local network, such as Ollama at `http://127.0.0.1:11434/v1`.
- Requests use your account with the service you choose and may cost money.
- After a rebuild with a different signature, macOS may ask for permission to read the Keychain item when you click "Test" or "Retry Now". Reads in the background are designed not to show this prompt; the status line asks you to save the key again instead. This still has to be checked by hand after a real rebuild.

### Overlay gestures

The intel and translation overlays are separate panels that behave like thumbnails: they never take focus, appear on all Spaces, and show only the character of the EVE window in front, switching content as soon as you switch clients. Clicks do not pass through to the game. The newest message is at the bottom and the list stays there. When you scroll up, the list stops following new messages and a bar at the bottom shows "N new"; click it to return to the latest.

| Action | Gesture |
| --- | --- |
| Scroll the list | Scroll wheel or two-finger swipe |
| Move | Right-drag, or Option+left-drag |
| Resize | Same gesture as moving, starting within 12 points of the overlay edge |
| Temporarily disable snapping | Hold Shift while dragging |
| Open the menu | Right-click (moving less than 4 points between press and release) |
| Return to the latest | Click the "N new" bar |

The right-click menu offers Scroll to Latest, Copy This Line, Open in Browser (only on lines with links), Clear List, Lock Layout, Reset Position and Size, Hide This Overlay and Open Settings…. "Background Opacity" (20%–100%, background only; text stays opaque) and "Font Size" (10–24 points) are on each feature's page. "Lock layout" and "Hide thumbnails when EVE is not in front" also apply to the overlays; Hide All applies to thumbnails only.

### Menu bar

The menu bar icon is a molecule inside an octagon. The menu offers: Show or Hide All Thumbnails, switch profile, Minimize All, Hotkeys Only in EVE, Show Intel Overlay, Show Translation Overlay, Check for Updates…, Report a Problem…, Settings and Quit. When an update is available or the previous run quit unexpectedly, a dot appears on the icon and the menu gets an item for it at the top. When a permission is missing, the menu has an extra item about it. If you stop a client's capture from the system's recording indicator, the menu gains a "Resume Capture" item.

EVE-O Preview also shows its icon in the Dock; clicking it opens the settings window. To keep only the menu bar icon, clear "Show icon in Dock" under Settings > General.

### Updates

EVE-O Preview checks for a new release at launch and once a day, using a signed update list on Cloudflare's CDN, with GitHub as the fallback. Releases that only change the Windows app are not offered, and the release notes show only the macOS parts. To turn this off, clear "Check for updates automatically" under Settings > General > Updates; "Check for Updates…" in the menu bar menu still checks on demand.

When a new version is available, a window shows the release notes in your interface language (English if there is no translation) and offers Install Update, Skip This Version and Later. While an EVE client is in front, the window waits until you switch away, and it never takes keyboard focus on its own; a dot on the menu bar icon shows that an update is waiting. "Skip This Version" only stops automatic reminders for that version; "Check for Updates…" still shows it.

Install Update downloads the dmg, checks it against `SHA256SUMS.txt`, verifies that the new app is signed with the same certificate as the running one, replaces the app and restarts it. If any step fails, the installed app is left unchanged. "Install updates automatically" is on by default: the update is downloaded in the background, then installed and the app restarted once no EVE client has been running for about a minute and no EVE-O Preview window is open. Otherwise it is installed when you quit EVE-O Preview, or when you choose "Restart to Update to X.Y.Z" in the menu bar menu. While an EVE client is running, the app never restarts by itself. Turn the setting off under Settings > General > Updates if you want the window to ask you first.

Some builds can only show the reason and an "Open Release Page" button instead of installing: ad-hoc or locally signed builds, an app running from a disk image or from a translocated location, an app in a folder you cannot write to, and an app on a volume that is not APFS, such as an external HFS+, exFAT or FAT disk.

### Reporting a problem

Choose "Report a Problem…" from the menu bar menu or the General page, or answer the prompt that appears after EVE-O Preview quit unexpectedly. The window lists every file that will go into the report and shows its contents after redaction: an environment summary, a settings summary without any names, the app log (up to 2 MiB) and up to three macOS crash reports. Nothing is created until you click "Create Report Only" or "Create Report and Open GitHub". The zip is saved to `~/Library/Application Support/EVE-O Preview/Reports/` (the 3 newest are kept) and Finder shows it; "Create Report and Open GitHub" also opens a prefilled issue in your browser. You attach the zip yourself; the app never uploads anything.

Your macOS user name, full name, home folder path and computer names are replaced with `[user]` and `[host]`. EVE character names become `[character-1]`, `[character-2]` and so on, and crash-report device identifiers become `[redacted]`. Only names the app knows are replaced: characters that never appeared in your settings or as a running client are not. If a name is a common word, the same word elsewhere in the log is replaced too. You can read every file before creating the report and untick any file you don't want to include.

The app keeps up to 5 log files of 1 MiB each in `~/Library/Logs/EVE-O Preview/`. Character names and window titles are written as `<private>`. Turn on "Verbose logging" in General to also record debug lines; "Show Logs in Finder" opens the folder. If no prompt appears after a crash, attach `~/Library/Logs/DiagnosticReports/EVEOPreview-<date>.ips` to the issue by hand.

## Privacy

The app connects to Cloudflare and GitHub for updates, and makes no other connections unless you turn on one of the optional features described after this list:

- Checking for updates downloads the signed update list `eveo.deepai.wiki/update-manifest.json` (served by Cloudflare), or `github.com/deletexiumu/eve-o-preview/releases/latest/download/update-manifest.json` if that fails, at launch and once a day while "Check for updates automatically" is on, and whenever you choose "Check for Updates…". The list also holds the notes of earlier versions, so showing versions you skipped needs no extra request.
- Installing an update downloads `SHA256SUMS.txt` and the dmg from `eveo.deepai.wiki`, or from the GitHub release if that fails. Each file is checked against the signed list.

The requests carry only the app version in the `User-Agent` header, a fixed `Accept-Language: en` and `Cache-Control: no-cache`; no character names, settings, logs, hardware details, system version or identifiers are sent, and no cookies are used. Cloudflare and GitHub see your IP address and the time of the request. There is no telemetry and no automatic crash upload: "Report a Problem…" only creates a zip on your Mac and opens a web page that you choose whether to submit.

The intel and translation overlays read the chat logs and game logs only; they never write to them, and private conversations are never read. Two optional features connect to other services:

- Pilot name checks: "Check pilot names online (ESI)" is on by default once you turn on the intel overlay. When an intel message received by the active character contains pilot names of two or more words that run together, the app sends those words, alone and in combinations of up to three, to CCP's ESI at `esi.evetech.net/universe/ids`. It does not send the sender, the channel or the rest of the message; your own character names are included only if someone typed them into an intel message. A name that stands alone as one word is never looked up. CCP sees your IP address and the `User-Agent` header, which contains the app version and the project URL. Turn the setting off on the Intel page to stop these requests. The app itself never contacts zKillboard: "Open in Browser" opens a character's zKillboard page in your browser, with only the character ID in the address.
- Chat translation (off by default): the text of messages received by the active client's character in your translation channels is sent to the model service chosen on the Translation page, together with the official names of the systems and ships they mention. Sender and channel names are not sent; "Test" sends one fixed sample sentence. The API key is stored only in the macOS Keychain, under the service `io.github.deletexiumu.eveopreview-macos.translation` with one item per service, and is sent only to that service. It never appears in the configuration file, the logs or problem reports. Public addresses must use `https`; `http` is accepted only for this Mac or the local network, for example Ollama. What the service does with the text is governed by its own terms.

Problem reports contain the settings of these features as numbers and switches (such as the channel count and the chosen service), but no channel names, system names, API addresses, model names, pilot names, chat text or keys.

The app stores data in these places. To uninstall completely, delete them along with the app and `~/Library/Application Support/EVE-O Preview/config.json`:

| Location | Contents |
| --- | --- |
| `~/Library/Logs/EVE-O Preview/` | App logs, about 5 MiB at most |
| `~/Library/Application Support/EVE-O Preview/session.json`, `state.json` | Session marker; update and diagnostics records; manual intel locations |
| `~/Library/Application Support/EVE-O Preview/Reports/` | Problem report zips you created, redacted (the 3 newest) |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | Downloaded update files, deleted after installing |
| `~/Library/Application Support/EVE-O Preview/pilot-names.json` | Pilot names and character IDs matched by ESI (public game data), kept for 30 days. Readable only by you (0600) and never included in problem reports; "Clear Name Cache" on the Intel page empties it. Names without a match are kept in memory for 6 hours only |
| `~/Library/Application Support/EVE-O Preview/translation-cache.json` | Original and translated message text, without sender or channel names. Readable only by you (0600) and never included in problem reports; "Clear Cache" on the Translation page empties it |
| Keychain items with the service `io.github.deletexiumu.eveopreview-macos.translation` | Your translation API keys, one per service; "Delete Key" on the Translation page removes the current one |

## Configuration file

The configuration is saved in `~/Library/Application Support/EVE-O Preview/config.json`. One file holds all profiles.

- Changes are saved automatically 0.5 seconds after you make them, and once more on quit.
- If the file is corrupt, it is renamed to `config.corrupt-<date-time>.json` and the app uses the default configuration.
- If the file comes from a newer version, the app runs with the default configuration, does not write to disk during that session, and does not overwrite the file.

The Profiles page has a "Show in Finder" button.

## Upstream features not ported

| Upstream feature | Reason |
| --- | --- |
| Frame-rate limiting and selective muting (Robin injection) | Upstream injects a DLL into Windows processes; macOS has no equivalent public mechanism. The Windows app limits the frame rate through the graphics driver instead (see [Windows](#windows)) |
| CPU affinity | Relies on Windows CPU Sets; Apple Silicon has no public API to pin a process to cores |
| Combat log Augments: damage numbers, DPS, repair amounts, system overlay, FC static data | A large separate subsystem outside "preview and switch"; only "flash when attacked" was ported |
| Themes, legacy UI, custom right-click menu styles | The macOS version follows the system appearance |
| Compatibility capture mode (`PrintWindow`) | ScreenCaptureKit is the only capture method |
| Low-level keyboard hook | Keyboard hotkeys use Carbon global hotkeys; a mouse event tap is created only when a mouse button is bound |

Regions with drag-and-drop docking, multi-select and group moves, undo, snap guides, importing Windows configurations, and launch at login are planned for after v1.

## Disclaimer

This tool only switches window focus. It does not broadcast input to multiple clients and does not read or modify game memory, the same boundary as upstream. The intel and translation overlays only read the log files that the client writes. Read the EVE Online End User License Agreement before using it.

The app connects to GitHub to check for and download updates. It connects to CCP's ESI and to a translation service only when you turn on those optional features, and sends only what [Privacy](#privacy) describes.

EVE Online and related logos are trademarks of CCP ehf. This project is not affiliated with or endorsed by CCP.

The app icon is a cartoon grim reaper supplied by the project maintainer. `shared/branding/make-icons.py` builds the macOS and Windows icons from `shared/branding/logo-source.jpg`. The icon contains no CCP trademarks or game art.
