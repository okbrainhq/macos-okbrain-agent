# OkBrain macOS Agent

A macOS menu-bar agent that exposes screenshot capture, accessibility (AX) GUI control with per-app guardrails, a curated macOS function catalog, and toggleable file editing over a local Unix domain socket. The Brain server connects to this socket via SSH forwarding and exchanges `OKB1` binary frames.

See [`protocol/01-macos-agent-ssh-socks-protocol.md`](protocol/01-macos-agent-ssh-socks-protocol.md), [`protocol/02-macos-agent-file-editing.md`](protocol/02-macos-agent-file-editing.md), [`protocol/04-macos-agent-accessibility-api.md`](protocol/04-macos-agent-accessibility-api.md), [`protocol/07-macos-agent-guardrails-and-functions.md`](protocol/07-macos-agent-guardrails-and-functions.md), and [`protocol/08-macos-agent-sandboxed-shell.md`](protocol/08-macos-agent-sandboxed-shell.md) for the protocol specifications. Raw `osascript.run` was retired and is no longer a protocol capability.

## Requirements

- macOS 14.0+
- Xcode 15+ / Swift 5.9+
- Screen Recording & Accessibility permissions
- No Homebrew dependency for WebP: official libwebp `cwebp` 1.5.0 is vendored for macOS arm64 and bundled by `scripts/build.sh` (`MACOS_AGENT_CWEBP_PATH` can override it)

## Quick Start

### 1. Create a code-signing certificate (once)

Without this, macOS forgets Screen Recording / Accessibility permissions after every rebuild.

```bash
./scripts/setup-codesign.sh
```

### 2. Build

```bash
./scripts/build.sh          # dev: dist/OkBrainMacOSAgent-Dev.app
./scripts/build.sh --prod   # prod: dist/OkBrainMacOSAgent.app
```

The default build is the isolated dev app. Prod keeps the stable bundle id and socket path used by the installed agent.

| Mode | Command | App bundle | Bundle ID | Socket path | State key |
| --- | --- | --- | --- | --- | --- |
| Dev | `./scripts/build.sh` or `--dev` | `dist/OkBrainMacOSAgent-Dev.app` | `com.okbrain.macos-agent.dev` | `/tmp/okbrain-macos-agent-dev.sock` | `.okbrain-macos-agent-dev` |
| Prod | `./scripts/build.sh --prod` | `dist/OkBrainMacOSAgent.app` | `com.okbrain.macos-agent` | `/tmp/okbrain-macos-agent.sock` | `.okbrain-macos-agent` |

Both app plists include `AppEnvironment` and `AppStateDirectoryName`. `MACOS_AGENT_SOCKET_PATH` still overrides the default socket path for either mode.

### 3. Run

```bash
./scripts/run.sh          # opens dev with open -n
./scripts/run.sh --prod   # opens prod
```

The agent starts a Unix socket for the selected mode (`/tmp/okbrain-macos-agent-dev.sock` for dev, `/tmp/okbrain-macos-agent.sock` for prod) and listens for `OKB1` binary-framed requests. Screenshots are encoded locally as WebP quality 80 and returned as binary response bodies. By default, it starts a per-process `ProcessInfo` activity with idle system sleep disabled while the agent is active (display sleep is allowed, so the screen can turn off normally), without changing global `pmset` settings or requiring sudo.

## Accessibility (AX) API and App & Global Access

When Accessibility permission is granted, the agent serves `ax.*` GUI actions for app discovery, inspection, and control. Access is **default-deny**: every app read needs explicit **Observe** or **Control** access, while writes need **Control** (which includes Observe). Every app target is resolved to a bundle ID—or a captured frontmost PID for untargeted synthetic input—then rechecked immediately before control is sent. The local popup asks for the exact level and offers Allow Once, Always Allow Observe/Control, or Not Now; unresolved targets fail closed without prompting or queuing. Manage grants in **Computer Use → App & Global Access**: global capability categories are always in the picker, while installed apps are selected through a native `.app` file browser. Timed-out requests remain in a sanitized, bounded menu-bar pending list for a later decision.

