import Foundation

func runPatchEngineVerifier() throws {
  try verify("exactUniqueMatchPatchesCorrectly", exactUniqueMatchPatchesCorrectly)
  try verify("multipleExactMatchesWithoutStartLineReturnsAmbiguousPatch", multipleExactMatchesWithoutStartLineReturnsAmbiguousPatch)
  try verify("multipleExactMatchesWithStartLinePatchesRequestedLine", multipleExactMatchesWithStartLinePatchesRequestedLine)
  try verify("multipleMatchesOnSameStartLineStillReturnsAmbiguousPatch", multipleMatchesOnSameStartLineStillReturnsAmbiguousPatch)
  try verify("missingTextReturnsPatchNotFound", missingTextReturnsPatchNotFound)
  try verify("emptyOldTextReturnsInvalidRequest", emptyOldTextReturnsInvalidRequest)
  try verify("invalidStartLineReturnsInvalidRequest", invalidStartLineReturnsInvalidRequest)
  try verify("trailingSpacesAndTabsAreIgnoredByNormalizedFallback", trailingSpacesAndTabsAreIgnoredByNormalizedFallback)
  try verify("crlfSourceMatchesLFOldText", crlfSourceMatchesLFOldText)
  try verify("crOnlySourceSupportsStartLineDisambiguation", crOnlySourceSupportsStartLineDisambiguation)
  try verify("finalTrailingNewlinesDoNotAffectNormalizedMatching", finalTrailingNewlinesDoNotAffectNormalizedMatching)
  try verify("midLineSafetyPreservesUntouchedContentAfterIgnoredWhitespace", midLineSafetyPreservesUntouchedContentAfterIgnoredWhitespace)
  try verify("unicodeEmojiTextPatchesCorrectly", unicodeEmojiTextPatchesCorrectly)
  try verify("wrongStartLineUniqueMatchFallsBackWithWarning", wrongStartLineUniqueMatchFallsBackWithWarning)
  try verify("wrongStartLineWithDuplicateMatchesReturnsAmbiguousPatch", wrongStartLineWithDuplicateMatchesReturnsAmbiguousPatch)
  try verify("patchPayloadIncludesStartLineFallbackWarning", patchPayloadIncludesStartLineFallbackWarning)
  try verify("dryRunReturnsMetadataWithoutWriting", dryRunReturnsMetadataWithoutWriting)
  try verify("expectedSHAMismatchReturnsContentConflict", expectedSHAMismatchReturnsContentConflict)
  try verify("multiEditSuccessAppliesAllEdits", multiEditSuccessAppliesAllEdits)
  try verify("multiEditFailureLeavesFileUnchanged", multiEditFailureLeavesFileUnchanged)
}

private func verify(_ name: String, _ operation: () throws -> Void) throws {
  do {
    try operation()
  } catch {
    throw PatchVerifierFailure("\(name): \(error)")
  }
}

private func exactUniqueMatchPatchesCorrectly() throws {
  let engine = TextPatchEngine()
  var source = "one\nreturn null\nthree\n"
  let match = try engine.findMatch(
    oldText: "return null",
    in: source,
    startLine: nil,
    whitespaceNormalizedFallback: true
  )

  try expectEqual(match.kind, .exact, "unique match kind")
  try expectEqual(match.line, 2, "unique match line")
  try expectEqual(match.column, 1, "unique match column")
  source.replaceSubrange(match.range, with: "return 42")
  try expectEqual(source, "one\nreturn 42\nthree\n", "unique exact patch result")
}

private func multipleExactMatchesWithoutStartLineReturnsAmbiguousPatch() throws {
  let engine = TextPatchEngine()
  try expectProtocolError("ambiguous_patch") {
    _ = try engine.findMatch(
      oldText: "target",
      in: "target\nother\ntarget\n",
      startLine: nil,
      whitespaceNormalizedFallback: true
    )
  } validateMessage: { message in
    try expect(message.contains("1:1"), "ambiguous message should include first location")
    try expect(message.contains("3:1"), "ambiguous message should include second location")
  }
}

private func multipleExactMatchesWithStartLinePatchesRequestedLine() throws {
  let engine = TextPatchEngine()
  var source = "target\nother\ntarget\n"
  let match = try engine.findMatch(
    oldText: "target",
    in: source,
    startLine: 3,
    whitespaceNormalizedFallback: true
  )

  source.replaceSubrange(match.range, with: "patched")
  try expectEqual(source, "target\nother\npatched\n", "startLine-selected patch result")
}

private func multipleMatchesOnSameStartLineStillReturnsAmbiguousPatch() throws {
  let engine = TextPatchEngine()
  try expectProtocolError("ambiguous_patch") {
    _ = try engine.findMatch(
      oldText: "a",
      in: "a a\n",
      startLine: 1,
      whitespaceNormalizedFallback: true
    )
  } validateMessage: { message in
    try expect(message.contains("1:1"), "same-line ambiguous message should include first column")
    try expect(message.contains("1:3"), "same-line ambiguous message should include second column")
  }
}

