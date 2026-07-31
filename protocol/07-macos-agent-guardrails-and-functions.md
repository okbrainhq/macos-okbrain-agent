# 🛡️ macOS Agent Guardrails & Curated Functions — Design Doc

> Status: **Implemented (guardrails, curated catalog, local controls, and verification coverage)**
> Audience: maintainers and integrators. Read `protocol/02` (file editing rules) and `protocol/04` (AX API); `protocol/05` is now a retirement stub.
> Goal: add **per-app permission guardrails** to `ax.*` and replace raw `osascript.run` with a **curated function catalog**. This is *guidance*, not a sandbox — it prevents accidental overreach by the remote agent and gives the user visibility and control.

---

## 1. Pre-Rollout Background

The table records the surface **before** this rollout; §§2–3 describe the implemented replacement.

| Surface | Before rollout |
| --- | --- |
| `fs.*` file editing | Full rule engine (`FilePermissionRuleEngine`): path rules, `disabled`/`read-only`/`read-write`, longest-prefix match, `realpath` normalization, **default-deny**. Persisted in UserDefaults, managed in `PermissionRulesView`. |
| `ax.*` accessibility | Only a global kill-switch (`remoteControlAPIsEnabled` UserDefaults flag, checked in `AgentRequestHandler.handle`). No per-app scoping. Write actions post synthetic CGEvents globally or to a target pid (CGEvent field 89). |
| `osascript.run` | Same kill-switch only. It accepted arbitrary AppleScript/JXA through `/usr/bin/osascript`, including `do shell script` outside the file-rule layer. This socket action is now removed. |

Existing building blocks used by the implementation:

- `FilePermissionRuleEngine` + `FileEditingAllowedRoot` — the pattern mirrored by App & Global Access rules.
- `AutomationPermissionService` (`Sources/OkBrainMacOSAgentCore/Osascript/`) — wraps `AEDeterminePermissionToAutomateTarget` for per-app macOS **TCC Automation** status/prompting. Curated functions preflight it and the local Remote Control settings link to macOS Automation settings. See trick *"macOS Automation permission API"* for signature/error-code mapping.
- `AgentRuntimeStore` — `@Published` settings + UserDefaults persistence pattern (`filePermissionRules`, `remoteControlAPIsEnabled`).
- `AgentRequestHandler` — single choke point: every protocol action passes through `handle`.
- `AccessibilityServicing` — protocol boundary retained for guarded AX dispatch and verifier fakes; the raw `OsascriptServicing` socket surface was retired.

---

## 2. Part A — Explicit App & Global Access Guard

### 2.1 Default-deny target model

```swift
enum AXAppPermissionMode: String, Codable {
  case observe   // inspect only
  case control   // inspect + change
}

enum PermissionTargetKind: String, Codable {
  case application  // real bundle ID
  case category     // stable global capability ID
}

struct PermissionTarget: Codable, Identifiable {
  var kind: PermissionTargetKind
  var identifier: String     // bundle ID or category ID
  var displayName: String
  var pid: Int32?            // captured only for app dispatch
}

struct AXAppPermissionRule: Codable, Identifiable {
  var target: PermissionTarget
  var mode: AXAppPermissionMode
}
```

- There is **no Deny rule**. The absence of a rule is the default-deny state.
- **Observe** permits read/inspection operations only. **Control** subsumes Observe and also permits actions that alter UI or system state.
- Every app-specific AX action needs an explicit grant: reads request **Observe**; writes request **Control**. A local user may grant through the App & Global Access screen or the matching popup.
- A grant never uses a fake bundle ID. Global capabilities use `PermissionTargetKind.category` and an allow-listed stable category ID.
- A legacy persisted `deny` record is migrated to **no rule**; legacy Observe/Control rules remain valid. Legacy pending requests are migrated as Control requests because the earlier UI only queued control prompts.

### 2.2 Targets and categories

Application targets resolve to a verified bundle ID before a popup can be shown:

1. `targetPid`, then query `pid` → `NSRunningApplication(processIdentifier:)?.bundleIdentifier`.
2. Query `appName` → one matching running app/bundle ID.
3. Untargeted synthetic input (`type-text`, `key-press`, `click-at`, `scroll`, `drag`) captures `NSWorkspace.shared.frontmostApplication` at request time and dispatches to that same PID.
4. A target that cannot resolve to a valid bundle ID fails closed with `app_permission_required`, `pending: false`; it cannot prompt, queue, or create a grant.

