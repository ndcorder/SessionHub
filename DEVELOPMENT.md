# SessionHub development plan

The next release should be a dependable daily companion for managing iTerm2
projects from either the menu bar or a floating panel. PR #2 remains the separate
search/navigation contribution; new work builds on it on `feat/sessionhub-complete`.

## Release requirements

- [x] Recover from iTerm2 exit/restart, socket closure, timeout, and failed handshakes.
      Serialize connection state; bound request waits; reject malformed frames and
      protobuf messages without crashes. Cover these behaviors with transport tests.
- [x] Show the actual active session and useful available context (directory, host,
      running job). Rename sessions without changing their project/profile grouping.
      Report failed actions; retain the last successful snapshot during transient errors.
- [ ] Create windows, tabs, and split panes from available profiles, including when
      no sessions exist. Provide explicit confirmation before closing a session.
- [ ] Keyboard navigation and shortcuts, persistent favorite/collapsed projects,
      sorting, session counts, and clear loading/offline/empty/search states.
- [ ] Optional floating panel with remembered position and a keyboard shortcut;
      settings for refresh interval, appearance, details, and launch at login.
- [ ] Onboarding/help and actionable connection status; bounded, privacy-conscious
      diagnostics; correct installation/build documentation.
- [ ] Meaningful automated tests, repeatable demo/QA mode, macOS CI, release build,
      signature verification, and visual checks of all major interface states.

## Verification log

- Transport: 10 automated tests pass, covering reconnect after EOF, stale callbacks,
  shared handshake waiters, handshake rejection/timeout, pending-request timeouts,
  server error routing, fragmentation/ping, malformed lengths and protobuf overflow.
- Baseline: PR #2 is open without feedback. Worktree was clean at `7a51556`.
- Automated suite: 22 tests pass, including session state, preferences, snapshot
  metadata, and launch-at-login state handling. Production app builds and its code
  signature verifies successfully.
- Live iTerm2 smoke check passed after API access approval: detected 9 existing
  sessions, 13 profiles, the active session, and working directories; disconnected
  and reconnected successfully. Created a disposable shell, renamed it without
  changing its profile, activated it, split it, and closed both test sessions.
  Confirmed cleanup and restored the previously active session.
- Search UI was previously verified with sample data. Remaining visual checks and
  hosted CI still need verification before the release requirements are complete.
- Additional demo checks: empty project list renders correctly, pinned projects
  remain visible with no open sessions, and Command–Comma opens settings without
  first opening the More menu. The settings accessibility tree exposes every section
  and the guide button.
- Native UI automation repeatedly lost its connection with `Sky Computer Use native
  pipe closed before response` while opening the guide, including after a tool reset.
  The demo process remained running and no new app crash report appeared. Guide,
  offline/connection-loss layout, rename autofocus, and production floating-panel
  shortcut/position checks remain pending; the interface PR must stay a draft.

## Review boundaries

Keep reliability/protocol changes, session-management features, and interface/settings
changes in separate commits suitable for follow-up PRs. Do not merge PR #2 or publish
a release as part of local development.
