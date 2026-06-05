# Patch File Improvement Design Plan

## Current State

The current Swift implementation already supports `fs.patch` in `Sources/OkBrainMacOSAgentCore/FileEditing/LocalFileEditingService.swift`.

Key behavior:

- `patch(_:)` validates root/path permissions, UTF-8 encoding, binary detection, expected SHA, dry-run, backup, and atomic write.
- Edits are applied sequentially in memory before any write happens.
- Matching is exact-first, then optional whitespace-normalized fallback.
- Current normalized fallback handles trailing spaces/tabs and `CRLF`/`CR`/`LF` normalization.

The patch-specific code is currently embedded in `LocalFileEditingService`:

- `findPatchMatch`
- `exactRanges`
- `normalizedWhitespaceRanges`
- `normalizeTrailingWhitespaceAndLineEndingsWithMap`
- `lineNumber`

## Gaps Compared With the Python Agent

The Python agent's patch engine is more robust in a few important ways:

- It stores normalized-character mappings as original source spans, not just a single original index.
- It strips trailing final newlines from the normalized form.
- It explicitly extends matches through ignored trailing spaces/tabs only when those spaces reach EOF or a line ending.
- It treats `LF`, `CRLF`, and `CR` consistently for line numbering and matching.
- It validates invalid `startLine` values separately from `patch_not_found`.
- It reports ambiguity with useful match locations.
- It has a clear patch-focused test matrix.

A quick probe of the current Swift behavior found two notable differences:

- `oldText` with a final newline can consume the file's final newline during normalized fallback.
- `startLine` does not work for `CR`-only files because `lineNumber` only counts `\n`.

Also, `swift test` currently has no XCTest/Swift Testing targets, and `./scripts/test.sh` currently fails before file-editing verification reaches patch coverage because `workspace.describe` is denied without an allowed root rule.

## Design Goals

- Match Python patch behavior closely enough that Brain tools have identical UX on macOS and non-macOS hosts.
- Keep the existing v2 protocol stable unless richer diagnostics are intentionally added.
- Keep patching transactional: all edits succeed in memory before any disk write.
- Keep path safety, SHA conflict checks, max-size checks, backup, dry-run, and atomic writes unchanged.
- Make the patch algorithm independently testable.

## Proposed Architecture

### 1. Extract a Dedicated Patch Engine

Create a focused patch component, for example:

```swift
struct TextPatchEngine {
  func findMatch(
    oldText: String,
    in source: String,
    startLine: Int?,
    whitespaceNormalizedFallback: Bool
  ) throws -> PatchMatch
}
```

Supporting models:

```swift
enum PatchMatchKind {
  case exact
  case whitespaceNormalized
}

struct PatchMatch {
  let range: Range<String.Index>
  let line: Int
  let column: Int
  let kind: PatchMatchKind
}

struct SourceSpan {
  let start: String.Index
  let end: String.Index
}

struct NormalizedText {
  let text: String
  let map: [SourceSpan]
}
```

`LocalFileEditingService.patch(_:)` should keep file I/O and permission checks, then delegate matching to `TextPatchEngine`.

### 2. Replace the Normalized Mapping Algorithm

Implement a Swift equivalent of the Python `_normalize_with_map` algorithm:

- Scan source by logical lines.
- Recognize `\n`, `\r\n`, and `\r` as line endings.
- Strip only trailing horizontal whitespace: spaces and tabs.
- Emit one normalized `\n` per original line ending.
- Map each kept body character to its exact source span.
- Map each normalized newline to a source span from the trimmed body end through the full original line ending.
- Strip trailing final normalized newlines and their map entries.

This span-based map avoids guessing with `map[upperOffset]` and makes replacement boundaries explicit.

### 3. Add Explicit Final Whitespace Extension

After converting a normalized match back to a source range, run an equivalent of Python's `_extend_through_ignored_final_whitespace`:

- Start from the raw match end.
- Consume spaces/tabs only while scanning forward.
- Keep the extension only if the consumed whitespace reaches EOF, `\n`, or `\r`.
- Otherwise leave the end unchanged so mid-line content is not deleted.

