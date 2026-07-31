# 🖥️ macOS Agent `.sock` Protocol over SSH

**Status:** Implemented socket-only binary-frame protocol for the separate macOS agent app  
**Date:** 2026-06-05  
**Protocol:** `okbrain.macos-agent.v3`  
**Scope:** Brain Code Project screenshot/control access to a macOS GUI session

---

## 🎯 Goal

Brain should **not install, update, or manage** the macOS GUI agent. A separate macOS app owns:

- Installing/updating the local macOS agent
- Requesting Screen Recording / Accessibility permissions
- Running in the logged-in GUI session
- Creating and serving a local Unix domain socket (`.sock`)

Brain detects and calls that `.sock` through the existing Code Project SSH connection.

---

## ✅ Transport Decision

Use **one transport only**:

```text
Brain server → SSH → remote Unix domain socket → macOS GUI app/agent
```

- No custom `agentctl` CLI.
- No Brain-installed Python client script.
- No HTTP loopback port.
- No SOCKS proxy mode.
- The GUI app owns the socket lifecycle and permissions.

### Can Brain access a remote `.sock` via SSH?

Yes. SSH can bridge the remote Unix socket with StreamLocal forwarding:

```bash
ssh -N -L /tmp/okbrain-local.sock:/tmp/okbrain-macos-agent.sock user@mac
```

Brain then connects to `/tmp/okbrain-local.sock` locally and sends one binary-framed request per connection. This is **not SOCKS**; SOCKS is a TCP proxy and does not directly address a Unix domain socket.

---

## 📍 Socket Path

Current default:

```text
/tmp/okbrain-macos-agent.sock
```

Brain can override this with:

```text
MACOS_AGENT_SOCKET_PATH=/path/to/agent.sock
```

Rules:

- The socket must be owned by the logged-in GUI user.
- Permissions should be `0600`.
- The GUI app must remove stale socket files before binding.
- The socket speaks one **binary frame request** and one **binary frame response** per connection.

---

## 📦 Binary Frame

All requests and responses use this frame layout:

```text
0..3    magic          ASCII "OKB1"
4..7    headerLength   uint32 big-endian
8..15   bodyLength     uint64 big-endian
16..N   header JSON    UTF-8 JSON, exactly headerLength bytes
N..end  body bytes     exactly bodyLength bytes
```

### Request Frame

- `bodyLength` is currently `0`.
- The header JSON contains the RPC request.

```json
{
  "protocol": "okbrain.macos-agent.v3",
  "id": "req_01HZ...",
  "action": "agent.status",
  "params": {}
}
```

### Success Response Frame

- The response header JSON contains the envelope.
- For non-binary actions, `bodyLength` is `0`.
- For `screenshot.capture`, the body is raw WebP bytes.

```json
{
  "protocol": "okbrain.macos-agent.v3",
  "id": "req_01HZ...",
  "ok": true,
  "data": {}
}
```

### Error Response Frame

Errors have `bodyLength: 0`.

```json
{
  "protocol": "okbrain.macos-agent.v3",
  "id": "req_01HZ...",
  "ok": false,
  "error": {
    "code": "permission_denied",
    "message": "Screen Recording permission is not granted"
  }
}
```

---

## 🧩 Actions

### `agent.status`

Checks whether the macOS agent is installed, running, reachable, and permissioned.

Expected `data`:

```json
{
  "installed": true,
  "running": true,
  "available": true,
  "version": "2.0.0",
  "socketPath": "/tmp/okbrain-macos-agent.sock",
  "protocolVersions": ["okbrain.macos-agent.v3"],
  "permissions": {
    "screenRecording": "granted",
    "accessibility": "unknown"
  },
  "capabilities": [
    "screenshot.full",
    "screenshot.window",
    "screenshot.region",
    "screenshot.cursor",
    "screenshot.webp",
    "screenshot.binary"
  ]
}
```

### `screenshot.capture`

Captures the GUI, converts it locally to **lossy WebP quality 80** via the bundled official libwebp `cwebp` 1.5.0 binary, and returns raw WebP bytes in the binary response body. The app resolves `cwebp` from `MACOS_AGENT_CWEBP_PATH`, the app bundle resources, or the vendored repo path during source runs.

```json
{
  "protocol": "okbrain.macos-agent.v3",
  "id": "req_capture_1",
  "action": "screenshot.capture",
  "params": {
    "mode": "full",
    "format": "webp",
    "quality": 80,
    "includeCursor": false
  }
}
```

Response header `data`:

```json
{
  "mimeType": "image/webp",
  "encoding": "binary",
  "byteLength": 123456,
  "width": 3024,
  "height": 1964
}
```

Response body:

```text
<exactly byteLength raw WebP bytes>
```

Modes:

| Mode | Required params | Notes |
| --- | --- | --- |
| `full` | none | Primary display; set `includeCursor: true` to include the pointer |
| `window` | `appName` or `windowId` | Set `includeCursor: true` to include the pointer if it is within the capture |
| `region` | `rect: { x, y, width, height }` | Screen coordinates; `includeCursor` is not supported |

### `permissions.status`

Returns permission state without attempting capture.

### `agent.info`

Returns version/build details for diagnostics. Expected transport is:

```json
{
  "transport": "ssh-unix-socket-binary-frame"
}
```

---

## 🔐 Security Rules

- Brain may only connect to hosts allowed by `CODE_PROJECT_SSH_HOSTS`.
- The macOS agent must bind only to a user-owned Unix socket.
- The web app must not run arbitrary installer scripts on the Mac.
- Brain must use a fixed socket bridge command, not arbitrary user-provided shell.
- Enforce response body size limits for screenshots.
- Time out screenshot calls quickly, default 15 seconds.
- Never store screenshot binary payloads in SQLite chat events.
- Store uploaded screenshots as WebP files and expose only `/uploads/...` URLs.

---

## 🧪 Brain-side E2E Expectations

- Settings page shows a **macOS Agent Installed / Not Installed** status button for Darwin Code Projects.
- Status button calls `GET /api/code-projects/:id/check-macos-agent`.
- Status response includes `transport: "ssh-unix-socket-binary-frame"` and `socketPath`.
- Screenshot test captures through the `.sock` protocol, receives WebP bytes directly, uploads/stores them, and returns `fileUri`.
- Chat tool result stores `fileUri`, `mimeType`, and `description`; it must not persist raw image bytes.
- Mock socket daemon must emit/parse `OKB1` binary frames.

## Listener resilience (ops note)

The agent's UNIX socket listener is hardened so a single bad or hung request cannot take down the
whole endpoint:

- Each accepted connection is handled on a concurrent queue; the accept loop never runs request
  handling code, so a hung handler (e.g. a `functions.run` waiting on a permission prompt) cannot
  wedge `accept()` and cause `ECONNREFUSED` for other clients.
- Transient `accept` errors are skipped; fatal errors trigger a supervised rebind with backoff.
- Per-connection reads time out, and failures are logged to the unified log under subsystem
  `com.okbrain.macos-agent`, category `socket-server`.

If `agent.status` is refused even though `/tmp/okbrain-macos-agent.sock` exists, restart the agent
and see the "Socket listener diagnostics" section in `README.md`.
