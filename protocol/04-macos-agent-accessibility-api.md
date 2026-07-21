# 🪟 macOS Agent Accessibility (`ax.*`) API

**Status:** Implemented in the macOS agent (socket-only, `OKB1` binary frames)
**Date:** 2026-07-21
**Protocol:** `okbrain.macos-agent.v3`
**Scope:** Let Brain coding agents observe and drive macOS GUI apps via the Accessibility API through the existing agent `.sock`

---

## 🎯 Goal

Give coding agents a small, high-level API to:

- See which apps and windows are open
- Read the UI element tree (buttons, text fields, labels, frames on screen)
- Click / press UI elements by name — no coordinates required
- Read and set values (text fields, checkboxes, sliders)
- Type text, press keyboard shortcuts, and click at screen coordinates

All actions run inside the logged-in GUI session by the macOS agent app, which already holds **Accessibility** permission. Brain reaches them over the same SSH-forwarded Unix socket used for screenshots and file editing.

---

## 🔐 Permission Gate

Every `ax.*` action requires **Accessibility** permission (`AXIsProcessTrusted()`).

- Not granted → error envelope `permission_denied` (`"Accessibility permission is not granted"`).
- Granted → `agent.status` `capabilities` includes the eleven `ax.*` actions.
- Keyboard/mouse event synthesis (`ax.type-text`, `ax.key-press`, `ax.click-at`) is covered by the same Accessibility trust — no extra TCC prompt.

Check `permissions.status` (or `agent.status → permissions.accessibility`) before calling.

---

## 🧭 Element Targeting Model (read this first)

There are **no persistent element handles**. AXUIElement references are not stable across connections, so every action re-resolves the element from a **query** in `params`:

