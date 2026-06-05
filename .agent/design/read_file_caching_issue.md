# Bug Report: `read_file` Tool Returns Stale Content After `patch_file` / `write_file`

**Status:** 🔴 Confirmed — Root Cause Identified  
**Date:** 2026-06-05  
**Reporter:** Kimi K2.6  
**Component:** File Editing Tool Layer (above macOS Agent Core)

---

## 1. Summary

The `read_file` tool **caches file contents** and fails to invalidate the cache after `patch_file` or `write_file` operations. This causes `read_file` to return stale/outdated file content even though the file on disk has been correctly updated.

---

## 2. Evidence

### Reproduction Steps

1. Created `test_large_code2.swift` (73 lines)
2. Applied `patch_file` → success (file on disk updated to 87 lines)
3. Applied second `patch_file` → success (file on disk updated to 98 lines)
4. Applied third `patch_file` → success (file on disk updated to ~156 lines)
5. Called `read_file` on `test_large_code2.swift` → **returned 98 lines** (stale)
6. Called `cat test_large_code2.swift` via shell → **returned 156 lines** (correct, matches disk)
7. Called `read_file` again → still showed stale content

### Additional Evidence

- The **File Context Index** also shows stale metadata: `test_large_code2.swift — 98 lines` even after the file grew to 156 lines.
- `patch_file` and `write_file` themselves work correctly (verified via `cat` and `wc -l`).
- The stale content persists across multiple `read_file` calls until some later point when the cache finally refreshes.

---

## 3. Root Cause Analysis

### ✅ What was ruled out

| Component | Finding |
|-----------|---------|
| `LocalFileEditingService.swift` | **No caching.** `readData()` uses `Data(contentsOf: url)` — reads fresh from disk every time. |
| `TextPatchEngine.swift` | No caching. Pure text processing. |
| `UnixSocketServer.swift` | No caching. Per-request handler dispatch. |
| `AgentRequestHandler.swift` | No caching. Directly routes to `LocalFileEditingService`. |
| `AgentRuntimeStore.swift` | No file content caching. Only stores app runtime state. |
| Swift codebase search (`cache`, `Cache`, `cached`, `FileHandle`) | **Zero results** in `Sources/` |

### 🎯 Actual Root Cause

The caching bug is **not in the Swift macOS Agent codebase**. It exists in the **tool wrapper layer** that sits above the agent — likely in the Python file-agent fallback or the orchestration layer that manages tool calls.

The `read_file` tool implementation (agent-side or backend-side) maintains a **content cache** keyed by file path, and **does not invalidate** that cache when `patch_file` or `write_file` successfully modifies the same file.

---

## 4. Impact

| Severity | Description |
|----------|-------------|
| 🔴 **High** | Agents cannot reliably verify their own edits, leading to cascading errors |
| 🔴 **High** | Multi-step file editing workflows are broken — agents read stale state and make incorrect subsequent patches |
| 🟡 **Medium** | Agents must fall back to `run_shell_command` with `cat` to verify changes, which is slower and less ergonomic |

---

## 5. Recommended Fix

### Option A: Invalidate Cache on Write (Recommended)

When `patch_file` or `write_file` succeeds, **immediately invalidate** any cached content for that file path in the `read_file` cache.

```
On patch_file(path="foo.txt", ...) success:
    invalidate_cache(path="foo.txt")

On write_file(path="foo.txt", ...) success:
    invalidate_cache(path="foo.txt")
```

### Option B: Disable Cache for `read_file`

Remove caching entirely from the `read_file` tool. The macOS Agent already reads fresh from disk via `Data(contentsOf:)` — the cache adds no value and only introduces bugs.

### Option C: Cache with Timestamp/Checksum Validation

If caching is needed for performance, validate cache entries against file modification time (`mtime`) or content hash before returning cached data.

---

## 6. Files to Investigate (Outside This Repo)

