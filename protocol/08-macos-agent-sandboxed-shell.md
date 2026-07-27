# 🐚 macOS Agent — Sandboxed Shell Execution — Design Proposal

> Status: **Phases 1–4 implemented (core sandbox + Ask flow + Shell Access UI/audit + exec policy). Phase 5 (Brain routing + E2E) pending.** See §13 for the as-built notes.
> Audience: maintainers and integrators. Read `protocol/02` (file editing rules) and `protocol/07` (guardrails & curated functions) first — this doc mirrors their models.
> Goal: route Brain's shell execution **through the macOS agent** inside a **Seatbelt (sandbox-exec) sandbox**, inheriting the existing file permission rules and adding an Ask/Block permission model identical in spirit to the Computer Use guardrails.

---

## 1. Background

| Surface | Today |
| --- | --- |
| `run_shell_command` | Brain executes shell directly over SSH with the full rights of the logged-in user. No file scoping, no network control, no approval flow. |
| `fs.*` file editing | `FilePermissionRuleEngine` (path rules, `disabled`/`read-only`/`read-write`, longest-prefix match, realpath normalization, **default-deny**), persisted in `AgentRuntimeStore`, managed in `PermissionRulesView`. |
| `ax.*` / `functions.*` | Three-tier curated catalog with `app_permission_required` prompts (NSAlert: **Allow Once / Always Allow / Not Now**, 10 s expiry, ≤50 pending inbox), session + persistent rules, `AgentRequestHandler` choke point. |
| Seatbelt / `sandbox-exec` | macOS kernel-enforced sandbox (SBPL profiles). Deprecated-but-load-bearing API; children inherit the sandbox; one-way (can only tighten after apply). Used in production by other coding agents (e.g. Claude Code's sandbox-runtime). |

Shell is the last unrestricted surface. This proposal closes it with the **same rule engine + prompt UX** the user already manages for files and Computer Use.

---

## 2. 🎯 Design Principles

- **Same transport:** keep `Brain → SSH StreamLocal → Unix socket → agent`. Shell becomes new protocol actions (`sh.*`), not a new channel.
- **Inherit, don't duplicate:** file access derives from the existing `FilePermissionRuleEngine` rules. The user manages **one** path-permission UI (`PermissionRulesView`); both `fs.*` and shell consume it.
- **Three tiers, one UX language:** Allow (silent, rule-based) / Ask (prompt, like `ax.*`) / Block (hard deny, no prompt) — same semantics as the curated-function tiers.
- **Kernel-enforced where possible:** Seatbelt is the enforcement layer; the agent's pre-flight checks are a UX layer on top, not the security boundary.
- **Fail closed:** profile generation errors, unknown classifications, and unresolved approvals all result in refusal, never an unsandboxed run.
- **Fallback friendly:** if the agent is unreachable or lacks `sh.*` capabilities, Brain keeps today's direct SSH flow (unchanged behavior, clearly surfaced).

---

## 3. 🚫 Non-Goals

- A hostile-process security boundary or malware defense. This guards against **agent overreach and accidents**, same trust posture as `protocol/07` §6 — plus real kernel enforcement as a bonus.
- Containers/VMs (Apple Container, Virtualization.framework) — rejected as too heavy for v1.
- CPU/RAM/IO quotas — Seatbelt has none; v1 uses best-effort `ulimit`/priority hints only (§9.4).
- Privileged/root execution, `sudo`, or any TCC/SIP manipulation.
- Replacing `functions.*`; shell complements the curated catalog, it doesn't bypass its gating.

---

## 4. 🧩 Permission Model

### 4.1 The three tiers

| Tier | Behavior | Source of truth |
| --- | --- | --- |
| ✅ **Allow** | Runs silently inside the sandbox | File rules (existing `FilePermissionRuleEngine`) + new shell capability rules |
| ❓ **Ask** | Prompts locally (NSAlert + pending inbox), runs only on approval | New `ShellCapabilityRule` store, mirrored on `AXAppPermissionRule` |
| ⛔ **Block** | Hard deny, never promptable, logged to audit | Immutable base profile compiled into every run |

### 4.2 File access — inherited (Tier Allow)

`FilePermissionRuleEngine` output maps directly to SBPL:

| File rule mode | Generated SBPL |
| --- | --- |
| `read-write` | `(allow file-read* file-write* (subpath "<realpath>"))` |
| `read-only` | `(allow file-read* (subpath "<realpath>"))` |
| no rule (default-deny) | nothing — kernel denies; plus `(allow file-read-metadata)` globally so `ls`/`stat` work without contents |

- Paths are realpath-normalized by the existing engine before profile generation — symlink resolution matches `fs.*` semantics exactly.
- System runtime paths are always read-allowed (`/usr`, `/bin`, `/sbin`, `/System`, `/Library`, `/private/etc/ssl`, toolchain dirs) or nothing can execute.

### 4.3 Network policy (Tier Allow)

**Fully open by default.** Every generated profile includes `(allow network*)` — unrestricted outbound, inbound, and local bind/listen (dev servers need ports; builds need package managers and git). Prompting on network access would be constant noise for shell work, so v1 accepts this exposure and documents it (§9). A per-host Ask mode can be added later without protocol changes.

### 4.4 Shell capabilities — new rule store (Tier Ask, rare + critical only)

The Ask tier is intentionally tiny. It triggers only for **rare, high-consequence** operations — everything else is Allow (rules/network) or Block (§4.6). New `ShellCapabilityRule` records, persisted via `AgentRuntimeStore` exactly like `permissionRules`/`filePermissionRules`:

```swift
enum ShellCapabilityKind: String, Codable {
  case processExec          // executable path prefix outside trusted set (§4.5)
  case appleEventSend       // per target bundle ID (AppleScript automation from shell)
}

struct ShellCapabilityRule: Codable, Identifiable {
  var kind: ShellCapabilityKind
  var value: String                 // "/opt/homebrew/custom/bin", "com.apple.Music"
  var mode: ShellCapabilityMode     // .ask | .alwaysAllow
}
```

- **Default is Ask.** Absence of a rule = prompt on first use. These events are rare in normal coding workflows, so prompt volume stays near zero.
- `Always Allow` persists the rule; `Allow Once` grants for the session only (in-memory, same semantics as AX grants, §protocol/07 2.3).
- Managed in the existing **Permissions UI** as a new "Shell" section next to file rules and App & Global Access.

### 4.5 Exec policy

| Executable | Tier |
| --- | --- |
| Trusted prefixes: `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`, Xcode toolchain dirs | ✅ Allow (silent) — compiles/builds spawn children freely (children inherit the sandbox) |
| Anything else (user-writable dirs, `~/Downloads`, `/tmp`, project-local binaries) | ❓ Ask per path prefix — the primary "rare + critical" gate: arbitrary downloaded/generated code execution |
| setuid/setgid binaries, `sudo`, `su`, `launchctl` into system domain, `osascript` targeting other apps | ⛔ Block |

Arg-level pre-screening (agent layer, before Seatbelt): a small denylist of dangerous **invocations** of otherwise-trusted tools — `rm -rf /`-style root targets, `dd` to raw devices, `curl|wget … | sh`, `chmod -R` on system paths. Flagged invocations are ⛔ Blocked regardless of exec allowlisting. Seatbelt cannot inspect argv; this pre-screen is defense-in-depth, not the boundary.

### 4.6 Immutable Block profile (Tier Block)

Compiled into **every** generated profile, non-overridable by any rule:

- ⛔ `file-write*` to `/System`, `/private/etc`, `/private/var/db`, `/usr/libexec`, other users' homes, `~/Library/Keychains`, `~/.ssh` (matches `protocol/02` high-risk path list)
- ⛔ `file-read* file-write*` to all TCC databases (`TCC.db` — prevents permission self-granting)
- ⛔ `authorization-right-obtain`, `nvram*`, `sysctl-write`, `file-write-mount`, `file-write-unmount`, `file-write-setugid`
- ⛔ `mach-lookup` to privileged services (`com.apple.authd`, opendirectoryd, etc.)
- ⛔ `process-exec` of setuid/setgid binaries (§4.4)

---

## 5. 🏗️ Architecture

```
Brain ──OKB1 sh.exec──▶ AgentRequestHandler (choke point)
                            │
                            ▼
                    ShellExecutionService
                       1. Pre-flight classify (argv → exec/AppleEvent intents)
                       2. Rule check: Allow → build profile
                                      Ask   → ShellPermissionPrompter → grant? → build profile
                                      Block → shell_permission_blocked
                       3. SBPLProfileGenerator(rules, blockBase) → profile.sb
                       4. spawn /usr/bin/sandbox-exec -f profile.sb -- <cmd>
                       5. bounded stdout/stderr drain, timeout, audit event
```

- **`AgentRequestHandler` stays the single choke point** — `sh.*` actions get the same remote-control kill-switch check and re-check-before-dispatch pattern as `functions.run` (protocol/07 §3.1).
- **`SBPLProfileGenerator`** — pure function from `(fileRules, shellCapabilityRules, approvedOnceGrants) → SBPL string`. Unit-testable, no I/O. Regenerated per execution from live stores.
- **`ShellPermissionPrompter`** — mirrors `AXPermissionPrompter`: main-thread NSAlert (**Allow Once / Always Allow / Not Now**), 10 s expiry, sanitized pending inbox (≤50 de-duped kind/value entries), menu-bar surfacing. Dismiss/timeout persists nothing.
- **One-way sandbox consequence:** approval cannot widen a running process. The Ask flow is therefore **pre-flight** (classify → prompt → then spawn) rather than reactive; if classification misses something, the kernel denies with `EPERM`, the agent parses `sandboxd` output for the command, and returns `shell_permission_required` so Brain can re-request that exact capability (prompt → re-run). v1 may ship pre-flight only and log misses.
- **Execution service** reuses the `FixedAppleScriptExecutor` patterns: concurrent stdout/stderr drain, shared 1 MiB output cap, timeout → terminate → force-kill, exit code reporting.

---

## 6. 📦 Protocol

### New actions

| Action | Purpose |
| --- | --- |
| `sh.exec` | Run a command string (or argv array) inside the generated sandbox. Params: `command`, `cwd` (must pass file rules, read-write for build outputs), `env` (allow-listed keys), `timeoutSeconds` (capped), `classification` optional hint. |
| `sh.status` | Report the effective policy: file rules in effect, trusted exec prefixes, persisted shell capability rules, block list summary. Lets Brain render the same permission UI state. |

### Capability negotiation

`agent.status.capabilities` gains `"sh.exec"`, `"sh.status"`. Brain prefers agent-shell when present; otherwise falls back to direct SSH (unchanged).

### New error codes

| Code | When |
| --- | --- |
| `shell_permission_required` | Capability needs local approval; `details` carries `kind`, `value`, `command`, `pending` (mirrors `app_permission_required` payload shape) |
| `shell_permission_blocked` | Matched the immutable Block profile or arg pre-screen denylist; no prompt possible |
| `shell_denied_by_sandbox` | Kernel denied an unanticipated operation at runtime (`EPERM` from sandboxd parse); details include the denied SBPL operation when known |
| `shell_timeout` / `shell_output_limit` | Execution exceeded timeout / 1 MiB output cap |
| `invalid_request` | `cwd` fails file rules, disallowed env key, empty command |

### Example denial

```json
{ "ok": false,
  "error": { "code": "shell_permission_required",
    "message": "Executing /tmp/install-helper requires local approval",
    "details": { "kind": "processExec", "value": "/tmp",
                 "command": "/tmp/install-helper --setup", "pending": true } } }
```

---

## 7. 🖥️ macOS App UI

- **PermissionRulesView**: existing file rules stay untouched and now state they apply to "Files & Shell".
- New **Shell Access** section (mirrors App & Global Access screen): table of `ShellCapabilityRule`s (kind, value, mode), add/remove, pending-request inbox with Allow Once / Always Allow / Dismiss.
- **Audit log view** additions: timestamp, command (bounded, no secrets), cwd, classification result, decision (allow/ask-grant/block), exit code — same audit event pattern as `fs.*` (protocol/02 🔐). Never log full stdout contents.

---

## 8. 🧠 Brain Integration

- New `MacOSAgentShellExecutionContext` alongside the existing SSH context; `run_shell_command` routes to the agent when `sh.exec` capability is present and the project root has a file rule.
- On `shell_permission_required`: Brain surfaces the pending prompt to the user in-chat ("approve on your Mac") and can retry after grant — same pattern as Computer Use permission errors today.
- On `shell_permission_blocked`: hard stop, explain the rule.

---

## 9. 🔐 Security Requirements & Limits

1. Sandbox profile regeneration on **every** execution from live stores — no cached profiles after rule edits.
2. All rule paths realpath-normalized through the existing engine; profile uses the normalized forms only.
3. `cwd` must resolve inside a read-write file rule.
4. Best-effort resource hygiene only: `ulimit -v`/`nofile` wrappers and `taskpolicy` background priority for long builds; document that CPU/RAM quotas are unavailable on macOS without VMs.
5. 1 MiB combined stdout/stderr cap; configurable per-call timeout with hard ceiling.
6. Audit every execution including denials; never log stdout contents or env values.
7. The agent never edits TCC databases, never invokes `sudo`, and Block rules cannot be relaxed from the socket.
8. Network is fully open by design in v1 (§4.3); document this exposure in `sh.status` output and the README so users can make an informed choice.
9. Known limitation to document: `sandbox-exec` is a deprecated-but-functional private interface; monitor Apple's containerization work as a future migration path. Children inheriting the profile is the property we depend on.

---

## 10. 🧪 Testing Plan

- **Unit:** `SBPLProfileGenerator` — file-rule → SBPL mapping (ro/rw/absent), block-base always present, symlink normalization, exec-prefix classification, arg pre-screen denylist hits.
- **Protocol verifier (`scripts/verify_protocol.swift`):** default-Ask out-of-tree exec attempt (e.g. from `/tmp`), Allow-Once vs Always-Allow persistence, prompt timeout → pending inbox, Block-tier TCC.db write attempt, `cwd` outside rules, capability advertisement, output caps, timeout kill.
- **Live tests (per trick *"macOS agent AX API — usage rules & live-testing workflow"*):** `sandbox-exec` profile against a real build (`swift build` in an allowed root — must run fully silent including network fetches), `curl` to external host runs without prompt, out-of-tree exec prompt flow, denial audit entries.
- **E2E (Brain):** mock agent with `sh.*` actions; routing preference + SSH fallback.

---

## 11. 🚀 Build Order

1. **Phase 1 — Core sandbox:** `SBPLProfileGenerator` from file rules + block base + open network, `ShellExecutionService` (spawn, drain, caps, timeout, audit), `sh.exec`/`sh.status`, no Ask yet (out-of-tree exec denied).
2. **Phase 2 — Ask flow:** classification engine, `ShellCapabilityRule` store, `ShellPermissionPrompter` + pending inbox, error codes.
3. **Phase 3 — UI:** Shell Access section, pending inbox, audit view; file-rules copy update ("Files & Shell").
4. **Phase 4 — Exec policy:** trusted prefixes, Ask for out-of-tree binaries, arg pre-screen denylist.
5. **Phase 5 — Brain routing + E2E + docs** (README, project tricks).

---

## 12. ❓ Open Questions

1. Reactive denial re-request (parse sandboxd → prompt → auto re-run) — v1 or v2? (Default: v2; pre-flight covers classified intents.)
2. Env allow-list: which keys may pass (`PATH`, `HOME`, `LANG`, …)? (Default: minimal fixed set + `TERM`.)
3. Should network stay fully open long-term, or gain an optional per-host Ask mode later? (Default: fully open for v1; `sh.status` documents the exposure; protocol leaves room for a future `networkOutbound` rule kind without breaking changes.)
4. Session grants for shell capabilities — decay after N minutes like an option, or session-only like AX? (Default: session-only, mirroring protocol/07 §7.)
5. Should `osascript` be executable from shell at all (it would bypass `functions.*` curation)? (Default leaning: Block; revisit.)

---

## 13. 🛠️ As-Built Notes (Phases 1–4)

Implementation deviations and decisions made while landing Phases 1–4:

- **Hybrid profile, not pure `(deny default)`.** A fully `(deny default)` profile aborts `bash` during process init on current macOS (SIGABRT before any output), so v1 starts from `(allow default)` and carves out the dangerous directions:
  - **File writes are kernel default-deny:** `(deny file-write* (subpath "/"))` then re-allow read-write rules, build temp dirs (`TMPDIR`, `/private/tmp`), and a small set of device nodes (`/dev/null`, `/dev/zero`, …) that git/clang/curl/shells require. Read-only rules can be read (default) but not written.
  - **File reads and process exec stay open at the kernel level in v1.** Exec scoping is enforced agent-side by `ShellCommandClassifier` (pre-flight Allow/Ask/Block). Read scoping tightens in a later phase; sensitive reads (`~/.ssh`, `~/Library/Keychains`, TCC) are already kernel-denied.
  - The **immutable Block base** (§4.6) is emitted last as specific `deny` rules so it overrides any broader allow regardless of file rules.
- **Ask tier (Phase 2).** `ShellCapabilityStore.swift` adds the `ShellCapabilityRule` store (`processExec` / `appleEventSend`, mode `.ask` / `.alwaysAllow`), a bounded deduped pending inbox (≤50), and `ShellCapabilityCoordinator` — a thread-safe mirror of `AXPermissionCoordinator` (default-Ask, Allow Once = session-only, Always Allow = persisted, prompt timeout → pending + `shell_permission_required(pending:true)`). `SystemShellPermissionPrompter` reuses the AX NSAlert UX (Allow Once / Always Allow / Not Now, 15 s countdown). The classifier now returns `.ask` for out-of-tree executables (was Block in Phase 1) and for inline `osascript … tell application "X"` (appleEventSend = the application name). Dangerous invocations and privileged tools remain a hard Block.
- **Fail closed.** An Ask intent with no coordinator/prompter available throws `shell_permission_required(pending:false)` rather than running. The app always installs a coordinator; the nil path only occurs in minimal/test setups.
- **Exec policy (Phase 4).** Trusted prefixes (§4.5) run silently; out-of-tree absolute-path executables Ask per directory prefix (longest-prefix rule match); `osascript`/`osacompile` with an inline `tell application "X"` Ask per application name (case-insensitive). `osascript script.scpt` (no statically visible target) falls through to the exec rules — `osascript` lives in `/usr/bin`, so it is a trusted exec; only the automation *intent* is gated. This keeps prompt volume near zero while still exercising the `appleEventSend` kind (revisit open question §12.5 if a stronger osascript posture is wanted).
- **UI + audit (Phase 3).** `AgentRuntimeStore` persists the coordinator (`UserDefaults` + change notification, mirroring AX state), publishes `shellCapabilityRules` / `pendingShellCapabilityRequests` / `shellAuditEvents`, and wires a coordinator-backed `ShellExecutionService` into the request handler (the same instance survives handler rebuilds, so live rule edits apply immediately). The audit sink posts a notification observed on the main actor into a bounded (200) in-memory log. `ShellAccessView` manages capability rules, the pending inbox, and the audit log.
- **Dedicated Shell Access tab + independent toggle.** Shell access lives in its own sidebar tab (`AppSection.shellAccess`) with a **Shell Access** switch persisted in `AgentRuntimeStore` (`shellAccessEnabled`, default **off** — default-deny like File Editing). It is **decoupled from `fileEditing.enabled`**: `AgentConfiguration.shellAccessEnabled` gates `sh.exec`/`sh.status` (which still require ≥1 folder rule), while `fileEditing.enabled` gates only the `fs.*`/`workspace.describe` capabilities. The sandbox reuses the shared folder rules, so the tab renders the same `FilePermissionRulesSection` (add-rule + rules table) as the File Permissions tab — one reusable view, two places. Toggling rebuilds the handler and restarts the socket via `applyShellAccessSetting()`, mirroring `applyFileEditingSetting()`.
- **Profile is regenerated per execution** from live rules (no caching); paths are realpath-normalized through `FilePermissionRuleEngine`.
- **Plumbing reused:** `ProcessStopController`/`OutputBudget`/`PipeCollector` were extracted from `FixedAppleScriptExecutor` into `ProcessExecutionSupport.swift` (internal) so the shell executor and verifier share them.
- **Validated live:** `echo`, cwd writes, `cc` compile+run, and `swift --version` run fully silent; writes to `/System` and to paths outside any rule are kernel-denied; `rm -rf /`, `curl|sh`, and `sudo` are blocked pre-flight; an out-of-tree exec runs only with an Always Allow capability rule and is refused (`shell_permission_required`) when declined. Coverage lives in `scripts/verify_shell.swift` (registered in `scripts/test.sh`), including coordinator unit tests with a fake prompter.
- **Executables inside an allowed rule run silently (intentional).** The classifier treats absolute-path executables under a read/write rule (e.g. a compiled binary in `cwd`, `.build/...`) the same as trusted prefixes, so project-local build tools are not prompted. This deliberately widens §4.5's trusted-prefix table to include rule paths; out-of-tree exec *outside* any rule is Ask.
