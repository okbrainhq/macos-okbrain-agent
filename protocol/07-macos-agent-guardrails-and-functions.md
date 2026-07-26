# 🛡️ macOS Agent Guardrails & Curated Functions — Design Doc

> Status: **Design (approved direction, not yet implemented)**
> Audience: implementing agent. Read `protocol/02` (file editing rules), `protocol/04` (AX API), and `protocol/05` (osascript API) first.
> Goal: add **per-app permission guardrails** to `ax.*` and replace raw `osascript.run` with a **curated function catalog**. This is *guidance*, not a sandbox — it prevents accidental overreach by the remote agent and gives the user visibility and control.

---

## 1. Background & Current State

| Surface | Today |
| --- | --- |
| `fs.*` file editing | Full rule engine (`FilePermissionRuleEngine`): path rules, `disabled`/`read-only`/`read-write`, longest-prefix match, `realpath` normalization, **default-deny**. Persisted in UserDefaults, managed in `PermissionRulesView`. |
| `ax.*` accessibility | Only a global kill-switch (`remoteControlAPIsEnabled` UserDefaults flag, checked in `AgentRequestHandler.handle`). No per-app scoping. Write actions post synthetic CGEvents globally or to a target pid (CGEvent field 89). |
| `osascript.run` | Same kill-switch only. Pipes arbitrary AppleScript/JXA to `/usr/bin/osascript` with the user's full privileges. `do shell script` bypasses *all* file rules. |

Existing building blocks to reuse:

- `FilePermissionRuleEngine` + `FileEditingAllowedRoot` — the pattern to mirror.
- `AutomationPermissionService` (`Sources/OkBrainMacOSAgentCore/Osascript/`) — wraps `AEDeterminePermissionToAutomateTarget` for per-app macOS **TCC Automation** status/prompting. Used by "Settings → AppleScript App Access". See trick *"macOS Automation permission API"* for signature/error-code mapping.
- `AgentRuntimeStore` — `@Published` settings + UserDefaults persistence pattern (`filePermissionRules`, `remoteControlAPIsEnabled`).
- `AgentRequestHandler` — single choke point: every protocol action passes through `handle`.
- `AccessibilityServicing` / `OsascriptServicing` are protocols — decorators/wrappers insert cleanly.

---

## 2. Part A — Per-App AX Permission Guard

### 2.1 Rule model

```swift
enum AXAppPermissionMode: String, Codable {
  case deny      // nothing allowed
  case observe   // read actions only
  case control   // read + write actions
}

struct AXAppPermissionRule: Codable, Equatable, Identifiable {
  var bundleID: String     // e.g. "com.apple.Terminal"
  var appName: String      // display only
  var mode: AXAppPermissionMode
}
```

- `AXPermissionRuleEngine(rules:)` mirrors `FilePermissionRuleEngine`.
- **Read actions:** `ax.list-apps`, `ax.list-windows`, `ax.get-tree`, `ax.find`, `ax.get-value` → need `observe` or `control`.
- **Write actions:** `ax.perform`, `ax.set-value`, `ax.type-text`, `ax.key-press`, `ax.click-at`, `ax.scroll`, `ax.drag` → need `control`.
- **Default posture for unknown apps:** `control`-equivalent *today's behavior is preserved for reads*; **writes to unknown apps trigger the permission prompt** (§2.3). Reads stay allowed (observe-by-default) — user decision: "read ops are okay, write ops need permission".

### 2.2 Target resolution

Every decision resolves a **target bundle ID** before dispatch:

1. If the request query has `pid` → `NSRunningApplication(processIdentifier:)?.bundleIdentifier`.
2. Else if query has `appName` → match against running apps (same lookup the AX service already does) → bundleID.
3. Else (untargeted CGEvent actions: `type-text`/`key-press`/`click-at` with no `targetPid`) → `NSWorkspace.shared.frontmostApplication` **at call time**. These events go to whatever is focused; this is the main bypass hole and must be covered.
4. If no target can be resolved → treat as unknown app → prompt on writes, allow reads.

### 2.3 Permission prompt (sync + async fallback)

User decision: **sync popup with 10s timeout, then async fallback.**

Flow when a write action targets an app without `control`:

1. `AXPermissionPrompter` (new protocol, injectable for tests) shows an `NSAlert` on the main thread:
   - App icon + name, the requested action (e.g. `ax.perform → press "Delete"`), and the calling context.
   - Buttons: **Allow Once**, **Allow Always** (persists/updates rule to `control`), **Deny**.
   - 10-second countdown label; **default on timeout = Deny**.
2. Response wired back to the waiting request (async/await continuation; the socket handler already supports long-running actions — cf. `osascript.run` default 30s timeout).
3. **Timeout or app-not-foregroundable** → request fails with `app_permission_required` **and** a pending entry is added to the **menu-bar badge**: menu shows "Pending permission requests (n)" where the user can Allow/Deny later. The remote agent retries on its next turn.

Protocol error (new, in `AgentProtocolError`):

```json
{ "ok": false,
  "error": { "code": "app_permission_required",
    "message": "Control of Safari requires user approval",
    "details": { "bundleID": "com.apple.Safari", "appName": "Safari",
                 "action": "ax.perform", "pending": true } } }
```