The curated function catalog also includes permission-gated, coordinate-free GUI functions. `menubar.list`, `menubar.open`, and `menubar.click` drive status-item popup menus; `menubar.open` accepts an optional `title` (opening by `appName` alone when the app has exactly one status item) and returns the available status items when a title does not match. `menu.list` and `menu.click` read and press application menu items by title or path (for example `View > Enter Full Screen`). `window.list`, `window.close`, `window.minimize`, `window.zoom`, and `window.raise` inspect and control windows through Accessibility button presses and `AXRaise`—never raw screen coordinates. `display.info` and `window.frame` remove coordinate-system guesswork for computer-use agents: `display.info` reports every connected display's geometry in screen points plus its backing scale (pixels per point), and `window.frame` returns a window's position and size in global screen points (the AX top-left origin space that `CGEvent` clicks use). All targeting parameters are forgiving (trimmed, case-insensitive substring match) and failures list the candidate items or windows. These functions require macOS Accessibility permission; discover their schemas through `functions.list`.

See [`protocol/04-macos-agent-accessibility-api.md`](protocol/04-macos-agent-accessibility-api.md) and [`protocol/07-macos-agent-guardrails-and-functions.md`](protocol/07-macos-agent-guardrails-and-functions.md) for the full targeting and guardrail rules.

## Curated macOS Functions

The agent serves `functions.list`, `functions.run`, and `functions.propose`. The catalog replaces raw scripting with validated, named operations for apps, system volume/clipboard/battery/Wi-Fi, media, browsers, Finder, notifications, and branded dialogs. Read functions are catalog-enabled by default but still require explicit **Observe** permission for their app or global category. Write functions and elevated `browser.run-javascript` also require their per-function local toggles plus **Control** permission. Global categories—Application Discovery, Menu Bar Extras, System Audio, Clipboard, Power & Battery, Network Information, Notifications, User Dialogs, and Displays—are managed in the same App & Global Access picker.

Functions that use Apple Events preflight macOS **Automation** permission for their target app. Grant or revoke that permission in System Settings → Privacy & Security → Automation. Proposals appear in the local Functions inbox; approval requires a full-source review and submitted SHA-256 digest. Stored templates bind one reviewed literal app bundle ID, reject dynamic/multi-target and shell/admin/scripting-addition constructs, escape fixed placeholders, and run under bounded output and timeout handling.

## File Editing

File editing is disabled by default. Enable or disable it from the app's **Settings → File Editing** switch.

Supported actions are `workspace.describe`, `fs.stat`, `fs.list`, `fs.read`, `fs.write`, `fs.patch`, and `fs.search`. File access is default-deny: enable **Settings → File Editing**, then add folder rules in **File Permissions**. A read or write rule applies to that folder and all nested paths unless a more specific child-folder rule overrides it. Requests provide an absolute `path`; access is allowed only when that path is inside an enabled permission rule. `fs.search` accepts either a directory or a single file path, symlink escapes are denied by default, and writes use SHA conflict checks plus atomic replacement.

## Sandboxed Shell (Phases 1–4)

Shell access has its own **Shell Access** sidebar tab and **Settings → Shell Access** switch (default **off**, independent of File Editing). When Shell Access is enabled with at least one folder rule, the agent serves `sh.exec` and `sh.status`. `sh.exec` runs a command string inside a per-execution Seatbelt (`sandbox-exec`) sandbox derived from the live folder rules; `sh.status` reports the effective policy. The Shell Access tab shows the same default-deny folder-rule manager as the File Permissions tab — the sandbox is scoped to those shared rules.

- **File writes are kernel default-deny** outside read-write rules and build temp dirs (`TMPDIR`, `/private/tmp`). Read-only rules can be read but not written.
- **An immutable Block base** always denies writes to `/System`, `/private/etc`, `/private/var/db`, etc., all TCC/system-policy databases, `~/.ssh` and `~/Library/Keychains`, plus `authorization-right-obtain`, `nvram*`, mount/unmount, setugid, and privileged Mach services. No rule can relax these.
- **Three-tier pre-flight classification** (defense-in-depth): dangerous invocations (`rm -rf /`, `curl|sh`, `dd of=/dev/…`) and privileged tools (`sudo`, `su`, `launchctl`) are hard **Block** (`shell_permission_blocked`); out-of-tree absolute-path executables and inline `osascript … tell application "X"` automation are **Ask** — they prompt locally (Allow Once / Always Allow / Not Now) and return `shell_permission_required` until approved; trusted prefixes and in-rule binaries run silently.
- **Shell Access UI + audit.** The Shell Access tab manages capability rules (process-exec path prefixes, Apple-event targets), resolves the pending-request inbox, and shows a bounded audit log (command, cwd, classification, decision, exit code — never output contents).
- **Network is fully open in v1** and reads/exec are open at the kernel level; exec scoping is agent-enforced. See [`protocol/08-macos-agent-sandboxed-shell.md`](protocol/08-macos-agent-sandboxed-shell.md) §13 for the as-built notes and the remaining Brain-routing phase.
- **Known limitation — nested sandboxes.** macOS refuses `sandbox_apply` from inside any deny-based profile, so tools that spawn their own `sandbox-exec` (e.g. SwiftPM) fail. Re-run with the tool's sandboxing disabled (`swift build --disable-sandbox`, `swift test --disable-sandbox`); the agent sandbox still confines the command. `sh.exec` detects this signature and returns `shell_denied_by_sandbox` with operation `nested-sandbox-apply` and guidance.

