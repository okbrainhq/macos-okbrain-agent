# OkBrain macOS Agent

A macOS menu-bar agent that exposes screenshot capture and accessibility controls over a local Unix domain socket. The Brain server connects to this socket via SSH forwarding.

See [`macos-agent-ssh-socks-protocol.md`](macos-agent-ssh-socks-protocol.md) for the full protocol specification.

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