The bug is **not in this repository**. The fix must be applied in the tool orchestration layer. Look for:

- Python file-agent fallback code
- Tool call caching/memoization logic
- `read_file` tool wrapper implementation
- Any middleware that intercepts `read_file`, `write_file`, `patch_file` tool calls

---

## 7. Test Artifacts

The following test files were created during reproduction and can be used for verification:

- `test_large_code2.swift` — 156 lines after all patches
- `test_large_code.swift` — 87 lines after patches
- `test_patch_edge_cases.txt` — basic patch test
- `test_trailing_whitespace.txt` — trailing whitespace test
- `test_ambiguity.txt` — ambiguous match test
- `test_unicode.txt` — unicode/emoji test
- `test_crlf.txt` — CRLF line ending test
- `test_cr_only.txt` — CR-only line ending test
- `test_midline_safety.txt` — mid-line safety test
- `test_final_newline.txt` — final newline test
- `test_same_line.txt` — same-line multiple match test
- `test_exact_priority.txt` / `test_exact_priority2.txt` — exact match priority tests
- `test_exact_wins.txt` — exact match wins over normalized test

---

## 8. Verification Script

To verify the fix, run this sequence:

```bash
# 1. Create a file
echo -e "line1\nline2\nline3" > /tmp/cache_test.txt

# 2. read_file it (populates cache)

# 3. patch_file: change line2 to LINE2

# 4. read_file it again — should show LINE2, not line2

# 5. Verify with cat
cat /tmp/cache_test.txt

# 6. read_file and cat must match. If they don't, the bug is still present.
```

---

## 9. Follow-up Investigation — 2026-06-05

### Findings

- Reproduced the stale-cache behavior with local tool calls:
  - `write_file` → `read_file` cached a 3-line file.
  - `patch_file` inserted two lines successfully on disk.
  - The next `read_file` still returned the old 3-line content, while `cat`/`wc -l` showed the correct 5-line file.
  - The same stale behavior occurred after `write_file` overwrote a previously-read file with more lines.
- Confirmed again that the Swift agent is not the cache owner: `LocalFileEditingService.read(_:)` calls `readData(at:)`, and `readData(at:)` calls `Data(contentsOf:)` every time.
- Added a direct agent regression guard in `scripts/verify_protocol.swift` so `fs.read` is checked immediately after both `fs.patch` and `fs.write`. This prevents future agent-side regressions and proves the remaining stale read is in the wrapper/orchestration layer.

### Actual Fix Required in Brain / Tool Wrapper

Normalize the target file path and invalidate all read/index/list caches for that file whenever `write_file` or non-dry-run `patch_file` succeeds.

```ts
async function writeFileTool(args) {
  const result = await macosAgent.write(args)
  if (result.ok) {
    fileCache.invalidateFile(projectId, normalizePath(args.path))
    fileContextIndex.invalidateFile(projectId, normalizePath(args.path))
    directoryListCache.invalidateAncestors(projectId, normalizePath(args.path))
  }
  return result
}

async function patchFileTool(args) {
  const result = await macosAgent.patch(args)
  if (result.ok && !args.dryRun) {
    fileCache.invalidateFile(projectId, normalizePath(args.path))
    fileContextIndex.invalidateFile(projectId, normalizePath(args.path))
    directoryListCache.invalidateAncestors(projectId, normalizePath(args.path))
  }
  return result
}
```

Recommended cache key if caching is kept:

```ts
cacheKey = `${projectId}:${root}:${relativePath}:${startLine ?? ""}:${endLine ?? ""}:${stat.size}:${stat.mtimeNs}:${stat.sha256 ?? ""}`
```

Safer option: disable `read_file` content caching entirely for macOS agent-backed file tools.

### Temporary Workaround

Until the wrapper fix lands, verify edits with `run_shell_command` (`cat`, `sed`, `wc -l`) instead of trusting `read_file` immediately after `patch_file` or `write_file`.

---

*End of Report*