private func missingTextReturnsPatchNotFound() throws {
  let engine = TextPatchEngine()
  try expectProtocolError("patch_not_found") {
    _ = try engine.findMatch(
      oldText: "missing",
      in: "present\n",
      startLine: nil,
      whitespaceNormalizedFallback: true
    )
  }
}

private func emptyOldTextReturnsInvalidRequest() throws {
  let engine = TextPatchEngine()
  try expectProtocolError("invalid_request") {
    _ = try engine.findMatch(
      oldText: "",
      in: "present\n",
      startLine: nil,
      whitespaceNormalizedFallback: true
    )
  }
}

private func invalidStartLineReturnsInvalidRequest() throws {
  let engine = TextPatchEngine()
  try expectProtocolError("invalid_request") {
    _ = try engine.findMatch(
      oldText: "present",
      in: "present\n",
      startLine: 0,
      whitespaceNormalizedFallback: true
    )
  }
}

private func trailingSpacesAndTabsAreIgnoredByNormalizedFallback() throws {
  let engine = TextPatchEngine()
  var source = "alpha  \n\tbeta\t\n"
  let match = try engine.findMatch(
    oldText: "alpha\n\tbeta",
    in: source,
    startLine: nil,
    whitespaceNormalizedFallback: true
  )

  try expectEqual(match.kind, .whitespaceNormalized, "normalized trailing whitespace match kind")
  source.replaceSubrange(match.range, with: "done")
  try expectEqual(source, "done\n", "normalized trailing whitespace patch result")
}

private func crlfSourceMatchesLFOldText() throws {
  let engine = TextPatchEngine()
  var source = "a\r\nb\r\nc"
  let match = try engine.findMatch(
    oldText: "a\nb",
    in: source,
    startLine: nil,
    whitespaceNormalizedFallback: true
  )

  source.replaceSubrange(match.range, with: "x")
  try expectEqual(source, "x\r\nc", "CRLF source should match LF oldText")
}

private func crOnlySourceSupportsStartLineDisambiguation() throws {
  let engine = TextPatchEngine()
  var source = "target\rskip\rtarget\r"
  let match = try engine.findMatch(
    oldText: "target",
    in: source,
    startLine: 3,
    whitespaceNormalizedFallback: true
  )

  try expectEqual(match.line, 3, "CR-only startLine line number")
  source.replaceSubrange(match.range, with: "patched")
  try expectEqual(source, "target\rskip\rpatched\r", "CR-only startLine patch result")
}

private func finalTrailingNewlinesDoNotAffectNormalizedMatching() throws {
  let engine = TextPatchEngine()
  var source = "foo  \n"
  let match = try engine.findMatch(
    oldText: "foo\n",
    in: source,
    startLine: nil,
    whitespaceNormalizedFallback: true
  )

  source.replaceSubrange(match.range, with: "bar")
  try expectEqual(source, "bar\n", "final newline should remain after normalized fallback")
}

private func midLineSafetyPreservesUntouchedContentAfterIgnoredWhitespace() throws {
  let engine = TextPatchEngine()
  var source = "a  \nb c"
  let match = try engine.findMatch(
    oldText: "a\nb",
    in: source,
    startLine: nil,
    whitespaceNormalizedFallback: true
  )

  source.replaceSubrange(match.range, with: "X")
  try expectEqual(source, "X c", "mid-line content after ignored whitespace should be preserved")
}

private func unicodeEmojiTextPatchesCorrectly() throws {
  let engine = TextPatchEngine()
  var source = "hello 👋\nhello 👋\n"
  let match = try engine.findMatch(
    oldText: "hello 👋",
    in: source,
    startLine: 2,
    whitespaceNormalizedFallback: true
  )

  source.replaceSubrange(match.range, with: "goodbye 🌍")
  try expectEqual(source, "hello 👋\ngoodbye 🌍\n", "Unicode patch result")
}

private func wrongStartLineUniqueMatchFallsBackWithWarning() throws {
  let engine = TextPatchEngine()
  var source = "one\ntarget\nthree\n"
  let match = try engine.findMatch(
    oldText: "target",
    in: source,
    startLine: 99,
    whitespaceNormalizedFallback: true
  )

  try expectEqual(match.line, 2, "fallback should use unique actual line")
  try expectEqual(match.warnings.count, 1, "fallback should report one warning")
  try expect(match.warnings[0].contains("startLine 99"), "fallback warning should mention requested startLine")
  try expect(match.warnings[0].contains("2:1"), "fallback warning should mention actual location")
  source.replaceSubrange(match.range, with: "patched")
  try expectEqual(source, "one\npatched\nthree\n", "fallback patch result")
}

private func wrongStartLineWithDuplicateMatchesReturnsAmbiguousPatch() throws {
  let engine = TextPatchEngine()
  try expectProtocolError("ambiguous_patch") {
    _ = try engine.findMatch(
      oldText: "target",
      in: "target\nother\ntarget\n",
      startLine: 99,
      whitespaceNormalizedFallback: true
    )
  } validateMessage: { message in
    try expect(message.contains("startLine 99"), "ambiguous fallback message should mention requested startLine")
    try expect(message.contains("1:1"), "ambiguous fallback message should include first location")
    try expect(message.contains("3:1"), "ambiguous fallback message should include second location")
  }
}