`ax.list-apps` and `app.list` are not implicit exceptions: they require **Observe** for the global **Application Discovery** category.

The always-available global categories are:

| Category | Observe examples | Control examples |
| --- | --- | --- |
| Application Discovery | `ax.list-apps`, `app.list` | — |
| Menu Bar Extras | unfiltered `menubar.list` | — |
| System Audio | `system.get-volume` | `system.set-volume`, `system.mute` |
| Clipboard | `system.get-clipboard` | `system.set-clipboard` |
| Power & Battery | `system.get-battery` | — |
| Network Information | `system.get-wifi-name` | — |
| Notifications | — | `system.notify` |
| User Dialogs | — | `dialog.ask-user` |

### 2.3 Permission prompt (sync + async fallback)

When a valid target lacks the requested level, `AXPermissionPrompter` presents a main-thread `NSAlert` for the exact intent:

1. The alert names the app/category, requested action, requested **Observe** or **Control** level, and context. Its buttons are **Allow Once**, **Always Allow Observe/Control**, and **Not Now**.
2. Observe grants only Observe. Control grants Control, which also satisfies later Observe requests. **Not Now** persists no negative decision.
3. The alert expires after 10 seconds. A timeout returns `app_permission_required` and, only for a validated target, creates a sanitized menu-bar pending request with the same intent. The bounded persisted inbox holds at most 50 de-duplicated target/intent/action entries.
4. Pending requests offer intent-specific Allow Once / Always Allow actions or **Dismiss**. Dismiss persists no rule.

Example error:

```json
{ "ok": false,
  "error": { "code": "app_permission_required",
    "message": "Observe access to Safari requires local approval",
    "details": {
      "targetKind": "application",
      "targetID": "com.apple.Safari",
      "bundleID": "com.apple.Safari",
      "appName": "Safari",
      "intent": "observe",
      "action": "ax.get-tree",
      "pending": true
    } } }
```

### 2.4 Config, persistence, UI

- `AgentRuntimeStore` persists generalized `[AXAppPermissionRule]` records and exposes them as `permissionRules`.
- **App & Global Access** always shows the eight global capability choices in its Target picker.
- Applications are added only through **Choose Application…**, a native `.app` file browser. The selected bundle is validated with `Bundle(url:)`, bundle ID validation, and de-duplication; a running-process list is not the permission source.
- The rule table exposes only Observe and Control. Removing a rule revokes its matching session grant as well.
- Timed-out requests appear in the app and menu bar with their requested intent.

### 2.5 Enforcement point

`AgentRequestHandler` is the choke point. It resolves the target, asks the coordinator for the exact intent, and repeats a no-prompt authorization check immediately before dispatch. For AX writes it additionally verifies that the captured PID still belongs to the authorized bundle. For functions it rejects any execution plan that does not declare a valid application or global-category permission target. The global Remote Control switch is rechecked after prompts/TCC waits and before dispatch.

---

## 3. Part B — Curated macOS Functions (replacing `osascript.run`)

Three protocol actions replace the free-form script surface:

| Action | Purpose |
| --- | --- |
| `functions.list` | Return the catalog: name, description, arg schema, tier, enabled state, app/TCC metadata, and static global `permissionTarget` category metadata where available |
| `functions.run` | Run one function with validated args |
| `functions.propose` | Agent proposes a new function → lands in a user-facing proposals inbox |

### 3.1 Registry and dispatch

```swift
protocol MacOSFunction {
  var name: String { get }
  var summary: String { get }
  var tier: FunctionTier { get }            // .read | .write | .elevated
  var argSchema: [FunctionArg] { get }
  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan
  func run(plan: FunctionExecutionPlan) throws -> FunctionResult
}

struct FunctionExecutionPlan {
  var target: FunctionTarget?               // app target / TCC when applicable
  var permissionTarget: PermissionTarget?   // required for every execution
}
```

`FunctionRegistry` validates function name and args before building a plan. The handler rejects a plan with no valid `permissionTarget`, so an unbound backend cannot silently bypass the access gate.

`functions.run` dispatches in this order:

