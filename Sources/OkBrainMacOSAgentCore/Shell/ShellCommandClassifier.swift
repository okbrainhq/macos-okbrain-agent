import Foundation

/// Why a shell command was hard-blocked at pre-flight (never promptable).
public enum ShellBlockKind: String, Sendable, Codable {
  /// A dangerous invocation of an otherwise-trusted tool (§4.5 arg pre-screen).
  case dangerousInvocation
  /// A privileged/administrative tool that is always blocked (§4.5).
  case privilegedTool
}

/// Pre-flight classification result (protocol/08 §4.5). Seatbelt cannot inspect
/// argv, so this is defense-in-depth, not the security boundary.
/// - `.allowed`: runs silently inside the sandbox.
/// - `.ask`: a rare, high-consequence intent gated by `ShellCapabilityCoordinator`.
/// - `.blocked`: immutable denylist; never promptable.
public enum ShellClassification: Equatable, Sendable {
  case allowed
  case ask(kind: ShellCapabilityKind, value: String, reason: String)
  case blocked(kind: ShellBlockKind, value: String, reason: String)
}

/// Agent-layer pre-screen that runs before Seatbelt. Phase 4 produces the full
/// Allow/Ask/Block tiering: out-of-tree executables and Apple-event automation
/// are Ask (rare + critical); dangerous invocations and privileged tools remain
/// a hard Block.
public struct ShellCommandClassifier: Sendable {
  /// Administrative tools that are always blocked regardless of path rules.
  public static let privilegedTools: Set<String> = [
    "sudo", "su", "doas", "launchctl", "installer", "hdiutil"
  ]

  public init() {}

  public func classify(
    command: String,
    fileRules: [FileEditingAllowedRoot]
  ) -> ShellClassification {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .blocked(kind: .dangerousInvocation, value: "", reason: "Command is empty")
    }

    // 1. Hard Block: dangerous invocations of otherwise-trusted tools.
    if let dangerous = dangerousInvocation(in: trimmed) {
      return .blocked(kind: .dangerousInvocation, value: dangerous, reason: "Blocked invocation pattern: \(dangerous)")
    }

    // 2. Ask: Apple-event automation from shell (per target application). Only
    // inline `osascript -e 'tell application "X"'` reveals its target statically;
    // script-file invocations fall through to the exec rules below (§13 note).
    if let target = appleEventTarget(in: trimmed) {
      return .ask(
        kind: .appleEventSend,
        value: target,
        reason: "Shell script sends Apple events to \(target)"
      )
    }

    // 3. Exec policy: privileged tools Block; out-of-tree absolute-path
    // executables Ask; trusted prefixes and in-rule binaries Allow.
    let allowedPrefixes = fileRules.filter { $0.mode.canRead }.map { $0.path }
    for segment in commandSegments(trimmed) {
      guard let executable = firstToken(segment) else { continue }

      if let privileged = privilegedTool(executable) {
        return .blocked(kind: .privilegedTool, value: privileged, reason: "Administrative tool '\(privileged)' is not allowed from shell")
      }

      // Only absolute-path executables are classified here; bare names resolve
      // through PATH to trusted prefixes and are left to the kernel profile.
      guard executable.hasPrefix("/") else { continue }
      let normalized = lexicalAbsolutePath(executable)
      if isUnderAnyPrefix(normalized, prefixes: SBPLProfileGenerator.trustedExecPrefixes) { continue }
      if isUnderAnyPrefix(normalized, prefixes: allowedPrefixes) { continue }

      let directory = (normalized as NSString).deletingLastPathComponent
      return .ask(
        kind: .processExec,
        value: directory.isEmpty ? "/" : directory,
        reason: "Executing \(normalized) requires approval (outside trusted prefixes)"
      )
    }

    return .allowed
  }

  // MARK: - Dangerous invocation pre-screen

  private func dangerousInvocation(in command: String) -> String? {
    let collapsed = command
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

    let patterns: [(String, String)] = [
      // rm targeting the filesystem root
      (#"\brm\b[^|;&]*\s(-[a-zA-Z]*[rRfF][a-zA-Z]*\s+)+(/(\s|$|\*))"#, "rm -rf /"),
      // dd writing to a raw device
      (#"\bdd\b[^|;&]*\bof=/dev/"#, "dd of=/dev/…"),
      // piping a download straight into a shell
      (#"(curl|wget|fetch)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, "curl|wget … | sh"),
      // recursive chmod/chown on a system root
      (#"\b(chmod|chown)\b[^|;&]*-[a-zA-Z]*R[a-zA-Z]*[^|;&]*\s/(\s|$)"#, "chmod/chown -R /"),
      // mkfs / newfs formatting
      (#"\b(mkfs|newfs)[.\w]*\b"#, "mkfs/newfs"),
      // fork bomb
      (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "fork bomb")
    ]

    for (pattern, label) in patterns {
      if collapsed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
        return label
      }
    }
    return nil
  }

  // MARK: - Apple-event detection

  /// Statically extracts the target application name from an inline
  /// `osascript`/`osacompile` `tell application "Name"` script, if present.
  private func appleEventTarget(in command: String) -> String? {
    let lowered = command.lowercased()
    guard lowered.contains("osascript") || lowered.contains("osacompile") else { return nil }
    guard let regex = try? NSRegularExpression(
      pattern: #"tell\s+(?:application|app)\s+"([^"]+)""#,
      options: [.caseInsensitive]
    ) else { return nil }
    let searchRange = NSRange(command.startIndex..., in: command)
    guard let match = regex.firstMatch(in: command, options: [], range: searchRange),
          match.numberOfRanges >= 2,
          let captureRange = Range(match.range(at: 1), in: command) else {
      return nil
    }
    let name = String(command[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }

  // MARK: - Tokenization helpers

  /// Splits a command line into simple command segments on shell separators.
  private func commandSegments(_ command: String) -> [String] {
    command
      .components(separatedBy: .newlines)
      .flatMap { $0.components(separatedBy: ";") }
      .flatMap { $0.components(separatedBy: "&&") }
      .flatMap { $0.components(separatedBy: "||") }
      .flatMap { $0.components(separatedBy: "|") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func firstToken(_ segment: String) -> String? {
    var token = segment
    // Strip leading command-substitution / subshell markers so `$( /tmp/x )`
    // and `( /tmp/x )` still classify the inner executable.
    while let first = token.first, first == "$" || first == "(" || first == "`" || first == " " {
      token.removeFirst()
    }
    let parts = token.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let head = parts.first else { return nil }
    return String(head)
  }

  private func privilegedTool(_ executable: String) -> String? {
    let base = (executable as NSString).lastPathComponent
    if Self.privilegedTools.contains(base) {
      return base
    }
    return nil
  }

  private func isUnderAnyPrefix(_ path: String, prefixes: [String]) -> Bool {
    prefixes.contains { prefix in
      if prefix == "/" { return path.hasPrefix("/") }
      return path == prefix || path.hasPrefix(prefix + "/")
    }
  }

  /// Lexically normalizes an absolute path (collapses `.`/`..` and duplicate
  /// slashes) without touching the filesystem. Used only for classification.
  private func lexicalAbsolutePath(_ path: String) -> String {
    var components: [String] = []
    for part in path.split(separator: "/") {
      switch part {
      case ".":
        continue
      case "..":
        if !components.isEmpty { components.removeLast() }
      default:
        components.append(String(part))
      }
    }
    return "/" + components.joined(separator: "/")
  }
}
