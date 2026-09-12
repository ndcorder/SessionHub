# SessionHub

A native macOS companion for iTerm2. Find the right project, window, tab, or pane from your menu bar, or keep a floating session panel beside your work.

Requires **macOS 14 or later** and **iTerm2 with its Python API enabled**. SessionHub itself does not need Python, a package manager at runtime, or Automation permission.

## What it does

- Groups sessions by iTerm2 profile, with stable project colors and persistent pin/collapse preferences.
- Searches project and session names, folders, hosts, jobs, and available branch names. Combine words such as `website server`.
- Marks the actual active session and shows working-directory and foreground-job details.
- Opens new windows and tabs from any available profile, including projects with no open sessions.
- Renames sessions, splits panes right or below, copies directories/session IDs, and confirms before closing sessions.
- Provides keyboard navigation, numbered session shortcuts, sorting by project/recent usage/active session, and a pinned-project filter.
- Offers a resizable floating panel with a remembered position and a global shortcut.
- Includes appearance, refresh-frequency, menu-bar count, and launch-at-login settings.
- Recovers from lost connections, coalesces refreshes, retains the last successful list during temporary outages, and reports failed actions.

## Build and install

```bash
git clone https://github.com/gregleo12/SessionHub.git
cd SessionHub
./build.sh
cp -R build/SessionHub.app /Applications/
open /Applications/SessionHub.app
```

The build requires the Xcode command-line tools. It builds for the current Mac's architecture and signs the bundle locally with an ad-hoc identity. To use your own signing identity, set `SESSIONHUB_SIGNING_IDENTITY` when running the build script.

To update an installed copy, quit SessionHub before replacing it. Keep the app in a stable location, such as `/Applications`, before enabling **Launch at login** in its settings.

## Connect and organize

1. In **iTerm2 → Settings → General → Magic**, enable **Python API**.
2. Open SessionHub. Allow API access if iTerm2 prompts, then use **Reconnect** if necessary.
3. Create an iTerm2 profile per project under **Settings → Profiles**. Set its name and initial working directory.
4. Pin your frequent projects in SessionHub. Use **New** to start a window or tab with a profile, or the plus beside a project to add a session there.

A setup guide is available under **More → Setup & Shortcuts**. SessionHub uses iTerm2's local Unix socket and does not change your shell configuration.

Directory information depends on what iTerm2 knows. Remote host and directory details work best with [iTerm2 shell integration](https://iterm2.com/documentation-shell-integration.html). Branch names appear when your shell supplies the `user.gitBranch` session variable; SessionHub does not run Git commands in your terminals.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Control–Option–Command–Space | Show or hide the floating panel |
| Command–F | Focus search |
| Up / Down | Select a search result |
| Return | Activate the selected result |
| Command–1 through Command–9 | Activate the corresponding visible session |
| Escape | Clear search or cancel renaming |
| Command–R | Refresh |
| Command–Comma | Settings |

Except for the panel shortcut, shortcuts apply while the SessionHub window or menu is focused. The global shortcut uses macOS hot-key registration and does not require Accessibility or input-monitoring permission. Settings reports a conflict if another application already registered that combination.

## Development and verification

```bash
swift test                  # Protocol, transport, store, preferences, and demo tests
./build.sh                  # Release build and signature verification
./build.sh --demo --debug    # Separate app using sample sessions
open build/SessionHubDemo.app
Tools/live-smoke.sh          # Read-only live snapshot and reconnect check
Tools/live-smoke.sh --actions # Create, rename, activate, split, and close test shells
```

The demo opens a regular window containing the same session interface. Its **Demo** menu exercises connected, empty, offline, and connection-loss states. Rename, create, split, activate, and close operate on sample data. Demo preferences are separate, and launch-at-login/global shortcuts are disabled. Use this mode for screenshots and interface testing without touching real terminals.

Live checks require iTerm2 API access; allow the prompt if shown. The action check opens disposable `/bin/zsh -f` sessions, closes the sessions it created, and restores the previously active session. It does not send commands to existing sessions.

GitHub Actions runs tests and packages a signed app on macOS 14 and 15. Build artifacts are local/CI builds, not notarized distribution releases.

## Architecture

- SwiftUI views share a main-actor observable store between the menu and panel.
- Async API requests use a serialized Network.framework Unix-socket transport.
- A small WebSocket/protobuf implementation validates framing, bounded lengths, responses, and request statuses.
- Polling uses a configurable interval (three seconds by default), bounded metadata-request concurrency, and one refresh at a time. Sleep pauses polling; wake reconnects.
- UserDefaults stores appearance, project pin/collapse choices, and up to 100 recently activated session IDs/timestamps. Terminal output and session snapshots are not persisted.
- Diagnostic logging uses the bounded macOS unified log. SessionHub does not read terminal scrollback or send session information to a remote server.

## Contributing

Focused pull requests are welcome. Include the user-visible behavior, relevant regression tests, and any live-iTerm2 checks performed. The demo is available for interface QA. Integration changes should be checked against the [official iTerm2 API](https://iterm2.com/python-api/) and [protobuf schema](https://github.com/gnachman/iTerm2/blob/master/proto/api.proto).

## License

MIT