`sh.exec` params: `command` (required), `cwd` (required, must resolve inside a read-write rule), `env` (allow-listed keys only), `timeoutSeconds` (capped). Output is capped at 1 MiB. Error codes: `shell_permission_required`, `shell_permission_blocked`, `shell_denied_by_sandbox`, `shell_timeout`, `shell_output_limit`.

## Testing

Run the package, protocol, patch-engine, shell, and bundle checks with:

```bash
./scripts/test.sh
```

This repository uses executable Swift verifiers for protocol and patch coverage, so `./scripts/test.sh` is the intended test command rather than `swift test`.

## Permissions

The app requires two macOS privacy permissions:

- **Screen Recording** — for `screenshot.capture`
- **Accessibility** — for the `ax.*` GUI control actions

These are requested automatically on first launch. If you rebuild without code signing, you must re-grant them every time.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `ambiguous matches` during codesign | `build.sh` signs with the resolved SHA-1 identity hash; run `setup-codesign.sh` if the identity is missing |
| Build prints `unsigned` after setup | Run `setup-codesign.sh` again and check that it prints an `Identity:` hash |
| Permission dialogs keep appearing | Ensure the app is signed (`build.sh` prints `Signed ...`) |
| Socket not found | Check that the matching agent is running (`pgrep OkBrainMacOSAgent-Dev` for dev, `pgrep OkBrainMacOSAgent` for prod) |
| Socket file exists but every call fails with `Connection refused` (errno 61) | A request handler hung and wedged the accept loop (historical bug). The listener now handles each client off the accept loop and auto-restarts; restart the agent and check the `socket-server` log category. See [Socket listener diagnostics](#socket-listener-diagnostics). |

### Socket listener diagnostics

The socket server (`Sources/OkBrainMacOSAgentCore/Socket/UnixSocketServer.swift`) is built so the
listener can never silently die:

- The accept loop runs on its own serial queue and **only** accepts connections. Each accepted
  client is dispatched to a concurrent queue, so a slow, hung, or malicious request handler can no
  longer block `accept()`. (Previously `handleClient` ran inline on the accept loop; one hung
  request filled the listen backlog and the kernel returned `ECONNREFUSED` to every client, making
  the whole agent appear dead while the process and socket file still existed.)
- Transient `accept` errors are logged and skipped; fatal errors bubble up to a supervisor that logs
  loudly and rebinds with backoff.
- Per-connection reads have a timeout, so a silent/half-open client cannot hold a handler forever.
- Notable failures are logged to the unified log (subsystem `com.okbrain.macos-agent`, category
  `socket-server`).

If the agent ever appears unresponsive again, diagnose with:

```bash
PID=$(pgrep -x OkBrainMacOSAgent)            # or OkBrainMacOSAgent-Dev for dev
lsof -p "$PID" | grep okbrain                 # is the listening fd present?
sample "$PID" 1 -file /tmp/agent.txt          # is the accept loop blocked in accept(), or a handler hung?
log show --last 5m --predicate 'subsystem == "com.okbrain.macos-agent"' --info | grep socket-server
```

A healthy idle agent shows its `com.okbrain.macos-agent.socket-server.accept` thread blocked in
`accept()`. If a single `functions.run`/`ax.*` handler is hung (for example waiting on a permission
prompt), only that one client is affected; `agent.status` and other calls still succeed. Approve the
pending permission in the agent UI (or via the persisted `axPermissionState` rules) to unblock it.