This preserves the important safety behavior where a match like `a\nb` in `a  \nb c` becomes `X c`, not `Xc` or `X`.

### 4. Build a Reusable Line Index

Replace repeated `lineNumber(at:in:)` scans with a `LineIndex` helper:

```swift
struct LineIndex {
  init(_ source: String)
  func location(at index: String.Index) -> (line: Int, column: Int)
}
```

Requirements:

- Count `\n`, `\r\n`, and `\r` as line breaks.
- Return 1-based line and column values.
- Reuse it for exact matches, normalized matches, changed lines, and diagnostics.

### 5. Improve Match Selection

New selection flow:

1. Validate `oldText` is not empty.
2. Validate `startLine == nil || startLine! >= 1`.
3. Find all exact matches.
4. If exact matches exist, select among them.
5. If exact has zero matches and fallback is enabled, find normalized matches.
6. Select by `startLine` if provided.
7. If zero selected matches, return `patch_not_found`.
8. If multiple selected matches, return `ambiguous_patch` with match locations in the message.
9. Return the single selected `PatchMatch`.

Important nuance: exact matches should always win over normalized fallback.

### 6. Keep Protocol Stable, Add Diagnostics Opportunistically

No required protocol change is needed.

Recommended non-breaking improvements:

- Include `line:column` locations in the `ambiguous_patch` message.
- Optionally add match kind to debug logs, not the public response.
- Optionally add `changedRanges` later, but keep `changedLines` for compatibility.

### 7. Test Plan

Add dedicated patch tests, either as a proper SwiftPM test target or as an executable verifier target included in `scripts/test.sh`.

Core test cases:

- Exact unique match patches correctly.
- Multiple exact matches without `startLine` returns `ambiguous_patch`.
- Multiple exact matches with `startLine` patches the requested line.
- Multiple matches on the same line with `startLine` still returns `ambiguous_patch`.
- Missing text returns `patch_not_found`.
- Empty `oldText` returns `invalid_request`.
- `startLine <= 0` returns `invalid_request`.
- Trailing spaces/tabs are ignored by normalized fallback.
- `CRLF` source matches `LF` `oldText`.
- `CR`-only source supports correct `startLine` disambiguation.
- Final trailing newlines do not affect normalized matching.
- Mid-line safety preserves untouched content after ignored whitespace.
- Unicode/emoji text patches correctly.
- Dry-run returns metadata without writing.
- Expected SHA mismatch returns `content_conflict`.
- Multi-edit success writes once after all matches are resolved.
- Multi-edit failure leaves the file unchanged.

## Implementation Phases

### Phase 1: Stabilize Verification

- Fix `scripts/verify_protocol.swift` so file-editing verification config includes the temp root as an allowed read-write rule.
- Decide whether to convert executable tests into SwiftPM `.testTarget`s so `swift test` is meaningful.

### Phase 2: Extract Patch Engine

- Move patch matching helpers out of `LocalFileEditingService`.
- Keep behavior equivalent initially, then add tests around the extracted engine.

### Phase 3: Port Python Normalization Semantics

- Implement span-based `NormalizedText` mapping.
- Strip trailing final normalized newlines.
- Add explicit final-whitespace extension.
- Replace `lineNumber` with `LineIndex`.

### Phase 4: Integrate and Harden

- Wire `TextPatchEngine` into `LocalFileEditingService.patch(_:)`.
- Preserve existing response shape and error codes.
- Improve ambiguity messages.
- Add regression tests for all Python edge cases.

### Phase 5: Optional Follow-Ups

- Add structured patch diagnostics to logs.
- Add changed range metadata to the protocol in a future v2 extension.
- Add fuzz/property tests comparing Swift output against the Python reference for generated whitespace/newline cases.

## Acceptance Criteria

- `./scripts/test.sh` passes.
- `swift test` either runs real tests or the README documents the intended test command.
- Swift patch behavior passes the Python edge-case matrix.
- Existing exact-match patch behavior remains unchanged.
- No protocol-breaking changes are required for Brain clients.