`pending: true` = queued in menu-bar pending list (timeout path); `pending: false` = user actively denied.

### 2.4 Config, persistence, UI

- Persist `[AXAppPermissionRule]` in UserDefaults via `AgentRuntimeStore` (`@Published private(set) var axAppPermissionRules`, `addAXAppPermissionRule/update/remove` — same shape as `filePermissionRules`).
- Injected into `AgentRequestHandler` as a closure/provider, same as `remoteControlEnabled`.
- **UI:** extend `PermissionRulesView` with an "App Control" section: table of rules (app icon, name, mode dropdown), add via running-apps picker, remove; plus the pending-requests list surfaced in the menu-bar menu.

### 2.5 Enforcement point

In `AgentRequestHandler.handle`, before dispatching any `ax.*` action: resolve target (§2.2) → consult engine → allow / prompt / deny. Keep enforcement in the handler (not the service) so tests can drive it with a fake engine/prompter.

---

## 3. Part B — Curated macOS Functions (replacing `osascript.run`)

Three protocol actions replace the free-form script surface:

| Action | Purpose |
| --- | --- |
| `functions.list` | Return the catalog: name, description, arg schema, tier, enabled state, TCC automation status of target app |
| `functions.run` | Run one function with validated args |
| `functions.propose` | Agent proposes a new function → lands in a user-facing proposals inbox |

### 3.1 Registry

```swift
protocol MacOSFunction {
  var name: String { get }                 // "browser.get-url"
  var summary: String { get }
  var tier: FunctionTier { get }           // .read | .write | .elevated
  var targetBundleID: String? { get }      // nil = no Apple Events needed
  var argSchema: [FunctionArg] { get }     // name, type, required, description, constraints
  func run(args: [String: Any]) throws -> FunctionResult
}
```

- `FunctionRegistry` holds implementations; dispatcher validates name + args (type, required, enum/range constraints) before calling `run`.
- Dispatch pipeline for `functions.run`:
  1. Lookup → `unknown_function`.
  2. Validate args → `invalid_args`.
  3. Tier check → tier-2 functions respect per-function enable toggles; tier-3 are off by default → `function_disabled`.
  4. **Permission gate:** tier-2/3 functions with a `targetBundleID` consult the **same `AXPermissionRuleEngine`** (Part A) — writes need `control` for the target app; this reuses the popup flow. (`app.*` write ops are gated this way — user decision: "app.list/launch/activate/quit/is-running good, but approve based on the ax list".)
  5. **TCC preflight:** if `targetBundleID != nil` and the backend uses Apple Events, call `AutomationPermissionService.status(forBundleID:)`; if not determined → `requestAccess` once; if denied → `automation_permission_required` with `details.bundleID` (agent tells user to grant in Settings → AppleScript App Access).
  6. `run(args)`; map thrown errors → `function_failed` with message.

### 3.2 Function catalog (final — user-approved)

**Tier 1 — read ops (allowed by default, no prompt):**

| Function | Backend | Notes |
| --- | --- | --- |
| `app.list` | NSWorkspace | running apps: name, bundleID, pid, frontmost |
| `app.is-running` | NSWorkspace | arg: `bundleID` or `name` |
| `system.get-volume` | osascript fixed string | output/mute state |
| `system.get-clipboard` | NSPasteboard | text only |
| `system.get-battery` | IOKit | %, charging |
| `system.get-wifi-name` | CoreWLAN | current SSID |
| `media.now-playing` | ScriptingBridge | Music/Spotify: track, artist, state |
| `browser.get-url` / `browser.get-title` / `browser.list-tabs` | ScriptingBridge | arg: `browser` enum(`safari`,`chrome`) — Firefox unsupported (no tab AppleScript) |
| `finder.get-selection` | ScriptingBridge | selected file paths |
| `finder.get-front-path` | ScriptingBridge | path of front Finder window |

**Tier 2 — write ops (enabled per function; target app needs `control` via Part A):**

| Function | Backend | Notes |
| --- | --- | --- |
| `app.launch` / `app.activate` / `app.quit` | NSWorkspace | gated by AX rule for the target app; `quit` = graceful only |
| `system.set-volume` / `system.mute` | osascript fixed string (`set volume output volume <int>`) | int 0–100, interpolated — no injection surface |
| `system.set-clipboard` | NSPasteboard | |
| `system.notify` | UNUserNotification (fallback: fixed osascript) | fixed "OkBrain Agent" branding — prevents phishing-style dialogs |
| `media.play-pause` / `media.next` / `media.previous` | ScriptingBridge | arg: `player` enum(`music`,`spotify`) |
| `browser.open-url` | ScriptingBridge | opens in new tab of chosen browser |
| `finder.reveal` | ScriptingBridge / NSWorkspace | **path validated by `FilePermissionRuleEngine` first** |
| `dialog.ask-user` | osascript fixed template | fixed agent-branded title; returns text/buttons |

**Tier 3 — elevated (off by default, explicit enable, and still needs `control` on target):**

