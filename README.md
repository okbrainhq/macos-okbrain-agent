# OkBrain macOS Agent

A macOS menu-bar agent that exposes screenshot capture, accessibility controls, and toggleable v2 file editing over a local Unix domain socket. The Brain server connects to this socket via SSH forwarding.

See [`protocol/01-macos-agent-ssh-socks-protocol.md`](protocol/01-macos-agent-ssh-socks-protocol.md) and [`protocol/02-macos-agent-file-editing.md`](protocol/02-macos-agent-file-editing.md) for the protocol specifications.

## Requirements

- macOS 14.0+
- Xcode 15+ / Swift 5.9+
- Screen Recording & Accessibility permissions

## Quick Start

### 1. Create a code-signing certificate (once)

Without this, macOS forgets Screen Recording / Accessibility permissions after every rebuild.

```bash
./scripts/setup-codesign.sh
```

### 2. Build

```bash
./scripts/build.sh
```

Output: `dist/OkBrainMacOSAgent.app`

### 3. Run

```bash
./scripts/run.sh
```

The agent starts a Unix socket at `/tmp/okbrain-macos-agent.sock` and listens for JSON requests. By default, it starts a per-process `ProcessInfo` activity with idle display/system sleep disabled while the agent is active, so remote screenshots stay available without changing global `pmset` settings or requiring sudo.

## File Editing

File editing is disabled by default. Enable or disable it from the app's **Settings → File Editing** switch.

Supported v2 actions are `workspace.describe`, `fs.stat`, `fs.list`, `fs.read`, `fs.write`, `fs.patch`, and `fs.search`. File access is default-deny: enable **Settings → File Editing**, then add folder rules in **File Permissions**. A read or write rule applies to that folder and all nested paths unless a more specific child-folder rule overrides it. Requests still provide an absolute `root`, paths stay root-relative, `fs.search` accepts either a directory or a single file path, symlink escapes are denied by default, and writes use SHA conflict checks plus atomic replacement.

## Testing

Run the package, protocol, patch-engine, shell, and bundle checks with:

```bash
./scripts/test.sh
```

This repository uses executable Swift verifiers for protocol and patch coverage, so `./scripts/test.sh` is the intended test command rather than `swift test`.

## Permissions

The app requires two macOS privacy permissions:

- **Screen Recording** — for `screenshot.capture`
- **Accessibility** — for future window/region targeting

These are requested automatically on first launch. If you rebuild without code signing, you must re-grant them every time.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `ambiguous matches` during codesign | `build.sh` signs with the resolved SHA-1 identity hash; run `setup-codesign.sh` if the identity is missing |
| Build prints `unsigned` after setup | Run `setup-codesign.sh` again and check that it prints an `Identity:` hash |
| Permission dialogs keep appearing | Ensure the app is signed (`build.sh` prints `Signed ...`) |
| Socket not found | Check that the agent is running (`pgrep OkBrainMacOSAgent`) |
