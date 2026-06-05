# 🖥️ macOS Agent v2 — File Editing Capability Spec

**Status:** Proposed v2 spec  
**Date:** 2026-06-05  
**Scope:** Code Project macOS agent file editing support over the existing SSH → Unix socket transport  
**Extends:** `protocol/01-macos-agent-ssh-socks-protocol.md`

---

## 🎯 Goal

Add **file editing features** to the separate macOS agent so Brain can use the agent for Code Project file tasks on macOS hosts, not only screenshots.

The v2 agent should support the existing coding tool workflow:

- `read_file`
- `write_file`
- `patch_file`
- `list_files`
- `search_files`

Brain should keep the same user-facing tool names and choose the macOS agent as an implementation path when the host is Darwin, the v2 agent is reachable, and the project root is allowed.

---

## ✅ Design Principles

- **Same transport:** keep `Brain server → SSH StreamLocal forwarding → remote Unix socket → macOS agent`.
- **No arbitrary shell:** file editing RPCs must not execute user-provided shell commands.
- **Backward compatible:** screenshot v1 remains valid; v2 adds file capabilities.
- **Project-root scoped:** every file operation must be constrained to an allowed Code Project root.
- **Safe by default:** canonicalize paths, prevent `..` traversal, enforce limits, and use optimistic conflict checks for writes.
- **Fallback friendly:** if v2 file editing is unavailable, Brain can fall back to the existing SSH coding tools.

---

## 🚫 Non-Goals

- Replacing `run_shell_command`; terminal/shell execution still uses existing SSH job flow.
- Installing, updating, or managing the macOS app from Brain.
- Editing files outside explicitly allowed roots.
- Bypassing macOS permissions, SIP, TCC, Full Disk Access, or sandbox restrictions.
- Providing privileged/root file editing.

---

## 📦 Protocol Envelope

Use newline-delimited JSON, one request and one response per line.

### Request

```json
{
  "protocol": "okbrain.macos-agent.v2",
  "id": "req_01HZ...",
  "action": "fs.read",
  "params": {}
}
```

### Success Response

```json
{
  "protocol": "okbrain.macos-agent.v2",
  "id": "req_01HZ...",
  "ok": true,
  "data": {}
}
```

### Error Response

```json
{
  "protocol": "okbrain.macos-agent.v2",
  "id": "req_01HZ...",
  "ok": false,
  "error": {
    "code": "path_outside_root",
    "message": "Resolved path escapes the configured project root"
  }
}
```

---

## 🤝 Capability Negotiation

### `agent.status`

Brain should call `agent.status` first and prefer v2 only when file capabilities are present.

Expected `data`:

```json
{
  "installed": true,
  "running": true,
  "available": true,
  "version": "2.0.0",
  "socketPath": "/tmp/okbrain-macos-agent.sock",
  "protocolVersions": ["okbrain.macos-agent.v1", "okbrain.macos-agent.v2"],
  "capabilities": [
    "screenshot.full",
    "screenshot.window",
    "screenshot.region",
    "fs.stat",
    "fs.list",
    "fs.read",
    "fs.write",
    "fs.patch",
    "fs.search"
  ],
  "fileEditing": {
    "enabled": true,
    "mode": "read-write",
    "allowedRoots": [],
    "permissionRules": [
      {
        "path": "/Users/arunoda/projects",
        "mode": "read-write"
      }
    ],
    "limits": {
      "maxReadBytes": 1048576,
      "maxWriteBytes": 5242880,
      "maxSearchResults": 200,
      "maxListEntries": 1000
    }
  },
  "permissions": {
    "screenRecording": "granted",
    "accessibility": "unknown",
    "fileAccess": "granted"
  }
}
```

---

## 📁 Path Model

All file actions use a `root` plus a root-relative `path`.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "path": "src/app/page.tsx"
}
```

Rules:

- Access is default-deny unless an agent-configured folder rule matches the effective target path.
- A read/write folder rule applies to all nested paths unless a more specific child-folder rule overrides it.
- `agent.status.fileEditing.allowedRoots` is legacy compatibility metadata and is not used for enforcement; native rules are reported as `permissionRules` and enforced by the agent on every `fs.*` request.
- `root` must be absolute, and `path` must be relative; absolute paths are rejected.
- The agent must canonicalize `root + path` with realpath-equivalent logic.
- Reject traversal attempts like `../`, symlink escapes, or paths outside `root`.
- Default symlink behavior is `followSymlinks: false` unless the root policy explicitly allows it.
- Preserve existing file mode and line endings where practical.
- Text encoding defaults to UTF-8.

---

## 🧩 File Actions

### `workspace.describe`

Verifies that a Code Project root is allowed and returns root metadata.

```json
{
  "protocol": "okbrain.macos-agent.v2",
  "id": "req_workspace_1",
  "action": "workspace.describe",
  "params": {
    "root": "/Users/arunoda/projects/my-app"
  }
}
```

Expected `data`:

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "exists": true,
  "mode": "read-write",
  "caseSensitive": false,
  "vcs": {
    "type": "git",
    "root": "/Users/arunoda/projects/my-app"
  }
}
```