1. Lookup → `unknown_function`.
2. Validate args → `invalid_args`.
3. Apply the local Tier-2/Tier-3 enable toggle → `function_disabled`.
4. Require **Observe** for Tier 1 or **Control** for Tier 2/3 against the plan’s application or global-category target. This may show the exact-intent popup.
5. For app targets using Apple Events, preflight TCC Automation; a denied target returns `automation_permission_required`.
6. Canonicalize required file paths through the file service.
7. Immediately before dispatch, re-check the global Remote Control switch, function enablement/template identity, and non-prompting permission grant.
8. Run the fixed backend; encoded result/output is bounded to 1 MiB.

A Tier-1 function is *catalog-enabled* by default, but it is **not permission-enabled**: it still needs the explicit Observe grant for its target/category.

### 3.2 Function catalog and permission targets

**Tier 1 — read operations (explicit Observe required):**

| Function | Permission target | Backend / notes |
| --- | --- | --- |
| `app.list` | Application Discovery | NSWorkspace running app list |
| `app.is-running` | requested app bundle | name resolves uniquely before status is returned |
| `menubar.list` | Menu Bar Extras without `appName`; requested owner app with `appName` | Native AX enumeration of `AXExtrasMenuBar` status items |
| `menu.list` | requested app (or frontmost app without `appName`) | Native AX enumeration of top-level menu bar items (title, enabled, hasSubmenu, path) |
| `window.list` | requested app (or frontmost app without `appName`) | Native AX window enumeration (title, index, role, frame, main) |
| `system.get-volume` | System Audio | fixed AppleScript volume/mute state |
| `system.get-clipboard` | Clipboard | plain text only |
| `system.get-battery` | Power & Battery | IOKit capacity/charging |
| `system.get-wifi-name` | Network Information | CoreWLAN SSID |
| `media.now-playing` | Music or Spotify app | current track metadata |
| `browser.get-url` / `browser.get-title` / `browser.list-tabs` | Safari or Chrome app | active browser tab/window |
| `finder.get-selection` / `finder.get-front-path` | Finder app | current Finder paths |

**Tier 2 — write operations (per-function toggle + explicit Control):**

| Function | Permission target | Notes |
| --- | --- | --- |
| `app.launch` / `app.activate` / `app.quit` | requested app bundle | `quit` remains graceful only |
| `menubar.open` / `menubar.click` | running owner app | Native AX popup opening/navigation; status item title can match AX title, description, label, or identifier |
| `menu.click` | running app | Native AX menu navigation/press by title or path; no coordinates |
| `window.close` / `window.minimize` / `window.zoom` | running app | Presses the window's AX close/minimize/zoom button |
| `window.raise` | running app | `AXRaise` on the window plus app activation |
| `system.set-volume` / `system.mute` | System Audio | fixed bounded input |
| `system.set-clipboard` | Clipboard | plain text only |
| `system.notify` | Notifications | fixed OkBrain Agent branding |
| `media.play-pause` / `media.next` / `media.previous` | Music or Spotify app | player enum |
| `browser.open-url` | Safari or Chrome app | opens a new tab |
| `finder.reveal` | Finder app + file read rule | canonical, symlink-safe file check first |
| `dialog.ask-user` | User Dialogs | fixed agent-branded dialog |

### 3.2.1 Menu bar extras

These are catalog functions, not new `ax.*` protocol actions. Discover their exact schemas through `functions.list`, then run them through `functions.run`:

```json
{ "action": "functions.run", "params": {
  "functionName": "menubar.list", "args": { "appName": "Acme VPN" }
} }
```

- All three functions also require the process-level macOS **Accessibility** grant. Omitting `appName` from `menubar.list` enumerates eligible running apps that expose `AXExtrasMenuBar` and requires the global **Menu Bar Extras** Observe grant. Supplying `appName` limits the read to one currently running, app-authorized owner: resolution tries an exact localized name first, then a unique case-insensitive partial localized-name match; ambiguous owner names return `invalid_request`.
- `menubar.open` requires `{ appName }` plus an optional `title`, Control for that owner app, and returns the opened popup's top-level items. When `title` is omitted the owner must expose exactly one status item (otherwise the error lists the available items). When present, `title` is normalized and matched case-insensitively against AX title, AX description, AX label, and AX identifier, with exact matches considered before contains matches; ambiguous matches fail and status-item errors list the visible candidates.
- `menubar.click` requires `{ appName, title, menuPath }`, where `menuPath` is a non-empty array of non-empty strings such as `["Settings…", "General"]`. It opens the status item, navigates the hierarchy, presses the final item, and returns the normalized path.

