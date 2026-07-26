import CryptoKit
import Darwin
import Foundation

public protocol FileEditingServicing: Sendable {
  func describeWorkspace(_ params: AgentRequestParams) throws -> WorkspaceDescribePayload
  func stat(_ params: AgentRequestParams) throws -> FileStatPayload
  func list(_ params: AgentRequestParams) throws -> FileListPayload
  func read(_ params: AgentRequestParams) throws -> FileReadPayload
  func write(_ params: AgentRequestParams) throws -> FileWritePayload
  func patch(_ params: AgentRequestParams) throws -> FilePatchPayload
  func search(_ params: AgentRequestParams) throws -> FileSearchPayload
  /// Resolves an existing readable target through the same canonical,
  /// symlink-safe policy used by `fs.*` before a function may reveal it.
  func resolveExistingReadablePath(_ path: String) throws -> String
}

public final class LocalFileEditingService: FileEditingServicing, @unchecked Sendable {
  private let configuration: FileEditingConfiguration
  private let fileManager: FileManager
  private let permissionEngine: FilePermissionRuleEngine

  public init(configuration: FileEditingConfiguration, fileManager: FileManager = .default) {
    self.configuration = configuration
    self.fileManager = fileManager
    permissionEngine = FilePermissionRuleEngine(rules: configuration.allowedRoots)
  }

  public func resolveExistingReadablePath(_ path: String) throws -> String {
    guard configuration.enabled else {
      throw AgentProtocolError.rootNotAllowed("File editing is disabled")
    }

    // Match the caller's lexical path first. Canonicalizing before this check
    // would turn a child of an allowed root that traverses an escaping symlink
    // into an ordinary outside path and lose the security-relevant error.
    let lexicalPath = try resolveLexicalAbsolutePath(path)
    guard let lexicalMatch = lexicalPermissionMatch(for: lexicalPath), lexicalMatch.mode.canRead else {
      throw AgentProtocolError.rootNotAllowed("No permission rule allows read access to: \(lexicalPath)")
    }

    let relative = relativePath(for: lexicalPath, root: lexicalMatch.lexicalRootPath)
    try rejectSymlinkComponents(relativePath: relative, rootPath: lexicalMatch.lexicalRootPath)
    guard lstatInfo(lexicalPath) != nil else {
      throw AgentProtocolError.fileNotFound("Reveal target does not exist: \(lexicalPath)")
    }

    // A successful lexical check is not sufficient for dispatch: only return
    // a realpath that is still inside the initially matched root and remains
    // readable under the canonical rule engine.
    guard let canonicalPath = realPath(lexicalPath) else {
      throw AgentProtocolError.fileNotFound("Reveal target does not exist: \(lexicalPath)")
    }
    guard self.path(canonicalPath, isInsideRoot: lexicalMatch.canonicalRootPath) else {
      throw AgentProtocolError.pathOutsideRoot("Reveal target resolves outside its allowed root")
    }

    let canonicalDecision = permissionEngine.decision(for: canonicalPath)
    guard canonicalDecision.canRead else {
      throw AgentProtocolError.rootNotAllowed("No permission rule allows read access to: \(canonicalPath)")
    }
    return canonicalPath
  }

  public func describeWorkspace(_ params: AgentRequestParams) throws -> WorkspaceDescribePayload {
    guard configuration.enabled else {
      throw AgentProtocolError.rootNotAllowed("File editing is disabled")
    }
    let canonical = try resolveAbsolute(params.path, defaultPath: nil)
    let decision = permissionEngine.decision(for: canonical)
    guard decision.canRead else {
      throw AgentProtocolError.rootNotAllowed("No permission rule allows read access to: \(canonical)")
    }
    let exists = isDirectory(canonical)
    return WorkspaceDescribePayload(
      root: canonical,
      exists: exists,
      caseSensitive: caseSensitiveVolume(at: canonical),
      vcs: detectVCS(root: canonical)
    )
  }

  public func stat(_ params: AgentRequestParams) throws -> FileStatPayload {
    let resolved = try resolve(params, defaultPath: nil)
    try ensureReadable(resolved)
    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("Target does not exist: \(resolved.url.path)")
    }

