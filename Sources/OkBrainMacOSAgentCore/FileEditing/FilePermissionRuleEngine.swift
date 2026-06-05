import Darwin
import Foundation

public enum FileAccessIntent: Equatable, Sendable {
  case read
  case write
}

public struct FilePermissionDecision: Equatable, Sendable {
  public let path: String
  public let mode: FileEditingMode
  public let matchedRule: FileEditingAllowedRoot?

  public var canRead: Bool {
    mode.canRead
  }

  public var canWrite: Bool {
    mode.canWrite
  }

  public init(path: String, mode: FileEditingMode, matchedRule: FileEditingAllowedRoot?) {
    self.path = path
    self.mode = mode
    self.matchedRule = matchedRule
  }
}

public struct FilePermissionRuleEngine: Sendable {
  private let normalizedRules: [NormalizedPermissionRule]

  public init(rules: [FileEditingAllowedRoot]) {
    normalizedRules = rules.enumerated().compactMap { index, rule in
      guard let normalizedPath = Self.normalizedAbsolutePath(rule.path) else {
        return nil
      }

      return NormalizedPermissionRule(
        path: normalizedPath,
        mode: rule.mode,
        originalRule: FileEditingAllowedRoot(path: normalizedPath, mode: rule.mode),
        order: index
      )
    }
  }

  public func decision(for absolutePath: String) -> FilePermissionDecision {
    guard let normalizedPath = Self.normalizedAbsolutePath(absolutePath) else {
      return FilePermissionDecision(path: absolutePath, mode: .disabled, matchedRule: nil)
    }

    let matchedRule = normalizedRules
      .filter { Self.path(normalizedPath, isInsideOrEqualTo: $0.path) }
      .max { lhs, rhs in
        if lhs.path.count == rhs.path.count {
          return lhs.order < rhs.order
        }
        return lhs.path.count < rhs.path.count
      }

    return FilePermissionDecision(
      path: normalizedPath,
      mode: matchedRule?.mode ?? .disabled,
      matchedRule: matchedRule?.originalRule
    )
  }

  public func allows(_ intent: FileAccessIntent, to absolutePath: String) -> Bool {
    let decision = decision(for: absolutePath)
    switch intent {
    case .read:
      return decision.canRead
    case .write:
      return decision.canWrite
    }
  }

  public static func normalizedRulePath(_ rawPath: String) throws -> String {
    guard let normalizedPath = normalizedAbsolutePath(rawPath) else {
      throw AgentProtocolError.invalidRequest("Permission rule paths must be absolute folders")
    }

    return normalizedPath
  }

  static func normalizedAbsolutePath(_ rawPath: String) -> String? {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let expanded = (trimmed as NSString).expandingTildeInPath
    guard (expanded as NSString).isAbsolutePath else {
      return nil
    }

    return realPath(expanded) ?? URL(fileURLWithPath: expanded).standardizedFileURL.path
  }

  private static func realPath(_ path: String) -> String? {
    guard let pointer = Darwin.realpath(path, nil) else {
      return nil
    }
    defer { free(pointer) }
    return String(cString: pointer)
  }

  private static func path(_ path: String, isInsideOrEqualTo rulePath: String) -> Bool {
    if rulePath == "/" {
      return path.hasPrefix("/")
    }

    return path == rulePath || path.hasPrefix(rulePath + "/")
  }
}

private struct NormalizedPermissionRule: Equatable, Sendable {
  let path: String
  let mode: FileEditingMode
  let originalRule: FileEditingAllowedRoot
  let order: Int
}
