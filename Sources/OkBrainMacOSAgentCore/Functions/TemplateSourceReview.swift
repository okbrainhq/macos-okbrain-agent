import AppKit
import CryptoKit
import Foundation

/// Resolves a literal AppleScript application-id target during local template
/// approval. Resolution is deliberately injectable so approval behavior can be
/// covered without depending on the host's installed apps.
public protocol TemplateTargetResolving: Sendable {
  func resolveTemplateTarget(bundleID: String) -> FunctionTarget?
}

public final class SystemTemplateTargetResolver: TemplateTargetResolving, @unchecked Sendable {
  public init() {}

  public func resolveTemplateTarget(bundleID: String) -> FunctionTarget? {
    let normalizedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedBundleID.isEmpty,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedBundleID) else {
      return nil
    }

    let installedBundleID = Bundle(url: url)?.bundleIdentifier ?? normalizedBundleID
    guard installedBundleID.caseInsensitiveCompare(normalizedBundleID) == .orderedSame else {
      return nil
    }

    let appName = FileManager.default.displayName(atPath: url.path)
    return FunctionTarget(
      bundleID: installedBundleID,
      appName: appName.isEmpty ? installedBundleID : appName,
      requiresAutomation: true
    )
  }
}

/// Immutable metadata derived from the exact source the local user reviewed.
public struct ReviewedTemplateSource: Equatable, Sendable {
  public let sourceDigest: String
  public let target: FunctionTarget
  public let argumentNames: [String]

  public init(sourceDigest: String, target: FunctionTarget, argumentNames: [String]) {
    self.sourceDigest = sourceDigest
    self.target = target
    self.argumentNames = argumentNames
  }
}

/// A deliberately small, fail-closed language boundary for proposal templates.
/// This is lexical validation rather than an AppleScript parser, so it accepts
/// only one literal `tell application id "…"` block and rejects constructs that
/// could dynamically execute source, escape into a shell, or retarget events.
public enum TemplateSourceReview {
  public static let maximumSourceBytes = 20_000

  public static func digest(for source: String) -> String {
    SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public static func review(
    source: String,
    targetResolver: TemplateTargetResolving
  ) throws -> ReviewedTemplateSource {
    guard !source.isEmpty, source.utf8.count <= maximumSourceBytes else {
      throw invalidTemplate("exampleScript", "Provide a non-empty AppleScript template of at most \(maximumSourceBytes) UTF-8 bytes.")
    }
    guard source.unicodeScalars.allSatisfy({ scalar in
      scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
    }) else {
      throw invalidTemplate("exampleScript", "Control characters are not allowed in approved templates.")
    }
    guard !source.contains("¬"), !source.contains("(*"), !source.contains("*)"), !source.contains("--") else {
      throw invalidTemplate("exampleScript", "Comments and line continuations are not allowed in approved templates.")
    }
    guard !source.contains("«"), !source.contains("»") else {
      throw invalidTemplate("exampleScript", "Raw Apple Event syntax is not allowed in approved templates.")
    }

    let compact = source
      .precomposedStringWithCompatibilityMapping
      .lowercased()
      .unicodeScalars
      .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != ";" }
      .map(String.init)
      .joined()
    let forbiddenCompactTerms = [
      "doshellscript",
      "withadministratorprivileges",
      "osascript",
      "runscript",
      "loadscript",
      "usescriptingadditions",
      "usingtermsfrom",
      "openforaccess",
      "currentapplication"
    ]
    if let forbidden = forbiddenCompactTerms.first(where: { compact.contains($0) }) {
      throw invalidTemplate("exampleScript", "Contains forbidden construct '\(forbidden)'.")
    }

    let forbiddenPatterns = [
      #"(?i)\bscript\b"#,
      #"(?i)\bon\s+(run|open|idle|quit|error)\b"#,
      #"(?i)\b(path\s+to|posix\s+file|system\s+attribute)\b"#
    ]
    for pattern in forbiddenPatterns where matches(pattern, in: source) {
      throw invalidTemplate("exampleScript", "Contains a disallowed dynamic or file-system construct.")
    }

    // There may be exactly one direct application target. Counting every tell
    // is intentionally conservative: nested tells make target review ambiguous.
    guard matchCount(#"(?i)\btell\b"#, in: source) == 2,
          matchCount(#"(?i)\bend\s+tell\b"#, in: source) == 1,
          matchCount(#"(?i)\btell\s+application\b"#, in: source) == 1 else {
      throw invalidTemplate("exampleScript", "Templates must contain exactly one application target.")
    }

    let pattern = #"(?is)^\s*tell\s+application\s+id\s+"([A-Za-z0-9][A-Za-z0-9.-]{1,254})"\s*(.*?)\s*end\s+tell\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          match.range == NSRange(source.startIndex..., in: source),
          let bundleRange = Range(match.range(at: 1), in: source),
          let bodyRange = Range(match.range(at: 2), in: source),
          !source[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw invalidTemplate(
        "exampleScript",
        "Use one literal tell application id \"bundle.id\" … end tell block; dynamic or multi-target scripts are not approvable."
      )
    }

    let bundleID = String(source[bundleRange])
    let prohibitedTargets = ["com.apple.systemevents", "com.apple.scripteditor2", "com.apple.automator"]
    guard !prohibitedTargets.contains(bundleID.lowercased()) else {
      throw invalidTemplate("exampleScript", "The requested application target is not allowed for stored templates.")
    }
    guard let resolvedTarget = targetResolver.resolveTemplateTarget(bundleID: bundleID),
          resolvedTarget.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
          !resolvedTarget.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw invalidTemplate("exampleScript", "The literal target '\(bundleID)' is not an installed, uniquely resolved application.")
    }

    return ReviewedTemplateSource(
      sourceDigest: digest(for: source),
      target: FunctionTarget(
        bundleID: resolvedTarget.bundleID,
        appName: resolvedTarget.appName,
        requiresAutomation: true
      ),
      argumentNames: placeholderNames(in: source)
    )
  }

  public static func placeholderNames(in source: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: "\\$([A-Za-z_][A-Za-z0-9_]*)")
    let fullRange = NSRange(source.startIndex..., in: source)
    var seen = Set<String>()
    return regex.matches(in: source, options: [], range: fullRange).compactMap { match in
      guard let range = Range(match.range(at: 1), in: source) else { return nil }
      let name = String(source[range])
      return seen.insert(name).inserted ? name : nil
    }
  }

  private static func matches(_ pattern: String, in source: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
    return regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
  }

  private static func matchCount(_ pattern: String, in source: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return Int.max }
    return regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
  }

  private static func invalidTemplate(_ argument: String, _ reason: String) -> AgentProtocolError {
    invalidArgsError("Proposal validation failed", violations: [.init(argument: argument, reason: reason)])
  }
}