    let type = fileType(info)
    var sha256: String?
    var isBinary: Bool?

    if type == "file" {
      let data = try readData(at: resolved.url, maxBytes: configuration.limits.maxReadBytes)
      sha256 = sha256Hex(data)
      isBinary = isBinaryData(data)
    }

    return FileStatPayload(
      path: resolved.url.path,
      type: type,
      size: Int64(info.st_size),
      mtime: iso8601Date(from: info),
      sha256: sha256,
      isBinary: isBinary,
      permissions: permissionsString(info)
    )
  }

  public func list(_ params: AgentRequestParams) throws -> FileListPayload {
    let resolved = try resolve(params, defaultPath: nil)
    try ensureReadable(resolved)
    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("Directory does not exist: \(resolved.url.path)")
    }
    guard fileType(info) == "directory" else {
      throw AgentProtocolError.notADirectory("List target is not a directory: \(resolved.url.path)")
    }

    let recursive = params.recursive ?? false
    let includeHidden = params.includeHidden ?? true
    let respectGitignore = params.respectGitignore ?? true
    let limit = min(max(params.limit ?? configuration.limits.maxListEntries, 1), configuration.limits.maxListEntries)
    let ignoreMatcher = respectGitignore ? GitignoreMatcher(root: resolved.rootPath, fileManager: fileManager) : nil
    let glob = params.glob?.trimmingCharacters(in: .whitespacesAndNewlines)

    var entries: [FileListEntryPayload] = []
    var truncated = false

    func appendEntry(_ url: URL) {
      guard entries.count < limit else {
        truncated = true
        return
      }

      let relative = relativePath(for: url.path, root: resolved.rootPath)
      guard shouldInclude(relativePath: relative, includeHidden: includeHidden, ignoreMatcher: ignoreMatcher) else {
        return
      }
      guard globMatches(glob, relativePath: relative, basename: url.lastPathComponent) else {
        return
      }
      guard let entryInfo = lstatInfo(url.path) else {
        return
      }

      let entryRelative = relativePath(for: url.path, root: resolved.url.path)
      entries.append(FileListEntryPayload(
        name: entryRelative,
        path: entryRelative,
        type: fileType(entryInfo),
        size: Int64(entryInfo.st_size),
        mtime: iso8601Date(from: entryInfo)
      ))
    }

    if recursive {
      let enumerator = fileManager.enumerator(
        at: resolved.url,
        includingPropertiesForKeys: nil,
        options: [.skipsPackageDescendants],
        errorHandler: nil
      )

      while let url = enumerator?.nextObject() as? URL {
        let relative = relativePath(for: url.path, root: resolved.rootPath)
        if shouldSkipTraversal(relativePath: relative, includeHidden: includeHidden, ignoreMatcher: ignoreMatcher) {
          if isDirectory(url.path) {
            enumerator?.skipDescendants()
          }
          continue
        }

        if isSymlink(url.path), isDirectoryFollowingSymlink(url.path) {
          enumerator?.skipDescendants()
        }

        appendEntry(url)
        if truncated {
          break
        }
      }
    } else {
      let urls = try fileManager.contentsOfDirectory(at: resolved.url, includingPropertiesForKeys: nil)
      for url in urls.sorted(by: { $0.path < $1.path }) {
        appendEntry(url)
        if truncated {
          break
        }
      }
    }

    return FileListPayload(entries: entries.sorted { $0.path < $1.path }, truncated: truncated)
  }

  public func read(_ params: AgentRequestParams) throws -> FileReadPayload {
    let resolved = try resolve(params, defaultPath: nil)
    try ensureReadable(resolved)
    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("File does not exist: \(resolved.url.path)")
    }
    guard fileType(info) == "file" else {
      throw AgentProtocolError.notAFile("Read target is not a file: \(resolved.url.path)")
    }

    try validateTextEncoding(params.encoding)
    let maxBytes = min(max(params.maxBytes ?? configuration.limits.maxReadBytes, 1), configuration.limits.maxReadBytes)
    let data = try readData(at: resolved.url, maxBytes: maxBytes)
    guard !isBinaryData(data), let text = String(data: data, encoding: .utf8) else {
      throw AgentProtocolError.binaryFile("Binary files cannot be read as UTF-8 text")
    }

    let ranges = lineRanges(in: text)
    let totalLines = ranges.count
    let requestedStart = max(params.startLine ?? (totalLines == 0 ? 0 : 1), totalLines == 0 ? 0 : 1)
    let requestedEnd = max(params.endLine ?? totalLines, 0)

    let selectedContent: String
    let actualStart: Int
    let actualEnd: Int

    if totalLines == 0 || requestedStart > totalLines || requestedEnd < requestedStart {
      selectedContent = ""
      actualStart = totalLines == 0 ? 0 : requestedStart
      actualEnd = totalLines == 0 ? 0 : min(requestedEnd, totalLines)
    } else {
      actualStart = requestedStart
      actualEnd = min(requestedEnd, totalLines)
      let startIndex = ranges[actualStart - 1].lowerBound
      let endIndex = ranges[actualEnd - 1].upperBound
      selectedContent = String(text[startIndex..<endIndex])
    }

    return FileReadPayload(
      path: resolved.url.path,
      content: selectedContent,
      encoding: "utf-8",
      lineCount: totalLines,
      range: FileReadRangePayload(startLine: actualStart, endLine: actualEnd),
      sha256: sha256Hex(data),
      truncated: false
    )
  }

  public func write(_ params: AgentRequestParams) throws -> FileWritePayload {
    let resolved = try resolve(params, defaultPath: nil)
    try ensureWritable(resolved)
    try validateTextEncoding(params.encoding)

    guard let content = params.content else {
      throw AgentProtocolError.invalidRequest("fs.write requires content")
    }
    guard let data = content.data(using: .utf8) else {
      throw AgentProtocolError.invalidRequest("Content must be UTF-8 encodable")
    }
    guard data.count <= configuration.limits.maxWriteBytes else {
      throw AgentProtocolError.fileTooLarge("Write content exceeds \(configuration.limits.maxWriteBytes) bytes")
    }

    let existingInfo = lstatInfo(resolved.url.path)
    if let existingInfo, fileType(existingInfo) != "file" {
      throw AgentProtocolError.notAFile("Write target is not a file: \(resolved.url.path)")
    }

    let previousData = existingInfo == nil ? nil : try readData(at: resolved.url, maxBytes: configuration.limits.maxReadBytes)
    let previousSha = previousData.map(sha256Hex)
    if let expectedSha = params.expectedSha256, expectedSha != previousSha {
      throw AgentProtocolError.contentConflict("expectedSha256 does not match current file content")
    }

    let parentURL = resolved.url.deletingLastPathComponent()
    if params.createDirs ?? false {
      try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
      try rejectSymlinkComponents(relativePath: parentRelativePath(for: resolved.relativePath), rootPath: resolved.rootPath)
    } else if !isDirectory(parentURL.path) {
      throw AgentProtocolError.fileNotFound("Parent directory does not exist: \(parentURL.path)")
    }

    let backupPath = (params.backup ?? false) && existingInfo != nil ? try backupExistingFile(resolved) : nil
    let permissions = existingInfo.map { mode_t($0.st_mode & 0o777) } ?? mode_t(0o644)
    try atomicWrite(data, to: resolved.url, permissions: permissions)

    return FileWritePayload(
      path: resolved.url.path,
      bytesWritten: data.count,
      previousSha256: previousSha,
      sha256: sha256Hex(data),
      backupPath: backupPath
    )
  }

  public func patch(_ params: AgentRequestParams) throws -> FilePatchPayload {
    let resolved = try resolve(params, defaultPath: nil)
    try ensureWritable(resolved)
    try validateTextEncoding(params.encoding)

    guard let edits = params.edits, !edits.isEmpty else {
      throw AgentProtocolError.invalidRequest("fs.patch requires at least one edit")
    }

    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("File does not exist: \(resolved.url.path)")
    }
    guard fileType(info) == "file" else {
      throw AgentProtocolError.notAFile("Patch target is not a file: \(resolved.url.path)")
    }

    let data = try readData(at: resolved.url, maxBytes: configuration.limits.maxReadBytes)
    guard !isBinaryData(data), var text = String(data: data, encoding: .utf8) else {
      throw AgentProtocolError.binaryFile("Binary files cannot be patched as UTF-8 text")
    }

    let previousSha = sha256Hex(data)
    if let expectedSha = params.expectedSha256, expectedSha != previousSha {
      throw AgentProtocolError.contentConflict("expectedSha256 does not match current file content")
    }

    let fallback = params.whitespaceNormalizedFallback ?? true
    let patchEngine = TextPatchEngine()
    var changedLines: [Int] = []
    var warnings: [String] = []

    for edit in edits {
      let match = try patchEngine.findMatch(
        oldText: edit.oldText,
        in: text,
        startLine: edit.startLine,
        whitespaceNormalizedFallback: fallback
      )
      changedLines.append(match.line)
      warnings.append(contentsOf: match.warnings)
      text.replaceSubrange(match.range, with: edit.newText)
    }

    guard let patchedData = text.data(using: .utf8) else {
      throw AgentProtocolError.invalidRequest("Patched content must be UTF-8 encodable")
    }
    guard patchedData.count <= configuration.limits.maxWriteBytes else {
      throw AgentProtocolError.fileTooLarge("Patched content exceeds \(configuration.limits.maxWriteBytes) bytes")
    }

    let newSha = sha256Hex(patchedData)
    var backupPath: String?

    if !(params.dryRun ?? false) {
      backupPath = (params.backup ?? false) ? try backupExistingFile(resolved) : nil
      let permissions = mode_t(info.st_mode & 0o777)
      try atomicWrite(patchedData, to: resolved.url, permissions: permissions)
    }

    return FilePatchPayload(
      path: resolved.url.path,
      applied: edits.count,
      previousSha256: previousSha,
      sha256: newSha,
      changedLines: Array(Set(changedLines)).sorted(),
      backupPath: backupPath,
      warnings: warnings.isEmpty ? nil : warnings
    )
  }

  public func search(_ params: AgentRequestParams) throws -> FileSearchPayload {
    guard let query = params.query?.trimmingCharacters(in: .newlines), !query.isEmpty else {
      throw AgentProtocolError.invalidRequest("fs.search requires query")
    }

    let resolved = try resolve(params, defaultPath: nil)
    try ensureReadable(resolved)
    guard let targetInfo = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("Search target does not exist: \(resolved.url.path)")
    }

    let includeHidden = params.includeHidden ?? true
    let respectGitignore = params.respectGitignore ?? true
    let maxResults = min(max(params.maxResults ?? configuration.limits.maxSearchResults, 1), configuration.limits.maxSearchResults)
    let ignoreMatcher = respectGitignore ? GitignoreMatcher(root: resolved.rootPath, fileManager: fileManager) : nil
    let glob = params.glob?.trimmingCharacters(in: .whitespacesAndNewlines)
    let regex = params.regex ?? false
    let expression = try regex ? NSRegularExpression(pattern: query) : nil

    var matches: [FileSearchMatchPayload] = []
    var truncated = false

    func appendMatches(in url: URL, filterRelative: String, fileRelative: String, info: Darwin.stat) {
      guard fileType(info) == "file" else {
        return
      }
      guard globMatches(glob, relativePath: filterRelative, basename: url.lastPathComponent) else {
        return
      }
      guard info.st_size <= configuration.limits.maxReadBytes else {
        return
      }

      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        return
      }
      guard !isBinaryData(data), let text = String(data: data, encoding: .utf8) else {
        return
      }

      var lineNo = 0
      text.enumerateLines { line, stop in
        lineNo += 1
        let isMatch: Bool
        if let expression {
          let range = NSRange(location: 0, length: (line as NSString).length)
          isMatch = expression.firstMatch(in: line, options: [], range: range) != nil
        } else {
          isMatch = line.range(of: query) != nil
        }

        if isMatch {
          if matches.count < maxResults {
            matches.append(FileSearchMatchPayload(file: fileRelative, line: lineNo, text: line))
          } else {
            truncated = true
            stop = true
          }
        }
      }
    }

    switch fileType(targetInfo) {
    case "directory":
      let enumerator = fileManager.enumerator(
        at: resolved.url,
        includingPropertiesForKeys: nil,
        options: [.skipsPackageDescendants],
        errorHandler: nil
      )

      while let url = enumerator?.nextObject() as? URL {
        let relative = relativePath(for: url.path, root: resolved.rootPath)
        if shouldSkipTraversal(relativePath: relative, includeHidden: includeHidden, ignoreMatcher: ignoreMatcher) {
          if isDirectory(url.path) {
            enumerator?.skipDescendants()
          }
          continue
        }

        if isSymlink(url.path), isDirectoryFollowingSymlink(url.path) {
          enumerator?.skipDescendants()
        }

        guard let info = lstatInfo(url.path) else {
          continue
        }
        guard fileType(info) == "file" else {
          continue
        }

        let searchRelative = relativePath(for: url.path, root: resolved.url.path)
        appendMatches(in: url, filterRelative: relative, fileRelative: searchRelative, info: info)
        if truncated {
          break
        }
      }
    case "file":
      if shouldInclude(relativePath: resolved.relativePath, includeHidden: includeHidden, ignoreMatcher: ignoreMatcher) {
        appendMatches(in: resolved.url, filterRelative: resolved.relativePath, fileRelative: resolved.url.lastPathComponent, info: targetInfo)
      }
    default:
      throw AgentProtocolError.notAFile("Search target is not a file or directory: \(resolved.url.path)")
    }

    return FileSearchPayload(matches: matches, truncated: truncated)
  }

  private func resolveAbsolute(_ rawPath: String?, defaultPath: String?) throws -> String {
    canonicalPath(try resolveLexicalAbsolutePath(rawPath, defaultPath: defaultPath))
  }

  /// Standardizes `.` and `..` without following symlinks. It is used only
  /// when the lexical location itself affects authorization or error
  /// classification; regular fs actions continue through `resolveAbsolute`.
  private func resolveLexicalAbsolutePath(_ rawPath: String?, defaultPath: String? = nil) throws -> String {
    guard let raw = (rawPath ?? defaultPath)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      throw AgentProtocolError.invalidRequest("File action requires path")
    }
    let expanded = (raw as NSString).expandingTildeInPath
    guard (expanded as NSString).isAbsolutePath else {
      throw AgentProtocolError.invalidRequest("Path must be absolute")
    }
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
  }

  /// Reproduces the rule engine's longest-prefix selection using a lexical
  /// target path. Keep both spellings of the root: macOS system aliases such
  /// as `/var` may canonicalize to `/private/var`, while user-controlled child
  /// symlinks must remain visible until they are explicitly rejected.
  private func lexicalPermissionMatch(for lexicalPath: String) -> LexicalPermissionMatch? {
    var match: (value: LexicalPermissionMatch, order: Int)?

    for (order, rule) in configuration.allowedRoots.enumerated() {
      guard let lexicalRootPath = try? resolveLexicalAbsolutePath(rule.path),
            let canonicalRootPath = try? FilePermissionRuleEngine.normalizedRulePath(rule.path),
            self.path(lexicalPath, isInsideRoot: lexicalRootPath) else {
        continue
      }
      let candidate = LexicalPermissionMatch(
        lexicalRootPath: lexicalRootPath,
        canonicalRootPath: canonicalRootPath,
        mode: rule.mode
      )
      guard let current = match else {
        match = (candidate, order)
        continue
      }
      if candidate.lexicalRootPath.count > current.value.lexicalRootPath.count
        || (candidate.lexicalRootPath.count == current.value.lexicalRootPath.count && order > current.order) {
        match = (candidate, order)
      }
    }

    return match?.value
  }

  private func resolve(_ params: AgentRequestParams, defaultPath: String?) throws -> ResolvedPath {
    guard configuration.enabled else {
      throw AgentProtocolError.rootNotAllowed("File editing is disabled")
    }
    let canonical = try resolveAbsolute(params.path, defaultPath: defaultPath)
    let decision = permissionEngine.decision(for: canonical)

    guard decision.mode != .disabled else {
      throw AgentProtocolError.rootNotAllowed("No permission rule allows access to: \(canonical)")
    }

    guard let matchedRule = decision.matchedRule else {
      throw AgentProtocolError.rootNotAllowed("No permission rule allows access to: \(canonical)")
    }

    let rootPath = try FilePermissionRuleEngine.normalizedRulePath(matchedRule.path)
    let relative = relativePath(for: canonical, root: rootPath)

    try rejectSymlinkComponents(relativePath: relative, rootPath: rootPath)

    return ResolvedPath(
      rootPath: rootPath,
      relativePath: relative,
      url: URL(fileURLWithPath: canonical),
      mode: decision.mode
    )
  }

  private func ensureReadable(_ resolved: ResolvedPath) throws {
    try ensureReadable(path: resolved.url.path, mode: resolved.mode)
  }

  private func ensureReadable(path: String) throws {
    try ensureReadable(path: path, mode: permissionEngine.decision(for: path).mode)
  }

  private func ensureReadable(path: String, mode: FileEditingMode) throws {
    guard mode.canRead else {
      throw AgentProtocolError.rootNotAllowed("No permission rule allows read access to: \(path)")
    }
  }

  private func ensureWritable(_ resolved: ResolvedPath) throws {
    guard resolved.mode.canWrite else {
      throw AgentProtocolError.permissionDenied("No permission rule allows write access to: \(resolved.url.path)")
    }
  }

  private func normalizeRelativePath(_ path: String) -> String {
    let components = path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)

    if components.contains("..") {
      return ".."
    }
    if components.isEmpty {
      return "."
    }
    return components.joined(separator: "/")
  }

  private func normalizeResponsePath(_ path: String) -> String {
    path == "" ? "." : path
  }

  private func rejectSymlinkComponents(relativePath: String, rootPath: String) throws {
    guard relativePath != "." else {
      return
    }

    let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.contains("..") else {
      throw AgentProtocolError.pathOutsideRoot("Path traversal is not allowed")
    }

    var current = URL(fileURLWithPath: rootPath, isDirectory: true)
    for component in components {
      current.appendPathComponent(component)
      guard let info = lstatInfo(current.path) else {
        break
      }
      if fileType(info) == "symlink" {
        throw AgentProtocolError.pathOutsideRoot("Symlink paths are not followed by default")
      }
    }
  }

  private func readData(at url: URL, maxBytes: Int) throws -> Data {
    guard let info = lstatInfo(url.path) else {
      throw AgentProtocolError.fileNotFound("File does not exist: \(url.path)")
    }
    guard info.st_size <= maxBytes else {
      throw AgentProtocolError.fileTooLarge("File exceeds configured read limit: \(info.st_size) bytes")
    }

    do {
      return try Data(contentsOf: url)
    } catch CocoaError.fileReadNoPermission {
      throw AgentProtocolError.permissionDenied("Permission denied while reading file")
    } catch {
      throw AgentProtocolError.internalError("Unable to read file: \(error.localizedDescription)")
    }
  }

  private func atomicWrite(_ data: Data, to url: URL, permissions: mode_t) throws {
    let tempURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).okbrain.tmp.\(UUID().uuidString)")
    var removeTemp = true
    defer {
      if removeTemp {
        try? fileManager.removeItem(at: tempURL)
      }
    }

    do {
      try data.write(to: tempURL, options: [])
      chmod(tempURL.path, permissions)
      if Darwin.rename(tempURL.path, url.path) != 0 {
        let message = String(cString: strerror(errno))
        throw AgentProtocolError.permissionDenied("Unable to replace file atomically: \(message)")
      }
      removeTemp = false
    } catch let error as AgentProtocolError {
      throw error
    } catch CocoaError.fileWriteNoPermission {
      throw AgentProtocolError.permissionDenied("Permission denied while writing file")
    } catch {
      throw AgentProtocolError.internalError("Unable to write file: \(error.localizedDescription)")
    }
  }

  private func backupExistingFile(_ resolved: ResolvedPath) throws -> String {
    let timestamp = backupTimestamp()
    let backupRelative = ".okbrain-backups/\(timestamp)/\(resolved.relativePath)"
    let backupURL = URL(fileURLWithPath: resolved.rootPath, isDirectory: true).appendingPathComponent(backupRelative)

    do {
      try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fileManager.copyItem(at: resolved.url, to: backupURL)
      return backupRelative
    } catch CocoaError.fileWriteNoPermission {
      throw AgentProtocolError.permissionDenied("Permission denied while creating backup")
    } catch {
      throw AgentProtocolError.internalError("Unable to create backup: \(error.localizedDescription)")
    }
  }

  private func lineRanges(in text: String) -> [Range<String.Index>] {
    guard !text.isEmpty else {
      return []
    }

    var ranges: [Range<String.Index>] = []
    var lineStart = text.startIndex

    while lineStart < text.endIndex {
      var lineEnd = lineStart
      while lineEnd < text.endIndex, text[lineEnd] != "\n" {
        lineEnd = text.index(after: lineEnd)
      }

      if lineEnd < text.endIndex {
        let next = text.index(after: lineEnd)
        ranges.append(lineStart..<next)
        lineStart = next
      } else {
        ranges.append(lineStart..<text.endIndex)
        break
      }
    }

    return ranges
  }

  private func validateTextEncoding(_ encoding: String?) throws {
    let encoding = encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard encoding == nil || encoding == "utf-8" || encoding == "utf8" else {
      throw AgentProtocolError.unsupportedParameter("Only UTF-8 text encoding is supported")
    }
  }

  private func shouldInclude(relativePath: String, includeHidden: Bool, ignoreMatcher: GitignoreMatcher?) -> Bool {
    if !includeHidden, hasHiddenPathComponent(relativePath) {
      return false
    }
    if ignoreMatcher?.isIgnored(relativePath) == true {
      return false
    }
    return true
  }

  private func shouldSkipTraversal(relativePath: String, includeHidden: Bool, ignoreMatcher: GitignoreMatcher?) -> Bool {
    if !includeHidden, hasHiddenPathComponent(relativePath) {
      return true
    }
    if ignoreMatcher?.isIgnored(relativePath) == true {
      return true
    }
    return false
  }

  private func hasHiddenPathComponent(_ relativePath: String) -> Bool {
    relativePath.split(separator: "/").contains { $0.hasPrefix(".") }
  }

  private func globMatches(_ glob: String?, relativePath: String, basename: String) -> Bool {
    guard let glob, !glob.isEmpty else {
      return true
    }

    let target = glob.contains("/") ? relativePath : basename
    guard let regex = try? NSRegularExpression(pattern: globRegexPattern(glob), options: []) else {
      return false
    }
    let range = NSRange(location: 0, length: (target as NSString).length)
    return regex.firstMatch(in: target, options: [], range: range) != nil
  }

  private func globRegexPattern(_ glob: String) -> String {
    var pattern = "^"
    let characters = Array(glob)
    var index = 0

    while index < characters.count {
      let character = characters[index]

      if character == "*" {
        if index + 1 < characters.count, characters[index + 1] == "*" {
          if index + 2 < characters.count, characters[index + 2] == "/" {
            pattern += "(?:.*/)?"
            index += 3
          } else {
            pattern += ".*"
            index += 2
          }
        } else {
          pattern += "[^/]*"
          index += 1
        }
        continue
      }

      if character == "?" {
        pattern += "[^/]"
        index += 1
        continue
      }

      if character == "{" {
        var end = index + 1
        while end < characters.count, characters[end] != "}" {
          end += 1
        }
        if end < characters.count {
          let body = String(characters[(index + 1)..<end])
          let alternatives = body.split(separator: ",").map { NSRegularExpression.escapedPattern(for: String($0)) }
          pattern += "(" + alternatives.joined(separator: "|") + ")"
          index = end + 1
          continue
        }
      }

      pattern += NSRegularExpression.escapedPattern(for: String(character))
      index += 1
    }

    return pattern + "$"
  }

  private func canonicalPath(_ path: String) -> String {
    realPath(path) ?? URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func realPath(_ path: String) -> String? {
    guard let pointer = Darwin.realpath(path, nil) else {
      return nil
    }
    defer { free(pointer) }
    return String(cString: pointer)
  }

  private func path(_ path: String, isInsideRoot root: String) -> Bool {
    root == "/" || path == root || path.hasPrefix(root + "/")
  }

  private func relativePath(for path: String, root: String) -> String {
    guard path != root else {
      return "."
    }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    if path.hasPrefix(prefix) {
      return String(path.dropFirst(prefix.count))
    }
    return path
  }

  private func parentRelativePath(for relativePath: String) -> String {
    let parent = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
    return parent == "." || parent == "/" ? "." : parent
  }

  private func lstatInfo(_ path: String) -> Darwin.stat? {
    var info = Darwin.stat()
    guard Darwin.lstat(path, &info) == 0 else {
      return nil
    }
    return info
  }

  private func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }

  private func isDirectoryFollowingSymlink(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }

  private func isSymlink(_ path: String) -> Bool {
    guard let info = lstatInfo(path) else {
      return false
    }
    return (info.st_mode & S_IFMT) == S_IFLNK
  }

  private func fileType(_ info: Darwin.stat) -> String {
    switch info.st_mode & S_IFMT {
    case S_IFREG:
      return "file"
    case S_IFDIR:
      return "directory"
    case S_IFLNK:
      return "symlink"
    default:
      return "other"
    }
  }

  private func permissionsString(_ info: Darwin.stat) -> String {
    String(format: "%04o", info.st_mode & 0o777)
  }

  private func iso8601Date(from info: Darwin.stat) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    return Self.iso8601Formatter.string(from: date)
  }

  private func backupTimestamp() -> String {
    Self.backupDateFormatter.string(from: Date())
  }

  private func caseSensitiveVolume(at path: String) -> Bool {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values?.volumeSupportsCaseSensitiveNames ?? false
  }

  private func detectVCS(root: String) -> VCSInfoPayload? {
    let gitPath = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".git").path
    return fileManager.fileExists(atPath: gitPath) ? VCSInfoPayload(type: "git", root: root) : nil
  }

  private func isBinaryData(_ data: Data) -> Bool {
    data.contains(0) || String(data: data, encoding: .utf8) == nil
  }

  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let backupDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()
}

