# OkBrain macOS Agent

A macOS menu-bar agent that exposes screenshot capture, accessibility controls, and v2 root-scoped file editing over a local Unix domain socket. The Brain server connects to this socket via SSH forwarding.

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

File editing is disabled by default. Enable it by approving one or more absolute project roots before launch:

```bash
MACOS_AGENT_ALLOWED_ROOTS="/Users/me/projects/app|read-write;/Users/me/projects/docs|read-only" ./scripts/run.sh
```

Supported v2 actions are `workspace.describe`, `fs.stat`, `fs.list`, `fs.read`, `fs.write`, `fs.patch`, and `fs.search`. All paths are root-relative, canonicalized, symlink escapes are denied by default, and writes use SHA conflict checks plus atomic replacement.

Optional limits:

- `MACOS_AGENT_FILE_EDITING_MODE=read-only|read-write|disabled`
- `MACOS_AGENT_MAX_READ_BYTES` (default `1048576`)
- `MACOS_AGENT_MAX_WRITE_BYTES` (default `5242880`)
- `MACOS_AGENT_MAX_SEARCH_RESULTS` (default `200`)
- `MACOS_AGENT_MAX_LIST_ENTRIES` (default `1000`)

## Permissions

The app requires two macOS privacy permissions:

- **Screen Recording** — for `screenshot.capture`
- **Accessibility** — for future window/region targeting

These are requested automatically on first launch. If you rebuild without code signing, you must re-grant them every time.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `ambiguous matches` during codesign | Run `setup-codesign.sh` again; it removes duplicate certificates |
| Permission dialogs keep appearing | Ensure the app is signed (`build.sh` prints `Signed ...`) |
| Socket not found | Check that the agent is running (`pgrep OkBrainMacOSAgent`) |