| Param | Type | Applies to | Meaning |
| --- | --- | --- | --- |
| `appName` | string | all query actions | App name or bundle id. Exact match first, then case-insensitive "contains". |
| `pid` | number | all query actions | Target app by process id (wins over `appName`). One of `appName`/`pid` is required. |
| `windowTitle` | string | all query actions | Window title (case-insensitive contains). Default: the app's main window. |
| `windowIndex` | number | all query actions | Window index from `ax.list-windows` (overrides default main window). |
| `allWindows` | bool | `ax.get-tree`, `ax.find`, element lookup | Search every window of the app instead of one window. |
| `role` | string | lookup | Element role or subrole, exact case-insensitive (e.g. `"AXButton"`, `"AXTextField"`, `"AXCheckBox"`). |
| `title` | string | lookup | Element `AXTitle`, case-insensitive **contains**. |
| `label` | string | lookup | Element `AXDescription`, case-insensitive **contains**. |
| `identifier` | string | lookup | Element `AXIdentifier`, case-insensitive **contains**. |
| `valueContains` | string | lookup | Element `AXValue` rendered as text, case-insensitive **contains**. Best for on-screen text (`AXStaticText`) and field contents. |
| `scope` | string | lookup | Search scope: `windows` (default), `menubar` (the app's menu bar — menu items only live here), or `all` (windows + menu bar). |
| `index` | number | lookup | Nth match (0-based, default 0) when several elements match. |
| `depth` | number | `ax.get-tree`, lookups | Max tree depth to walk. Defaults: **10** for `ax.get-tree`, **30** for `ax.find`/`ax.perform`/`ax.get-value`/`ax.set-value`/`ax.scroll` (web content nests deep). |
| `maxElements` | number | `ax.get-tree` | Node budget for the returned tree (default 500). |
| `maxResults` | number | `ax.find` | Max matches (default 20). |

Rules:

- Every provided criterion must match (AND semantics).
- `ax.find`, `ax.perform`, `ax.get-value`, `ax.set-value` require **at least one** of `role`, `title`, `label`, `identifier`, `valueContains` → otherwise `invalid_request`.
- App lookup misses → `app_not_found`. Element lookup misses → `element_not_found`.
- Menu bar items (`AXMenuBarItem`, `AXMenuItem`) are **not** under windows — always pass `scope: "menubar"` (or `"all"`) to find/press them.

---

## 🧩 Actions

All requests use the standard frame:

```json
{ "protocol": "okbrain.macos-agent.v3", "id": "req_1", "action": "ax.list-apps", "params": { ... } }
```

Responses are standard envelopes (`ok`, `data`). No action returns a binary body.

Eleven actions: `ax.list-apps`, `ax.list-windows`, `ax.get-tree`, `ax.find`, `ax.perform`, `ax.get-value`, `ax.set-value`, `ax.type-text`, `ax.key-press`, `ax.click-at`, `ax.scroll`.

### `ax.list-apps` — list running GUI apps

Params: none.

```json
{
  "ok": true,
  "data": {
    "apps": [
      { "pid": 4242, "name": "Safari", "bundleId": "com.apple.Safari", "active": true, "windowCount": 2 },
      { "pid": 4711, "name": "TextEdit", "bundleId": "com.apple.TextEdit", "active": false, "windowCount": 1 }
    ]
  }
}
```

### `ax.list-windows` — list an app's windows

Params: `appName` or `pid`.

```json
{
  "ok": true,
  "data": {
    "pid": 4242,
    "app": "Safari",
    "windows": [
      { "index": 0, "title": "GitHub — Pull Requests", "frame": { "x": 0, "y": 25, "width": 1512, "height": 944 }, "main": true }
    ]
  }
}
```

### `ax.get-tree` — dump the UI element tree

Params: `appName`/`pid` (required), plus optional `windowTitle`, `windowIndex`, `allWindows`, `depth` (default 10), `maxElements` (default 500).

Default scope is the app's **main window**. Pass `allWindows: true` to dump from the app root instead.

```json
{
  "ok": true,
  "data": {
    "pid": 4711,
    "app": "TextEdit",
    "window": { "index": 0, "title": "Untitled", "frame": { "x": 100, "y": 100, "width": 640, "height": 480 }, "main": true },
    "truncated": false,
    "root": {
      "role": "AXWindow",
      "subrole": "AXStandardWindow",
      "title": "Untitled",
      "label": null,
      "identifier": null,
      "value": null,
      "frame": { "x": 100, "y": 100, "width": 640, "height": 480 },
      "enabled": true,
      "focused": true,
      "children": [
        { "role": "AXButton", "title": "Save", "frame": { "x": 120, "y": 110, "width": 60, "height": 28 }, "enabled": true, "children": null }
      ]
    }
  }
}
```

Element fields: `role`, `subrole`, `title`, `label` (AXDescription), `identifier`, `value` (string/number/bool JSON), `valueTruncated`, `frame` (screen coordinates — the same space used by `screenshot.capture` region mode and `ax.click-at`), `enabled`, `focused`, `children`.

Values longer than 2000 characters are clipped with `valueTruncated: true`. When the node budget runs out, `truncated: true` — re-request with a deeper `depth`, a bigger `maxElements`, or a narrower window scope.

### `ax.find` — search elements without dumping the tree

Params: targeting + at least one match criterion, `maxResults` (default 20). Searches **all windows** unless `windowTitle`/`windowIndex` narrows it.

```json
{
  "action": "ax.find",
  "params": { "appName": "Safari", "role": "AXButton", "title": "Merge" }
}
```

```json
{
  "ok": true,
  "data": {
    "matches": [
      { "role": "AXButton", "title": "Merge pull request", "frame": { "x": 940, "y": 812, "width": 148, "height": 32 }, "enabled": true }
    ],
    "truncated": false
  }
}
```

Use `frame` from a match to drive `screenshot.capture` (region) or `ax.click-at` as fallbacks.

### `ax.perform` — act on an element

Params: targeting + criteria + `action` (default `"press"`) + optional `index`.

| `action` | Effect |
| --- | --- |
| `press` | AX press — buttons, checkboxes, menu items, tabs |
| `raise` | Bring a window to the front |
| `show-menu` | Open the element's menu |
| `increment` / `decrement` | Steppers, sliders |
| `confirm` / `cancel` | Dialogs, sheets |
| `pick` | Pick an item (combo boxes, lists) |
| `focus` | Set keyboard focus to the element |
| `scroll-into-view` | Scroll the element visible inside its scroll container |
| `activate` | Activate/bring the whole app to front (element criteria ignored). Uses `AXFrontmost`, which works from a background agent on macOS 14+ where `NSRunningApplication.activate` is silently ignored |

```json
{ "action": "ax.perform", "params": { "appName": "TextEdit", "role": "AXButton", "title": "Save", "action": "press" } }
```

Response `data`: `{ "action": "press", "element": { ...matched element snapshot... } }`.
Failure (unsupported action, stale element, hung app) → `action_failed`.

### `ax.get-value` / `ax.set-value` — read & write element values

`ax.get-value` returns the matched element snapshot (value inside `element.value`).

`ax.set-value` requires `value` (string). The agent adapts it to the element's current value type: numbers for sliders/steppers (`"42"` → 42), booleans for checkboxes (`"true"`, `"1"`, `"yes"`, `"on"` → true), strings otherwise.

```json
{ "action": "ax.set-value", "params": { "appName": "TextEdit", "role": "AXTextArea", "value": "Hello from Brain" } }
```

Prefer `ax.set-value` over `ax.type-text` for long text — it is atomic and does not depend on focus. Non-settable values → `action_failed`.

### `ax.type-text` — type into whatever has focus

Params: `text` (required, ≤ 10 000 chars). Unicode-safe (uses `CGEventKeyboardSetUnicodeString`); works with any keyboard layout.

```json
{ "action": "ax.type-text", "params": { "text": "git status\n" } }
```

Typical flow: `ax.perform` with `action: "focus"` on a text field → `ax.type-text`.

### `ax.key-press` — press a key or shortcut

Params: `key` (required), `modifiers` (array, optional).

- Keys: `return`, `tab`, `space`, `delete`, `forwarddelete`, `escape`, `left`/`right`/`up`/`down`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f12`, or a single US-layout character (`a`–`z`, `0`–`9`, `-=[];',./\` + backtick).
- Modifiers: `command`/`cmd`, `shift`, `option`/`alt`, `control`/`ctrl`.

```json
{ "action": "ax.key-press", "params": { "key": "s", "modifiers": ["command"] } }
```

Unknown key/modifier → `unsupported_parameter`.

### `ax.click-at` — click screen coordinates

Params: `x`, `y` (required, screen points), `button` (`left` default, `right`, `middle`), `clickCount` (default 1; 2 = double-click).

```json
{ "action": "ax.click-at", "params": { "x": 700, "y": 500, "clickCount": 2 } }
```

Coordinates match element `frame` values and screenshot pixels (points; Retina screenshots are 2× — divide pixel coordinates by the scale factor before clicking).

### `ax.scroll` — scroll a page or element

Params: `deltaX` / `deltaY` (numbers; at least one non-zero, 1 unit ≈ one wheel notch), optional targeting query, optional explicit `x`/`y`.

- **Direction:** `deltaY > 0` scrolls *down* (reveals content below); `deltaX > 0` scrolls right.
- **Scroll position resolution:** explicit `x`/`y` → center of the element matched by the query → center of the target window.
- Movement is approximate (the target app may apply its own scaling/smooth scrolling). Issue several calls for long distances, or prefer `ax.perform` with `action: "scroll-into-view"` to reveal a specific element.

```json
{ "action": "ax.scroll", "params": { "appName": "Chrome", "role": "AXWebArea", "deltaY": 10 } }
{ "action": "ax.scroll", "params": { "x": 700, "y": 500, "deltaY": -3 } }
```

---

## ❌ Error Codes (new)

| Code | When |
| --- | --- |
| `permission_denied` | Accessibility permission missing |
| `invalid_request` | Missing app target, missing criteria, missing `value`/`text`/`key`/`x`/`y` |
| `unsupported_parameter` | Unknown key, modifier, mouse button, or perform action |
| `app_not_found` | No running GUI app matches `appName`/`pid` |
| `element_not_found` | No window/element matches the query |
| `action_failed` | AX action rejected by the target app (includes the AX error reason) |

---

## 📌 Usage Rules for AI Agents (important — learned from live testing)

1. **⌨️ `ax.type-text` / `ax.key-press` / `ax.click-at` / `ax.scroll` target the FRONTMOST app.** Synthetic events go wherever the focus is — they do not respect `appName`. Before sending keys/clicks, always:
   1. `ax.perform` with `action: "activate"` for the target app,
   2. optionally verify with `ax.list-apps` → `active: true`,
   3. then send the events.
   Skipping this silently types into whatever app happens to be frontmost.
2. **Prefer `ax.set-value` over `ax.type-text` for text fields.** It is atomic, focus-independent, and works even when another app is frontmost. Fall back to `focus` → `type-text` only when the value is not settable.
3. **Web content attribute cheat-sheet** (Chrome/Safari/Electron apps):
   - `AXLink` → link text is in **`label`**, not `title` (e.g. `{"role":"AXLink","label":"Sign in"}`).
   - `AXStaticText` → visible text is in **`value`** — search it with `valueContains`.
   - `AXTextField` (address bars, inputs) → current text is in `value`; write with `ax.set-value`.
   - Buttons exposed by web pages → usually `AXButton` with text in `title` or `label`.
4. **Web content nests deep.** Google's results text sits ~25 levels down. The find/act default depth is 30 — only override `depth` when you need more.
5. **Chromium/Electron web trees are auto-enabled.** The agent sets `AXEnhancedUserInterface` + `AXManualAccessibility` on every app it touches, which makes Chrome/VS Code/Slack expose their full `AXWebArea` tree. The tree can take ~1 s to materialize after the first call — if a first `ax.find` on a browser returns nothing, wait a second and retry.
6. **Verify after acting.** AX calls report what was requested, not what visually happened. Confirm outcomes with `ax.list-windows` (title changed?), `ax.get-value`, or `screenshot.capture`.
7. **Menu bar commands need `scope: "menubar"`** — e.g. File → New Tab:
   `{ "action": "ax.perform", "params": { "appName": "Chrome", "scope": "menubar", "role": "AXMenuItem", "title": "New Tab" } }`.

---

## 🧰 Brain / OKBrain Integration Guide

Mirror `take_screenshot`: Brain opens one connection per request to the forwarded socket, sends one `OKB1` frame, reads one frame back. Reuse the existing frame codec — these actions are JSON-only (`bodyLength: 0`).

Suggested tool surface (names up to Brain):

| Brain tool | Agent action | Key params |
| --- | --- | --- |
| `macos_ax_list_apps` | `ax.list-apps` | — |
| `macos_ax_list_windows` | `ax.list-windows` | `appName` or `pid` |
| `macos_ax_get_tree` | `ax.get-tree` | `appName`, `windowTitle?`, `depth?`, `maxElements?`, `allWindows?` |
| `macos_ax_find` | `ax.find` | `appName`, `role?`, `title?`, `label?`, `identifier?`, `valueContains?`, `scope?`, `depth?`, `maxResults?` |
| `macos_ax_perform` | `ax.perform` | `appName`, criteria, `action`, `index?`, `scope?` |
| `macos_ax_get_value` | `ax.get-value` | `appName`, criteria |
| `macos_ax_set_value` | `ax.set-value` | `appName`, criteria, `value` |
| `macos_ax_type_text` | `ax.type-text` | `text` |
| `macos_ax_key_press` | `ax.key-press` | `key`, `modifiers?` |
| `macos_ax_click_at` | `ax.click-at` | `x`, `y`, `button?`, `clickCount?` |
| `macos_ax_scroll` | `ax.scroll` | `deltaX?`, `deltaY?`, targeting or `x`/`y` |

### Recommended agent workflow

1. `ax.list-apps` → pick the target app (get `pid`).
2. `ax.get-tree` with a shallow `depth` (3–5) or `ax.find` with criteria → locate the element.
3. Act: `ax.perform` (buttons) / `ax.set-value` (fields) / `ax.key-press` (shortcuts).
4. Verify: re-`ax.find` / `ax.get-value`, or `screenshot.capture` for visual confirmation.

### Example: click "Merge pull request" in Safari

```json
{ "action": "ax.perform", "params": { "appName": "Safari", "role": "AXButton", "title": "Merge pull request", "action": "press" } }
```

### Example: fill a dialog field and confirm

```json
{ "action": "ax.set-value", "params": { "appName": "TextEdit", "role": "AXTextField", "label": "Name", "value": "report.txt" } }
{ "action": "ax.perform", "params": { "appName": "TextEdit", "role": "AXButton", "title": "Save" } }
```

### Example: save in the frontmost app via shortcut

```json
{ "action": "ax.key-press", "params": { "key": "s", "modifiers": ["command"] } }
```

### Guidance for tool implementers

- Gate the tools on `agent.status → capabilities` containing `ax.find` (permission already checked).
- Time out `ax.*` calls quickly (default 15 s, same as screenshots). The agent bounds AX messaging to 5 s per call.
- Never persist element trees or typed text into chat events; treat them like screenshot content.
- `frame` coordinates are screen **points**, top-left origin — share them freely with `ax.click-at` and `screenshot.capture` region mode.
- Web content inside browsers is exposed as `AXWebArea` subtrees; use `ax.find` with `role: "AXButton"` / `"AXLink"` / `"AXTextField"` + `label`/`valueContains` instead of deep tree dumps.
- Follow the "Usage Rules for AI Agents" section above — especially the frontmost-app rule for synthetic input.

---

## 🧪 Verification

`scripts/verify_protocol.swift` covers the action surface with a fake accessibility service (envelope shapes, permission gating, capability listing, and required-param validation). Run everything with:

```bash
./scripts/test.sh
```

For a live smoke test on a Mac with the dev agent running:

```bash
./scripts/build.sh && ./scripts/run.sh   # grant Accessibility when prompted
printf '%s' '{"protocol":"okbrain.macos-agent.v3","id":"1","action":"ax.list-apps","params":{}}' \
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
