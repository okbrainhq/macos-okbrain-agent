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
}

public final class LocalFileEditingService: FileEditingServicing, @unchecked Sendable {
  private let configuration: FileEditingConfiguration
  private let fileManager: FileManager

  public init(configuration: FileEditingConfiguration, fileManager: FileManager = .default) {
    self.configuration = configuration
    self.fileManager = fileManager
  }

  public func describeWorkspace(_ params: AgentRequestParams) throws -> WorkspaceDescribePayload {
    let root = try allowedRoot(for: params.root, requireExisting: false)
    let exists = isDirectory(root.canonicalPath)
    return WorkspaceDescribePayload(
      root: root.canonicalPath,
      exists: exists,
      mode: root.mode,
      caseSensitive: caseSensitiveVolume(at: root.canonicalPath),
      vcs: detectVCS(root: root.canonicalPath)
    )
  }

  public func stat(_ params: AgentRequestParams) throws -> FileStatPayload {
    let resolved = try resolve(params, defaultPath: nil, requireExistingRoot: true)
    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("Target does not exist: \(resolved.relativePath)")
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
      path: resolved.relativePath,
      type: type,
      size: Int64(info.st_size),
      mtime: iso8601Date(from: info),
      sha256: sha256,
      isBinary: isBinary,
      permissions: permissionsString(info)
    )
  }

  public func list(_ params: AgentRequestParams) throws -> FileListPayload {
    let resolved = try resolve(params, defaultPath: ".", requireExistingRoot: true)
    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("Directory does not exist: \(resolved.relativePath)")
    }
    guard fileType(info) == "directory" else {
      throw AgentProtocolError.notADirectory("List target is not a directory: \(resolved.relativePath)")
    }

    let recursive = params.recursive ?? false
    let includeHidden = params.includeHidden ?? false
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

      entries.append(FileListEntryPayload(
        path: relative,
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
    let resolved = try resolve(params, defaultPath: nil, requireExistingRoot: true)
    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("File does not exist: \(resolved.relativePath)")
    }
    guard fileType(info) == "file" else {
      throw AgentProtocolError.notAFile("Read target is not a file: \(resolved.relativePath)")
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
      path: resolved.relativePath,
      content: selectedContent,
      encoding: "utf-8",
      lineCount: totalLines,
      range: FileReadRangePayload(startLine: actualStart, endLine: actualEnd),
      sha256: sha256Hex(data),
      truncated: false
    )
  }

  public func write(_ params: AgentRequestParams) throws -> FileWritePayload {
    let resolved = try resolve(params, defaultPath: nil, requireExistingRoot: true)
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
      throw AgentProtocolError.notAFile("Write target is not a file: \(resolved.relativePath)")
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
      throw AgentProtocolError.fileNotFound("Parent directory does not exist: \(parentRelativePath(for: resolved.relativePath))")
    }

    let backupPath = (params.backup ?? false) && existingInfo != nil ? try backupExistingFile(resolved) : nil
    let permissions = existingInfo.map { mode_t($0.st_mode & 0o777) } ?? mode_t(0o644)
    try atomicWrite(data, to: resolved.url, permissions: permissions)

    return FileWritePayload(
      path: resolved.relativePath,
      bytesWritten: data.count,
      previousSha256: previousSha,
      sha256: sha256Hex(data),
      backupPath: backupPath
    )
  }

  public func patch(_ params: AgentRequestParams) throws -> FilePatchPayload {
    let resolved = try resolve(params, defaultPath: nil, requireExistingRoot: true)
    try ensureWritable(resolved)
    try validateTextEncoding(params.encoding)

    guard let edits = params.edits, !edits.isEmpty else {
      throw AgentProtocolError.invalidRequest("fs.patch requires at least one edit")
    }

    guard let info = lstatInfo(resolved.url.path) else {
      throw AgentProtocolError.fileNotFound("File does not exist: \(resolved.relativePath)")
    }
    guard fileType(info) == "file" else {
      throw AgentProtocolError.notAFile("Patch target is not a file: \(resolved.relativePath)")
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
    var changedLines: [Int] = []

    for edit in edits {
      let match = try findPatchMatch(edit, in: text, whitespaceNormalizedFallback: fallback)
      changedLines.append(lineNumber(at: match.lowerBound, in: text))
      text.replaceSubrange(match, with: edit.newText)
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
      path: resolved.relativePath,
      applied: edits.count,
      previousSha256: previousSha,
      sha256: newSha,
      changedLines: Array(Set(changedLines)).sorted(),
      backupPath: backupPath
    )
  }

  public func search(_ params: AgentRequestParams) throws -> FileSearchPayload {
    guard let query = params.query?.trimmingCharacters(in: .newlines), !query.isEmpty else {
      throw AgentProtocolError.invalidRequest("fs.search requires query")
    }

    let resolved = try resolve(params, defaultPath: ".", requireExistingRoot: true)
    guard isDirectory(resolved.url.path) else {
      throw AgentProtocolError.notADirectory("Search target is not a directory: \(resolved.relativePath)")
    }

    let includeHidden = params.includeHidden ?? false
    let respectGitignore = params.respectGitignore ?? true
    let maxResults = min(max(params.maxResults ?? configuration.limits.maxSearchResults, 1), configuration.limits.maxSearchResults)
    let ignoreMatcher = respectGitignore ? GitignoreMatcher(root: resolved.rootPath, fileManager: fileManager) : nil
    let glob = params.glob?.trimmingCharacters(in: .whitespacesAndNewlines)
    let regex = params.regex ?? false
    let expression = try regex ? NSRegularExpression(pattern: query) : nil

    var matches: [FileSearchMatchPayload] = []
    var truncated = false

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

      guard let info = lstatInfo(url.path) else {
        continue
      }

      if fileType(info) == "directory" {
        continue
      }
      guard fileType(info) == "file" else {
        continue
      }
      guard globMatches(glob, relativePath: relative, basename: url.lastPathComponent) else {
        continue
      }
      guard info.st_size <= configuration.limits.maxReadBytes else {
        continue
      }

      let data: Data
      do {
        data = try Data(contentsOf: url)
      } catch {
        continue
      }
      guard !isBinaryData(data), let text = String(data: data, encoding: .utf8) else {
        continue
      }

      var lineNo = 0
      var shouldStopFile = false
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
            matches.append(FileSearchMatchPayload(path: relative, line: lineNo, text: line))
          } else {
            truncated = true
            shouldStopFile = true
            stop = true
          }
        }
      }

      if shouldStopFile || truncated {
        break
      }
    }

    return FileSearchPayload(matches: matches, truncated: truncated)
  }

  private func allowedRoot(for rawRoot: String?, requireExisting: Bool) throws -> RootContext {
    guard configuration.enabled else {
      throw AgentProtocolError.rootNotAllowed("File editing is disabled or no roots are approved")
    }
    guard let rawRoot = rawRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !rawRoot.isEmpty else {
      throw AgentProtocolError.rootRequired("File actions require root")
    }

    let requestedPath = (rawRoot as NSString).expandingTildeInPath
    guard (requestedPath as NSString).isAbsolutePath else {
      throw AgentProtocolError.rootNotAllowed("Root must be an absolute path")
    }

    let requestedCanonical = canonicalPath(requestedPath)
    for allowed in configuration.allowedRoots {
      let allowedPath = (allowed.path as NSString).expandingTildeInPath
      let allowedCanonical = canonicalPath(allowedPath)
      if requestedCanonical == allowedCanonical {
        if requireExisting, !isDirectory(allowedCanonical) {
          throw AgentProtocolError.fileNotFound("Approved root does not exist: \(allowedCanonical)")
        }
        return RootContext(canonicalPath: allowedCanonical, mode: allowed.mode)
      }
    }

    throw AgentProtocolError.rootNotAllowed("Root is not approved in the macOS app: \(requestedPath)")
  }

  private func resolve(_ params: AgentRequestParams, defaultPath: String?, requireExistingRoot: Bool) throws -> ResolvedPath {
    let root = try allowedRoot(for: params.root, requireExisting: requireExistingRoot)
    let rawRelative = (params.path ?? defaultPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawRelative.isEmpty else {
      throw AgentProtocolError.invalidRequest("File action requires path")
    }
    guard !(rawRelative as NSString).isAbsolutePath else {
      throw AgentProtocolError.pathOutsideRoot("Path must be root-relative")
    }

    let normalizedRelative = normalizeRelativePath(rawRelative)
    let rootURL = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
    let targetURL = rootURL.appendingPathComponent(normalizedRelative).standardized
    guard path(targetURL.path, isInsideRoot: root.canonicalPath) else {
      throw AgentProtocolError.pathOutsideRoot("Resolved path escapes the configured project root")
    }

    try rejectSymlinkComponents(relativePath: normalizedRelative, rootPath: root.canonicalPath)

    return ResolvedPath(
      rootPath: root.canonicalPath,
      relativePath: normalizeResponsePath(relativePath(for: targetURL.path, root: root.canonicalPath)),
      url: targetURL,
      mode: root.mode
    )
  }

  private func ensureWritable(_ resolved: ResolvedPath) throws {
    guard resolved.mode.canWrite else {
      throw AgentProtocolError.permissionDenied("The approved root is read-only")
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
      guard fileManager.fileExists(atPath: current.path) else {
        break
      }
      if isSymlink(current.path) {
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

  private func findPatchMatch(
    _ edit: FilePatchEdit,
    in text: String,
    whitespaceNormalizedFallback: Bool
  ) throws -> Range<String.Index> {
    guard !edit.oldText.isEmpty else {
      throw AgentProtocolError.invalidRequest("Patch oldText must not be empty")
    }

    var ranges = exactRanges(of: edit.oldText, in: text, startLine: edit.startLine)
    if ranges.isEmpty, whitespaceNormalizedFallback {
      ranges = normalizedWhitespaceRanges(of: edit.oldText, in: text, startLine: edit.startLine)
    }

    guard !ranges.isEmpty else {
      throw AgentProtocolError.patchNotFound("Patch oldText was not found")
    }
    guard ranges.count == 1 else {
      throw AgentProtocolError.ambiguousPatch("Patch oldText matched multiple locations; provide startLine")
    }
    return ranges[0]
  }

  private func exactRanges(of needle: String, in haystack: String, startLine: Int?) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchRange = haystack.startIndex..<haystack.endIndex

    while let range = haystack.range(of: needle, options: [], range: searchRange) {
      if startLine == nil || lineNumber(at: range.lowerBound, in: haystack) == startLine {
        ranges.append(range)
      }
      guard range.upperBound < haystack.endIndex else {
        break
      }
      searchRange = range.upperBound..<haystack.endIndex
    }

    return ranges
  }

  private func normalizedWhitespaceRanges(of needle: String, in haystack: String, startLine: Int?) -> [Range<String.Index>] {
    let normalizedHaystack = normalizeTrailingWhitespaceAndLineEndingsWithMap(haystack)
    let normalizedNeedle = normalizeTrailingWhitespaceAndLineEndingsWithMap(needle).text
    guard !normalizedNeedle.isEmpty else {
      return []
    }

    var ranges: [Range<String.Index>] = []
    var searchRange = normalizedHaystack.text.startIndex..<normalizedHaystack.text.endIndex

    while let range = normalizedHaystack.text.range(of: normalizedNeedle, options: [], range: searchRange) {
      let lowerOffset = normalizedHaystack.text.distance(from: normalizedHaystack.text.startIndex, to: range.lowerBound)
      let upperOffset = normalizedHaystack.text.distance(from: normalizedHaystack.text.startIndex, to: range.upperBound)
      guard lowerOffset < normalizedHaystack.map.count else {
        break
      }

      let originalStart = normalizedHaystack.map[lowerOffset]
      let originalEnd = upperOffset < normalizedHaystack.map.count ? normalizedHaystack.map[upperOffset] : haystack.endIndex
      let originalRange = originalStart..<originalEnd
      if startLine == nil || lineNumber(at: originalStart, in: haystack) == startLine {
        ranges.append(originalRange)
      }

      guard range.upperBound < normalizedHaystack.text.endIndex else {
        break
      }
      searchRange = range.upperBound..<normalizedHaystack.text.endIndex
    }

    return ranges
  }

  private func normalizeTrailingWhitespaceAndLineEndingsWithMap(_ source: String) -> (text: String, map: [String.Index]) {
    var normalized = ""
    var map: [String.Index] = []
    var lineStart = source.startIndex

    while lineStart < source.endIndex {
      var lineEnd = lineStart
      var newlineIndex: String.Index?

      while lineEnd < source.endIndex {
        let character = source[lineEnd]
        if character == "\n" || character == "\r" {
          newlineIndex = lineEnd
          break
        }
        lineEnd = source.index(after: lineEnd)
      }

      var trimEnd = lineEnd
      while trimEnd > lineStart {
        let previous = source.index(before: trimEnd)
        if source[previous] == " " || source[previous] == "\t" {
          trimEnd = previous
        } else {
          break
        }
      }

      var index = lineStart
      while index < trimEnd {
        normalized.append(source[index])
        map.append(index)
        index = source.index(after: index)
      }

      if let newlineIndex {
        normalized.append("\n")
        map.append(newlineIndex)
        var next = source.index(after: newlineIndex)
        if source[newlineIndex] == "\r", next < source.endIndex, source[next] == "\n" {
          next = source.index(after: next)
        }
        lineStart = next
      } else {
        lineStart = source.endIndex
      }
    }

    return (normalized, map)
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

  private func lineNumber(at index: String.Index, in text: String) -> Int {
    text[..<index].reduce(1) { count, character in
      character == "\n" ? count + 1 : count
    }
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
    path == root || path.hasPrefix(root + "/")
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

private struct RootContext {
  let canonicalPath: String
  let mode: FileEditingMode
}

private struct ResolvedPath {
  let rootPath: String
  let relativePath: String
  let url: URL
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