| Function | Backend | Notes |
| --- | --- | --- |
| `browser.run-javascript` | ScriptingBridge (`do JavaScript` / `execute javascript`) | arg: `browser`, `script`; powerful — gate hard |

**Explicitly excluded (user decision):** `finder.move-to-trash`, `finder.empty-trash`. File mutations go through `fs.*` where path rules apply.

### 3.3 `functions.propose`

Params: `{ name, description, rationale, exampleScript? }`.

- Stored (UserDefaults/JSON) as a **proposals inbox**, surfaced in Settings with approve/reject.
- **Approved proposals become stored templates**, not runtime codegen:
  - The `exampleScript` is frozen at approval time (user sees the exact script).
  - Lexical rejection: `do shell script`, `with administrator privileges`, nested `osascript` → cannot be approved.
  - Args substitute into fixed `$placeholder`s only (typed: string args are AppleScript-escaped by the implementation, never raw-concatenated).
- This is guidance-layer design: it keeps the escape hatch for long-tail needs *with explicit user opt-in per function*, without reopening arbitrary script execution.

### 3.4 Removing raw `osascript.run` entirely

- **User decision: remove the `osascript.run` action completely.** No raw-mode toggle, no escape hatch at the protocol level.
- Delete the dispatch branch in `AgentRequestHandler` and the `OsascriptServicing` socket surface; `osascript.run` → `unknown_action` (same as any unlisted action), and it is **removed from `agent.status → capabilities`** so the Brain-side agent adapts automatically.
- Internally, `/usr/bin/osascript` may **still be used by catalog functions** with fixed constant strings (e.g. `system.set-volume`, `dialog.ask-user`) — only the *arbitrary script* entry point is removed.
- The long-tail escape hatch is `functions.propose` (§3.3): user-vetted stored templates, never arbitrary scripts.
- `functions.*` actions are listed in capabilities (and the catalog via `functions.list`) so the remote agent can discover them before attempting.
- Also delete/retire: `protocol/05` doc (replace with a "removed — see protocol/07" stub), Brain-side `macos_osascript_run` tool mapping, and related verify_protocol cases.

### 3.5 New protocol error codes

| Code | When |
| --- | --- |
| `app_permission_required` | AX/function write to app without `control` (see §2.3 payload) |
| `unknown_function` | `functions.run` name not in registry |
| `invalid_args` | arg schema validation failure (details list violations) |
| `function_disabled` | tier gating (Tier-2/3 function not enabled) |
| `automation_permission_required` | TCC denied for `details.bundleID` |
| `function_failed` | implementation threw (message + stderr-ish detail) |

---

## 4. Testing Plan

- `Tests/` (Swift Testing, mirrors `PermissionRuleEngineTests`):
  - `AXPermissionRuleEngine` — bundleID matching, mode gating, unknown-app posture.
  - Target resolution — pid/appName/frontmost/unresolvable (fake `NSRunningApplication` provider).
  - Popup flow — fake prompter: allow-once, allow-always (rule persisted), deny, **timeout → deny + pending entry**.
  - Registry — schema validation (missing/extra/wrong-type args), tier gating, TCC preflight branching (fake `AutomationPermissionServicing`).
  - Proposal templates — lexical rejection cases, placeholder substitution/escaping.
- `scripts/verify_protocol.swift` — envelope + capabilities for `functions.*`, `osascript.run` → `unknown_action` after removal, `app_permission_required` shape. Run via `./scripts/test.sh`.
- Live-testing of AX popup via the workflow in trick *"macOS agent AX API — usage rules & live-testing workflow"*.

---

## 5. Build Order

1. **Phase 1 — Function skeleton:** `MacOSFunction` protocol, registry, `functions.list`/`functions.run` dispatch, ~8 Tier-1 functions (NSWorkspace/NSPasteboard/IOKit backends first — no TCC), error codes, capabilities wiring.
2. **Phase 2 — AX guard:** rule engine, target resolution, prompter (sync 10s + menu-bar pending), handler enforcement, Settings UI section.
3. **Phase 3 — Catalog completion:** Tier-2 functions (ScriptingBridge interfaces generated from sdef), TCC preflight, gating wired to Part A rules, `dialog.ask-user`, `browser.run-javascript` (tier 3).
4. **Phase 4 — Proposals + osascript removal:** `functions.propose` inbox + template approval, delete `osascript.run` dispatch + capabilities entry (§3.4), retire `protocol/05` to a stub.
5. **Phase 5 — Docs:** update `protocol/04` (AX rules section), README features; update project tricks.

---

## 6. Non-Goals

- Not a sandbox: this layer guides the agent and prevents *accidental* overreach; it does not defend against a hostile local process.
- No runtime codegen of arbitrary scripts from proposals (§3.3).
- No changes to `fs.*` rule semantics.

## 7. Open Questions

- Allow-once grants: in-memory only for the session, or decay after N minutes? (Default: session.)
- Should `browser.run-javascript` results be size-capped like file reads? (Default: yes, reuse `limits.maxReadBytes`-style cap.)
- Menu-bar pending requests: auto-expire? (Default: persist until acted on.)
