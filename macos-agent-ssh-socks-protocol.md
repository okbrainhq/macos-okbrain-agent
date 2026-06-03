# 🖥️ macOS Agent .sock Protocol over SSH

**Status:** Proposed socket-only protocol for the separate macOS agent app  
**Date:** 2026-06-02  
**Scope:** Brain Code Project screenshot/control access to a macOS GUI session

---

## 🎯 Goal

Brain should **not install, update, or manage** the macOS GUI agent. A separate macOS app owns:

- Installing/updating the local macOS agent
- Requesting Screen Recording / Accessibility permissions
- Running in the logged-in GUI session
- Creating and serving a local Unix domain socket (`.sock`)

Brain only detects and calls that `.sock` through the existing Code Project SSH connection.

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

Yes. SSH does not magically expose the remote Unix socket, but OpenSSH can bridge it with StreamLocal forwarding:

```bash
ssh -N -L /tmp/okbrain-local.sock:/tmp/okbrain-macos-agent.sock user@mac
```

Brain then connects to `/tmp/okbrain-local.sock` locally and sends the v1 JSON request. Current Brain code opens this forwarding socket briefly per request and closes it after the response. This is **not SOCKS**; SOCKS is a TCP proxy and does not directly address a Unix domain socket.

---

## 🧭 Roles

| Component | Responsibility |
| --- | --- |
| Brain server | Stores Code Project SSH host, checks status, invokes screenshot requests, uploads processed images |
| SSH transport | Secure path from Brain to the Mac; no public agent port required |
| macOS app / agent | Runs in GUI user session, owns the `.sock`, captures screen, returns protocol responses |
| Unix socket | User-owned local IPC endpoint, e.g. `/tmp/okbrain-macos-agent.sock` |

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
- The socket must speak newline-delimited JSON: one request, one response.

---

## 📦 JSON Envelope

### Request

```json
{
  "protocol": "okbrain.macos-agent.v1",
  "id": "req_01HZ...",
  "action": "agent.status",
  "params": {}
}
```

### Success Response

```json
{
  "protocol": "okbrain.macos-agent.v1",
  "id": "req_01HZ...",
  "ok": true,
  "data": {}
}
```

### Error Response

```json
{
  "protocol": "okbrain.macos-agent.v1",
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
  "version": "1.0.0",
  "socketPath": "/tmp/okbrain-macos-agent.sock",
  "permissions": {
    "screenRecording": "granted",
    "accessibility": "unknown"
  },
  "capabilities": ["screenshot.full", "screenshot.window", "screenshot.region", "screenshot.cursor"]
}
```

### `screenshot.capture`

Captures the GUI and returns image bytes as base64 PNG. Brain converts/uploads it to WebP and stores only `/uploads/<id>.webp` in chat/tool events.

```json
{
  "protocol": "okbrain.macos-agent.v1",
  "id": "req_capture_1",
  "action": "screenshot.capture",
  "params": {
    "mode": "full",
    "format": "png",
    "includeCursor": false
  }
}
```

Expected `data`:

```json
{
  "mimeType": "image/png",
  "base64": "iVBORw0KGgo...",
  "width": 3024,
  "height": 1964
}
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

Returns version/build details for diagnostics.

---

## 🔐 Security Rules

- Brain may only connect to hosts allowed by `CODE_PROJECT_SSH_HOSTS`.
- The macOS agent must bind only to a user-owned Unix socket.
- The web app must not run arbitrary installer scripts on the Mac.
- Brain must use a fixed socket bridge command, not arbitrary user-provided shell.
- Enforce response size limits for screenshots.
- Time out screenshot calls quickly, default 15 seconds.
- Never store screenshot base64 in SQLite chat events.
- Store uploaded screenshots as processed WebP files and expose only `/uploads/...` URLs.

---

## 🧪 Brain-side E2E Expectations

- Settings page shows a **macOS Agent Installed / Not Installed** status button for Darwin Code Projects.
- Status button calls `GET /api/code-projects/:id/check-macos-agent`.
- Status response includes `transport: "ssh-unix-socket"` and `socketPath`.
- Screenshot test captures through the `.sock` protocol, processes the PNG, uploads WebP, and returns `fileUri`.
- Chat tool result stores `fileUri`, `mimeType`, and `description`; it must not persist raw base64.
- Mock socket daemon remains valid for TEST_MODE until the standalone macOS app exists.

---

## ✅ Current Compatibility Mapping

The current prototype socket server still accepts legacy action names:

- `ping`
- `capture_full`
- `capture_window`
- `capture_region`

Brain now sends the v1 JSON envelope to the `.sock` first and only falls back to those legacy action names for compatibility. The standalone macOS app should implement the v1 envelope directly on its `.sock` endpoint.