private struct ResolvedPath {
  let rootPath: String
  let relativePath: String
  let url: URL
  let mode: FileEditingMode
}

private struct LexicalPermissionMatch {
  let lexicalRootPath: String
  let canonicalRootPath: String
  let mode: FileEditingMode
}

private struct GitignoreMatcher {
  private let patterns: [String]

  init(root: String, fileManager: FileManager) {
    let gitignorePath = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".gitignore").path
    guard let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
      patterns = [".git/"]
      return
    }

    patterns = [".git/"] + content
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
  }

  func isIgnored(_ relativePath: String) -> Bool {
    let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let basename = URL(fileURLWithPath: normalized).lastPathComponent

    for pattern in patterns {
      let directoryOnly = pattern.hasSuffix("/")
      let cleaned = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !cleaned.isEmpty else {
        continue
      }

      if directoryOnly {
        if normalized == cleaned || normalized.hasPrefix(cleaned + "/") || basename == cleaned {
          return true
        }
        continue
      }

      if cleaned.contains("/") {
        if globMatches(pattern: cleaned, target: normalized) {
          return true
        }
      } else if globMatches(pattern: cleaned, target: basename) {
        return true
      }
    }

    return false
  }

  private func globMatches(pattern: String, target: String) -> Bool {
    let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
      .replacingOccurrences(of: "\\*", with: ".*")
      .replacingOccurrences(of: "\\?", with: ".") + "$"
    let range = NSRange(location: 0, length: (target as NSString).length)
    return (try? NSRegularExpression(pattern: regex))?.firstMatch(in: target, range: range) != nil
  }
}