### `fs.stat`

Returns file/directory metadata.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "path": "package.json"
}
```

Expected `data`:

```json
{
  "path": "package.json",
  "type": "file",
  "size": 2048,
  "mtime": "2026-06-05T00:00:00.000Z",
  "sha256": "abc123...",
  "isBinary": false,
  "permissions": "0644"
}
```

### `fs.list`

Lists files and directories.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "path": "src",
  "recursive": false,
  "glob": "*.tsx",
  "includeHidden": false,
  "respectGitignore": true,
  "limit": 1000
}
```

Expected `data`:

```json
{
  "entries": [
    {
      "path": "src/app/page.tsx",
      "type": "file",
      "size": 1200,
      "mtime": "2026-06-05T00:00:00.000Z"
    }
  ],
  "truncated": false
}
```

### `fs.read`

Reads text content, optionally by line range.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "path": "src/app/page.tsx",
  "startLine": 1,
  "endLine": 120,
  "maxBytes": 1048576,
  "encoding": "utf-8"
}
```

Expected `data`:

```json
{
  "path": "src/app/page.tsx",
  "content": "export default function Page() {\n  return null\n}\n",
  "encoding": "utf-8",
  "lineCount": 3,
  "range": {
    "startLine": 1,
    "endLine": 3
  },
  "sha256": "abc123...",
  "truncated": false
}
```

Binary files should return `binary_file` unless `binary: "base64"` is explicitly requested by a future capability.

### `fs.write`

Creates or overwrites a file atomically.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "path": "src/app/page.tsx",
  "content": "export default function Page() {\n  return <main>Hello</main>\n}\n",
  "encoding": "utf-8",
  "createDirs": true,
  "expectedSha256": "abc123...",
  "backup": true
}
```

Expected `data`:

```json
{
  "path": "src/app/page.tsx",
  "bytesWritten": 64,
  "previousSha256": "abc123...",
  "sha256": "def456...",
  "backupPath": ".okbrain-backups/20260605T000000Z/src/app/page.tsx"
}
```

Rules:

- Use atomic temp-file write plus rename.
- Preserve permissions if replacing an existing file.
- If `expectedSha256` is provided and does not match current content, reject with `content_conflict`.
- If `backup: true`, create a root-local backup before replacement.

### `fs.patch`

Applies one or more exact text replacements.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "path": "src/app/page.tsx",
  "expectedSha256": "abc123...",
  "edits": [
    {
      "oldText": "return null",
      "newText": "return <main>Hello</main>",
      "startLine": 2
    }
  ],
  "whitespaceNormalizedFallback": true,
  "dryRun": false,
  "backup": true
}
```

Expected `data`:

```json
{
  "path": "src/app/page.tsx",
  "applied": 1,
  "previousSha256": "abc123...",
  "sha256": "def456...",
  "changedLines": [2],
  "backupPath": ".okbrain-backups/20260605T000000Z/src/app/page.tsx"
}
```

Patch rules:

- Prefer exact matching.
- If exact matching fails and `whitespaceNormalizedFallback` is true, normalize trailing whitespace and CRLF/LF only.
- If `oldText` appears multiple times and `startLine` is missing, reject with `ambiguous_patch`.
- If no match is found, reject with `patch_not_found`.
- `dryRun: true` returns the same metadata without writing.

### `fs.search`

Searches file contents inside the root.

```json
{
  "root": "/Users/arunoda/projects/my-app",
  "query": "export default",
  "regex": false,
  "path": ".",
  "glob": "**/*.{ts,tsx}",
  "respectGitignore": true,
  "includeHidden": false,
  "maxResults": 200
}
```

Expected `data`:

```json
{
  "matches": [
    {
      "path": "src/app/page.tsx",
      "line": 1,
      "text": "export default function Page() {"
    }
  ],
  "truncated": false
}
```

---

## 🔐 Security Requirements

- Socket remains user-owned and permissioned `0600`.
- Agent must only edit files as the logged-in macOS user; no sudo or privilege escalation.
- Roots must be approved in the macOS app UI or via security-scoped bookmarks if the app is sandboxed.
- Deny access outside approved roots, including symlink escapes.
- Deny high-risk paths by default unless explicitly approved in the macOS app:
  - `~/.ssh`
  - `~/Library/Keychains`
  - browser profile credential stores
  - system directories like `/System`, `/Library`, `/private/etc`
- Limit request/response payload sizes.
- Record local audit events in the macOS app: timestamp, root, path, action, byte count, and result code.
- Never log full file contents in agent logs.
- Brain should not persist file contents beyond normal chat/tool history behavior.

---

## 🍎 macOS Permission Behavior

File editing normally follows regular POSIX permissions for the logged-in user.

If the app is sandboxed, it must use security-scoped bookmarks for approved roots. If a path requires Full Disk Access or another macOS privacy grant, the agent should return:

```json
{
  "code": "permission_denied",
  "message": "The macOS agent cannot access this folder. Approve the project root in the macOS app or grant the requested macOS permission."
}
```

The agent must not attempt to modify TCC databases or bypass system prompts.

---

## 🧠 Brain Integration Plan

### Tool Routing

Add a Brain-side execution context for Darwin Code Projects:

```text
CodeProjectExecutionContext
  ├─ MacOSAgentFileExecutionContext when v2 fs capabilities are available and root is allowed
  └─ Existing SSH execution fallback otherwise