### 3.2.2 Menus and windows

These catalog functions give calling agents declarative, coordinate-free GUI operations. All of them require the process-level macOS **Accessibility** grant and resolve their app target to a bundle ID before dispatch; discover exact schemas through `functions.list`.

- `menu.list` takes an optional `appName` (defaulting to the frontmost app) and returns the top-level menu bar items with `title`, `enabled`, `hasSubmenu`, and the `path` accepted by `menu.click`.
- `menu.click` requires `appName` and either `title` or `path` (plus an optional top-level `menu`). A `title` containing `>` is split into a path (for example `"View > Enter Full Screen"`); `menu` + `title` combine into `[menu, title]`. It opens the menus with `AXShowMenu` and presses the final item with `AXPress`—no coordinates.
- `window.list` takes an optional `appName` filter (defaulting to the frontmost app) and returns each window's `appName`, `title`, `index`, `role`, `subrole`, `frame`, and `main` flag.
- `window.close`, `window.minimize`, and `window.zoom` require `appName` and an optional case-insensitive `title` substring (defaulting to the app's main window) and press the window's AX close/minimize/zoom button. `window.raise` performs `AXRaise` and activates the owning app. Window-targeting failures list the available window titles.

**Tier 3 — elevated (off by default + explicit Control):**

| Function | Permission target | Notes |
| --- | --- | --- |
| `browser.run-javascript` | Safari or Chrome app | powerful; output remains bounded |

`finder.move-to-trash` and `finder.empty-trash` remain excluded; file mutation belongs to `fs.*` under file rules. Screenshot capture remains governed by Screen Recording TCC and is not a curated function category.

### 3.3 `functions.propose`

Params: `{ name, description, rationale, exampleScript? }`.

- Stored (UserDefaults/JSON) as a **proposals inbox**, surfaced in Settings with approve/reject.
- **Approved proposals become stored templates**, not runtime codegen:
  - The user must review the **full source** in Settings; approval submits the visible SHA-256 digest. The immutable template persists the exact source, digest, placeholders, one reviewed target bundle ID/app name, and its Automation requirement.
  - Approval accepts only a small, literal grammar: one `tell application id "bundle.id" … end tell` block for an installed target. Dynamic, unresolved, or multi-target scripts stay unapproved; legacy persisted templates decode but remain disabled until re-reviewed.
  - Lexical rejection blocks shell/admin execution, nested `osascript`, `run script`, scripting additions, raw Apple Events, comments/continuations, and other dynamic/file-system constructs.
  - Args substitute into fixed `$placeholder`s only (typed: string args are AppleScript-escaped by the implementation, never raw-concatenated).
  - The internal AppleScript executor drains stdout/stderr concurrently under a 1 MiB shared cap and terminates/force-kills timed-out or over-limit work.
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
| `app_permission_required` | AX/function Observe or Control request lacks an explicit grant, is dismissed, or times out (see §2.3 payload) |
| `unknown_function` | `functions.run` name not in registry |
| `invalid_args` | arg schema validation failure (details list violations) |
| `function_disabled` | tier gating (Tier-2/3 function not enabled) |
| `automation_permission_required` | TCC denied for `details.bundleID` |
| `function_failed` | implementation threw (message + stderr-ish detail) |

---

## 4. Testing Plan

- `Tests/` exercises file-rule containment and the executable smoke targets.
- `scripts/verify_protocol.swift` covers default-denied Observe and Control, Observe-versus-Control upgrades, session/persistent grants and rule removal, Not Now/timeout/pending behavior, legacy Deny migration, validated global category targets, Application Discovery, captured PID dispatch, unapproved app-status queries, TCC branches, template identity/source protection, `finder.reveal` containment, and output limits.
- The verifier also asserts every built-in unbound function declares one of the always-available global categories and that a function plan without any permission target fails closed.
- `scripts/test.sh` runs both Swift executable targets and all protocol/patch/bundle checks before handoff.
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
- `browser.run-javascript` and every function result are size-capped (1 MiB encoded result/output limit).
- Menu-bar pending requests: auto-expire? (Default: persist until acted on.)
