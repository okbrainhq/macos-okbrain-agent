# 🖱️ macOS Agent — Background Input, Compact Trees & Drag (`ax.*` addendum)

**Status:** Implemented in the macOS agent (socket-only, `OKB1` binary frames)
**Date:** 2026-07-24
**Protocol:** `okbrain.macos-agent.v3`
**Scope:** Addendum to [`04-macos-agent-accessibility-api.md`](./04-macos-agent-accessibility-api.md). Adds PID-targeted (background) input, a compact tree mode, and a new `ax.drag` action.

> Read doc 04 first. This document only describes what is **new or changed**. All existing actions, targeting rules, error codes, and the frontmost-app workflow remain valid.

---

## 🎯 What's new

| Change | Affects | New params |
| --- | --- | --- |
| **PID-targeted input** | `ax.click-at`, `ax.type-text`, `ax.key-press`, `ax.scroll`, `ax.drag` | `targetPid` |
| **Compact tree mode** | `ax.get-tree` | `compact` |
| **Drag action** (new) | `ax.drag` | `x`, `y`, `toX`, `toY`, `targetPid?` |

The capability list now has **twelve** `ax.*` actions (was eleven): `ax.drag` is added.

---

## 🎯 PID-Targeted Input (`targetPid`)

### The problem it solves

Doc 04 rule #1 says synthetic input (`ax.type-text`, `ax.key-press`, `ax.click-at`, `ax.scroll`) always goes to the **frontmost** app — you must `activate` the target first, which steals focus and moves the real cursor. That makes parallel/background control impossible.

### The fix