```

User-facing tool names stay unchanged:

- `read_file`
- `write_file`
- `patch_file`
- `list_files`
- `search_files`

### Suggested Key Files

- `src/lib/code-project-macos-agent.ts` — v2 socket RPC client and capability checks.
- `src/lib/ai/tools/coding-tools.ts` — choose macOS agent file context when eligible.
- `src/app/api/code-projects/[id]/check-macos-agent/route.ts` — include v2 file capability data.
- `src/app/(main)/code-project/[id]/page.tsx` — show File Editing status under macOS Agent settings.
- `e2e/mock-macos-agent.py` — add v2 file action mocks.
- `e2e/code-project-macos-agent-files.spec.ts` — focused E2E coverage.

### Settings UI

For Darwin Code Projects, show:

- Agent status: installed/running/reachable.
- Screenshot status: available/unavailable.
- File Editing status: disabled, read-only, or read-write.
- Allowed roots returned by `agent.status`.
- Clear fallback message when Brain is using SSH file tools instead.

---

## ⚠️ Error Codes

| Code | Meaning |
| --- | --- |
| `unsupported_protocol` | Agent does not support v2. |
| `unsupported_action` | Action is unknown or disabled. |
| `invalid_request` | Malformed params. |
| `root_required` | Missing `root`. |
| `root_not_allowed` | Root is not approved in the macOS app. |
| `path_outside_root` | Canonical path escapes root. |
| `file_not_found` | Target does not exist. |
| `not_a_file` | File action targeted a directory. |
| `not_a_directory` | Directory action targeted a file. |
| `file_too_large` | File exceeds configured read/write limit. |
| `binary_file` | Text operation attempted on binary file. |
| `content_conflict` | `expectedSha256` does not match current file. |
| `patch_not_found` | Patch old text was not found. |
| `ambiguous_patch` | Patch old text matched multiple locations. |
| `permission_denied` | macOS/POSIX permission denied. |
| `operation_timeout` | Operation exceeded timeout. |
| `internal_error` | Unexpected agent failure. |

---

## 🧪 Test Plan

### Unit Tests

- Path canonicalization blocks `..` traversal.
- Symlink escapes are denied by default.
- `expectedSha256` conflicts reject writes.
- Patch exact match, whitespace-normalized fallback, ambiguous match, and not-found cases.
- Size limits and binary detection.

### E2E Tests

Use `TEST_MODE=true` plus `e2e/mock-macos-agent.py`.

- Darwin Code Project detects v2 file capabilities.
- `read_file` routes through macOS agent when root is allowed.
- `write_file` creates/overwrites files and returns updated SHA.
- `patch_file` applies exact replacement and conflict detection.
- `list_files` and `search_files` return root-scoped results.
- Root escape attempts are denied.
- When v2 agent is unavailable, coding tools fall back to existing SSH execution.

Focused command:

```bash
npm run test:e2e -- e2e/code-project-macos-agent-files.spec.ts --reporter=line
```

---

## 🚀 Rollout Phases

| Phase | Work | Priority |
| --- | --- | --- |
| P0 | Define v2 protocol and mock agent support. | Must |
| P0 | Add Brain v2 status/capability detection. | Must |
| P0 | Implement `fs.read`, `fs.write`, `fs.patch`, `fs.list`, `fs.search`. | Must |
| P0 | Add fallback to existing SSH coding tools. | Must |
| P1 | Add macOS app UI for approved folder rules and read/write mode. | Done |
| P1 | Add E2E coverage for routing, editing, and denial cases. | Should |
| P2 | Add security-scoped bookmark support for sandboxed app distribution. | Could |
| P2 | Add optional file watching/diff preview APIs. | Could |

---

## ❓ Open Questions

1. Should each Code Project root require explicit approval in the macOS app UI, or can Brain request approval from the app on first use?
2. Should the agent expose binary read/write in v2, or keep v2 text-only and add binary support later?
3. Should sensitive files like `.env` be editable by default inside an approved root, or require an additional root policy flag?
4. Should Brain cache v2 capability checks per chat session, per Code Project, or per tool call?
