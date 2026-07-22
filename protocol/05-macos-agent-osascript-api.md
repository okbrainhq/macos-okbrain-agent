# 🍎 macOS Agent AppleScript (`osascript.run`) API

**Status:** Implemented in the macOS agent (socket-only, `OKB1` binary frames)
**Date:** 2026-07-22
**Protocol:** `okbrain.macos-agent.v3`
**Scope:** Let Brain coding agents run AppleScript / JXA snippets through the existing agent `.sock`, for app-specific commands the Accessibility API can't express (playback control, volume, Finder operations, dialogs, `do shell script`, etc.)

---

## 🎯 Goal

Give coding agents a single, high-level action to run AppleScript (or JavaScript for Automation / JXA) inside the logged-in GUI session:

- Pause/play Music, set system volume, control Finder, show dialogs
- Drive any scriptable app via its AppleScript dictionary
- Run JXA with `language: "javascript"`

The script is piped to `/usr/bin/osascript` over **stdin**, so multi-line scripts and embedded quotes need **no shell escaping** and there is **no argument-length limit**. Brain reaches the action over the same SSH-forwarded Unix socket used for screenshots, file editing, and `ax.*`.

---

## 🔐 Permission Gate

`osascript.run` itself has **no protocol-level permission gate** — it runs without Accessibility or Screen Recording permission, and `agent.status → capabilities` always lists `osascript.run`.

However, **controlling another app** via AppleScript requires macOS **Automation** (Apple Events / TCC) permission for that target app:

- First time the agent sends an Apple Event to a target app, macOS shows a consent prompt ("OkBrain Agent wants to control X").
- If not yet granted (or denied), the script fails with a **non-zero `exitCode`** and `stderr` mentioning `Not authorized to send Apple events to …` (underlying `errAEEventNotPermitted`, `-1743`). This is surfaced in the response payload — **not** as a protocol error envelope.
- To avoid surprise prompts mid-task, pre-authorize apps in the agent UI: **Settings → AppleScript App Access** (add apps, click **Request Access**). See the agent README.

Scripts that don't target another app (e.g. `return 1 + 1`, `do shell script "date"`) need no Automation permission.

---

## 🧩 Action

Standard request frame:

```json
{ "protocol": "okbrain.macos-agent.v3", "id": "req_1", "action": "osascript.run", "params": { ... } }
```

Response is a standard envelope (`ok`, `data`). No binary body.

### `osascript.run` — run an AppleScript / JXA snippet

| Param | Type | Required | Meaning |
| --- | --- | --- | --- |
| `script` | string | ✅ | The script source. Multi-line OK; embedded quotes need no escaping (piped via stdin). Empty/whitespace-only → `invalid_request`. |
| `language` | string | — | `"applescript"` (default) or `"javascript"` / `"jxa"`. Normalized case-insensitively. **Any other value falls back to AppleScript** (no error). |
| `timeout` | number | — | Seconds before a runaway script is terminated. `≤ 0` or non-finite → default **30**; clamped to max **300**. |

```json
{ "action": "osascript.run", "params": { "script": "tell application \"Music\" to pause" } }
```

```json
{
  "ok": true,
  "data": {
    "language": "applescript",
    "exitCode": 0,
    "stdout": "",
    "stderr": "",
    "timedOut": false
  }
}
```

Response `data` fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `language` | string | Normalized language actually run: `"applescript"` or `"javascript"`. |
| `exitCode` | number | `osascript` process exit code (`0` on success). Non-zero means the script errored or was denied — inspect `stderr`. |
| `stdout` | string | Captured standard output (the script's `return`/`log` output). |
| `stderr` | string | Captured standard error. On timeout, a note `osascript timed out after Ns` is appended. |
| `timedOut` | bool | `true` when the script was killed for exceeding `timeout`. |

### JXA example

```json
{ "action": "osascript.run", "params": { "language": "javascript", "script": "Application('Music').pause(); 'paused'" } }
```

### Multi-line AppleScript (no escaping needed)

```json
{
  "action": "osascript.run",
  "params": {
    "script": "tell application \"Finder\"\n  set fileList to name of every file of desktop\nend tell\nreturn fileList"
  }
}
```

---

## ❌ Error Codes

| Code | When |
| --- | --- |
| `invalid_request` | `script` missing/empty, or `osascript` failed to launch |

> Script-level failures (syntax errors, missing Automation permission, target app errors) are **not** protocol errors — they come back as `ok: true` with a non-zero `exitCode` and a descriptive `stderr`. Check `exitCode` before trusting `stdout`.

---

## 📌 Usage Rules for AI Agents

1. **Always check `exitCode`.** `ok: true` only means the action ran; `exitCode != 0` means the script failed. Read `stderr` for the reason.
2. **Automation permission shows up as a script failure, not a protocol error.** If `stderr` says `Not authorized to send Apple events to <App>`, the user must grant Automation access (agent Settings → AppleScript App Access, or System Settings → Privacy & Security → Automation).
3. **Prefer `osascript.run` for app-specific commands** the AX API can't express (Music playback, `set volume`, Finder file ops, `display dialog`). Prefer `ax.*` for generic UI element manipulation (clicking buttons, reading fields).
4. **No shell escaping required.** Send the raw script in `script` — don't wrap it in `osascript -e '…'` or add shell quotes; the agent pipes it via stdin.
5. **Bound long work with `timeout`.** Default is 30 s; raise it (max 300) only for scripts that legitimately run long. On timeout, `timedOut: true`.
6. **`do shell script` runs with the agent's privileges** and can do anything the shell can — treat script content with the same caution as shell commands.

---

## 🧰 Brain / OKBrain Integration Guide

Mirror `take_screenshot` / `macos_ax`: Brain opens one connection per request to the forwarded socket, sends one `OKB1` frame, reads one frame back. Reuse the existing frame codec — this action is JSON-only (`bodyLength: 0`).

Suggested tool surface (names up to Brain):

| Brain tool | Agent action | Key params |
| --- | --- | --- |
| `macos_osascript_run` | `osascript.run` | `script`, `language?`, `timeout?` |

### Guidance for tool implementers

- Gate the tool on `agent.status → capabilities` containing `osascript.run` (always present).
- Default the client-side timeout slightly above the requested `timeout` (agent bounds execution to ≤ 300 s).
- Surface `exitCode`, `stdout`, `stderr`, and `timedOut` to the model; don't treat non-zero `exitCode` as a transport failure.
- Never persist script source or output into chat events beyond normal tool-result handling; treat `do shell script` output like shell output.

---

## 🧪 Verification

`scripts/verify_protocol.swift` covers `osascript.run` with a fake osascript service (envelope shape, `script`/`language`/`timeout` pass-through, capability listing, and missing-`script` validation). Run everything with:

```bash
./scripts/test.sh
```

For a live smoke test on a Mac with the dev agent running:

```bash
./scripts/build.sh && ./scripts/run.sh
printf '%s' '{"protocol":"okbrain.macos-agent.v3","id":"1","action":"osascript.run","params":{"script":"return 1 + 1"}}' \
  | { python3 - <<'PY'
import json, socket, struct, sys
payload = sys.stdin.buffer.read()
frame = b"OKB1" + struct.pack(">I", len(payload)) + struct.pack(">Q", 0) + payload
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/okbrain-macos-agent-dev.sock")
s.sendall(frame)
magic = s.recv(4); hlen = struct.unpack(">I", s.recv(4))[0]; blen = struct.unpack(">Q", s.recv(8))[0]
print(json.dumps(json.loads(s.recv(hlen)), indent=2))
PY
}
```