Every input action now accepts an optional **`targetPid`** (number, the target app's process id — get it from `ax.list-apps`). When present, the agent stamps the synthesized `CGEvent` with field `89` (`kCGEventTargetUnixProcessID`) before posting:

```swift
event.setIntegerValueField(CGEventField(89), value: Int64(targetPid))
event.post(tap: .cghidEventTap)
```

This routes the event **directly to that process** without:

- moving the real mouse cursor,
- stealing focus / changing the frontmost app,
- disturbing whatever the user (or another agent) is doing.

### Params

| Param | Type | Applies to | Meaning |
| --- | --- | --- | --- |
| `targetPid` | number (Int32) | `ax.click-at`, `ax.type-text`, `ax.key-press`, `ax.scroll`, `ax.drag` | Route the synthesized event to this process id. Omit (or `null`) for the legacy frontmost-app behavior. |

### Examples

Click a coordinate inside Safari **without** bringing Safari to front:

```json
{ "action": "ax.click-at", "params": { "x": 700, "y": 500, "targetPid": 4242 } }
```

Type into a background Terminal:

```json
{ "action": "ax.type-text", "params": { "text": "git status\n", "targetPid": 4711 } }
```

⚠️ **Caveat — not every app honors PID-targeted events.** Most Cocoa apps do; some (especially games, custom event loops, and a few Electron builds) ignore them and only respond to frontmost focus. If a `targetPid` action appears to do nothing, fall back to the doc-04 workflow: `ax.perform` `action: "activate"` → send the event without `targetPid`. Always **verify** the outcome (`ax.get-value`, `ax.list-windows`, or `screenshot.capture`).

---

## 🌳 Compact Tree Mode (`compact`)

### The problem it solves

A full `ax.get-tree` on a busy app returns hundreds of nodes — most of them static/decorative (`AXStaticText` labels, empty `AXImage`, layout `AXGroup`s) that an agent never acts on. That burns tokens and dilutes the interactive elements.

### The fix

`ax.get-tree` now accepts **`compact: true`**. The agent prunes **non-interactive leaf nodes** while preserving the tree structure and any container that has interactive descendants. The result is a smaller tree focused on things you can actually click/type/scroll.

### Params

| Param | Type | Applies to | Meaning |
| --- | --- | --- | --- |
| `compact` | bool | `ax.get-tree` | When `true`, drop non-interactive leaf nodes. Default `false` (full tree, unchanged behavior). |

Interactive/kept roles include: `AXButton`, `AXCheckBox`, `AXComboBox`, `AXDisclosureTriangle`, `AXLink`, `AXMenu`, `AXMenuBar`, `AXMenuBarItem`, `AXMenuItem`, `AXOutline`, `AXPopUpButton`, `AXRadioButton`, `AXRow`, `AXScrollBar`, `AXSearchField`, `AXSlider`, `AXTab`, `AXTabGroup`, `AXTable`, `AXTextArea`, `AXTextField`, `AXToolbar`, `AXTree`, `AXScrollArea`, `AXColumn`, `AXCell`, `AXHeading`, `AXWindow`, `AXGroup`, `AXStaticText`, `AXImage`, `AXList`, `AXSplitGroup`.

> Containers are kept when they have interactive descendants, so paths to clickable elements stay intact. Purely decorative leaves are dropped.

### Example

```json
{ "action": "ax.get-tree", "params": { "appName": "Safari", "compact": true, "depth": 8 } }
```

Response shape is identical to the normal `ax.get-tree` (`data.root`, `data.truncated`, etc.) — just fewer nodes.

**When to use it:** first-pass exploration of an unfamiliar app, or any time you only need the actionable surface. Use the full tree (`compact: false`) when you need on-screen text/labels for grounding.

---

## 🖱️ `ax.drag` — drag from one point to another (new action)

Drags the mouse from `(x, y)` to `(toX, toY)` with smooth interpolation (20 intermediate steps, smoothstep easing) so the target app sees a real drag gesture rather than a teleport. Supports `targetPid` for background drags.

### Params

| Param | Type | Required | Meaning |
| --- | --- | --- | --- |
| `x` | number | ✅ | Start X (screen points) |
| `y` | number | ✅ | Start Y (screen points) |
| `toX` | number | ✅ | End X (screen points) |
| `toY` | number | ✅ | End Y (screen points) |
| `targetPid` | number | — | Route to a specific process (see above) |

Coordinates use the same screen-point space as element `frame` values, `ax.click-at`, and `screenshot.capture` region mode.

### Request / response

```json
{ "action": "ax.drag", "params": { "x": 300, "y": 400, "toX": 800, "toY": 400 } }
```

```json
{ "ok": true, "data": { "action": "ax.drag", "detail": "Dragged from (300.0, 400.0) to (800.0, 400.0)" } }
```

Missing `x`/`y`/`toX`/`toY` → `invalid_request`.

---

## 🧰 Brain / OKBrain Integration Guide (deltas)

Update the tool surface from doc 04:

| Brain tool | Agent action | New / changed params |
| --- | --- | --- |
| `macos_ax_get_tree` | `ax.get-tree` | **+ `compact?`** |
| `macos_ax_click_at` | `ax.click-at` | **+ `targetPid?`** |
| `macos_ax_type_text` | `ax.type-text` | **+ `targetPid?`** |
| `macos_ax_key_press` | `ax.key-press` | **+ `targetPid?`** |
| `macos_ax_scroll` | `ax.scroll` | **+ `targetPid?`** |
| `macos_ax_drag` *(new)* | `ax.drag` | `x`, `y`, `toX`, `toY`, `targetPid?` |

Implementation notes:

- All new params are **optional** — existing callers keep working unchanged. Decode them as nullable.
- `targetPid` is an `Int32`; validate it against a live `ax.list-apps` pid before use.
- Gate `macos_ax_drag` on `agent.status → capabilities` containing `ax.drag`.
- When `targetPid` is set you can **skip** the `activate` step from doc 04 rule #1 — that is the whole point. But still verify the result, since some apps ignore PID-targeted events.

### Example: reorder a background app's window without stealing focus

```json
{ "action": "ax.drag", "params": { "x": 320, "y": 60, "toX": 900, "toY": 60, "targetPid": 4242 } }
```

---

## 🧪 Verification

The fake accessibility service in `scripts/verify_protocol.swift` and `Tests/DisplayWakeTests` were updated for the new protocol signatures (`targetPid`, `compact`, `toX`, `toY`, and the `drag` method). Build + run:

```bash
swift build
swift run DisplayWakeTests
swift run PermissionRuleEngineTests
```
