# OkBrain macOS Agent

A macOS menu-bar agent that exposes screenshot capture, accessibility controls, and toggleable file editing over a local Unix domain socket. The Brain server connects to this socket via SSH forwarding and exchanges `OKB1` binary frames.

See [`protocol/01-macos-agent-ssh-socks-protocol.md`](protocol/01-macos-agent-ssh-socks-protocol.md) and [`protocol/02-macos-agent-file-editing.md`](protocol/02-macos-agent-file-editing.md) for the protocol specifications.

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

## File Editing

File editing is disabled by default. Enable or disable it from the app's **Settings → File Editing** switch.

Supported actions are `workspace.describe`, `fs.stat`, `fs.list`, `fs.read`, `fs.write`, `fs.patch`, and `fs.search`. File access is default-deny: enable **Settings → File Editing**, then add folder rules in **File Permissions**. A read or write rule applies to that folder and all nested paths unless a more specific child-folder rule overrides it. Requests provide an absolute `path`; access is allowed only when that path is inside an enabled permission rule. `fs.search` accepts either a directory or a single file path, symlink escapes are denied by default, and writes use SHA conflict checks plus atomic replacement.

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
| Socket not found | Check that the matching agent is running (`pgrep OkBrainMacOSAgent-Dev` for dev, `pgrep OkBrainMacOSAgent` for prod) |