private func patchPayloadIncludesStartLineFallbackWarning() throws {
  let fixture = try PatchFixture(content: "one\ntwo\n")
  defer { fixture.remove() }

  let payload = try fixture.service.patch(AgentRequestParams(
    root: fixture.rootPath,
    path: fixture.fileName,
    edits: [FilePatchEdit(oldText: "two", newText: "three", startLine: 99)]
  ))

  try expectEqual(payload.changedLines, [2], "fallback payload changed lines")
  try expectEqual(payload.warnings?.count, 1, "fallback payload warning count")
  try expect(payload.warnings?.first?.contains("startLine 99") == true, "fallback payload warning should mention requested startLine")
  try expectEqual(try fixture.read(), "one\nthree\n", "fallback payload should write patched content")
}

private func dryRunReturnsMetadataWithoutWriting() throws {
  let fixture = try PatchFixture(content: "one\ntwo\n")
  defer { fixture.remove() }

  let payload = try fixture.service.patch(AgentRequestParams(
    root: fixture.rootPath,
    path: fixture.fileName,
    edits: [FilePatchEdit(oldText: "two", newText: "three", startLine: 2)],
    dryRun: true
  ))

  try expectEqual(payload.applied, 1, "dry-run applied count")
  try expectEqual(payload.changedLines, [2], "dry-run changed lines")
  try expect(payload.previousSha256 != payload.sha256, "dry-run should report patched sha")
  try expect(payload.backupPath == nil, "dry-run should not create backup")
  try expectEqual(try fixture.read(), "one\ntwo\n", "dry-run should not write file")
}

private func expectedSHAMismatchReturnsContentConflict() throws {
  let fixture = try PatchFixture(content: "one\n")
  defer { fixture.remove() }

  try expectProtocolError("content_conflict") {
    _ = try fixture.service.patch(AgentRequestParams(
      root: fixture.rootPath,
      path: fixture.fileName,
      expectedSha256: "not-the-current-sha",
      edits: [FilePatchEdit(oldText: "one", newText: "two")]
    ))
  }
}

private func multiEditSuccessAppliesAllEdits() throws {
  let fixture = try PatchFixture(content: "alpha\nbeta\ngamma\n")
  defer { fixture.remove() }

  let payload = try fixture.service.patch(AgentRequestParams(
    root: fixture.rootPath,
    path: fixture.fileName,
    edits: [
      FilePatchEdit(oldText: "alpha", newText: "one"),
      FilePatchEdit(oldText: "gamma", newText: "three")
    ]
  ))

  try expectEqual(payload.applied, 2, "multi-edit applied count")
  try expectEqual(payload.changedLines, [1, 3], "multi-edit changed lines")
  try expectEqual(try fixture.read(), "one\nbeta\nthree\n", "multi-edit file content")
}

private func multiEditFailureLeavesFileUnchanged() throws {
  let fixture = try PatchFixture(content: "alpha\nbeta\n")
  defer { fixture.remove() }

  try expectProtocolError("patch_not_found") {
    _ = try fixture.service.patch(AgentRequestParams(
      root: fixture.rootPath,
      path: fixture.fileName,
      edits: [
        FilePatchEdit(oldText: "alpha", newText: "one"),
        FilePatchEdit(oldText: "missing", newText: "two")
      ]
    ))
  }

  try expectEqual(try fixture.read(), "alpha\nbeta\n", "failed multi-edit should leave file unchanged")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() {
    throw PatchVerifierFailure(message)
  }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
  try expect(actual == expected, "\(message). Expected \(expected), got \(actual)")
}

private func expectProtocolError(
  _ code: String,
  operation: () throws -> Void,
  validateMessage: (String) throws -> Void = { _ in }
) throws {
  do {
    try operation()
  } catch let error as AgentProtocolError {
    try expectEqual(error.code, code, "protocol error code")
    try validateMessage(error.message)
    return
  }

  throw PatchVerifierFailure("Expected protocol error code \(code)")
}

private struct PatchFixture {
  let rootURL: URL
  let rootPath: String
  let fileName = "file.txt"
  let service: LocalFileEditingService

  init(content: String) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("OkBrainTextPatchEngineTests")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    rootPath = try FilePermissionRuleEngine.normalizedRulePath(rootURL.path)
    try content.write(to: rootURL.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    service = LocalFileEditingService(configuration: FileEditingConfiguration(
      enabled: true,
      mode: .readWrite,
      allowedRoots: [FileEditingAllowedRoot(path: rootPath, mode: .readWrite)]
    ))
  }

  func read() throws -> String {
    try String(contentsOf: rootURL.appendingPathComponent(fileName), encoding: .utf8)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private struct PatchVerifierFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

@main
struct PatchEngineVerifier {
  static func main() {
    do {
      try runPatchEngineVerifier()
      print("Patch engine verifier passed")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(1)
    }
  }
}
