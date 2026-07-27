import AppKit
import Foundation

// MARK: - Capability model (protocol/08 §4.4)

/// The rare, high-consequence shell capabilities that gate on the Ask tier.
/// Everything else is Allow (file rules / network) or Block (§4.6).
public enum ShellCapabilityKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  /// Executing a binary outside the trusted system prefixes (§4.5) — arbitrary
  /// downloaded/generated code execution.
  case processExec
  /// Sending Apple events to another application from a shell script (per
  /// target application name), bypassing the curated `functions.*` catalog.
  case appleEventSend

  public var label: String {
    switch self {
    case .processExec: "Process Execution"
    case .appleEventSend: "Apple Event"
    }
  }

  public var summary: String {
    switch self {
    case .processExec: "Run an executable outside the trusted system prefixes."
    case .appleEventSend: "Send Apple events to another application from a shell script."
    }
  }
}

/// Persisted grant level. Absence of a rule is the default-Ask state; a stored
/// `.alwaysAllow` rule runs silently. `.ask` is an explicit "keep prompting".
public enum ShellCapabilityMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case ask
  case alwaysAllow

  public var label: String {
    switch self {
    case .ask: "Ask"
    case .alwaysAllow: "Always Allow"
    }
  }
}

public struct ShellCapabilityRule: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let kind: ShellCapabilityKind
  public let value: String
  public let mode: ShellCapabilityMode

  /// For `.processExec` the value is a path prefix (directory); for
  /// `.appleEventSend` it is the target application name.
  public var id: String { "\(kind.rawValue):\(value)" }

  public init(kind: ShellCapabilityKind, value: String, mode: ShellCapabilityMode) {
    self.kind = kind
    self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    self.mode = mode
  }
}

public struct ShellPendingCapabilityRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: ShellCapabilityKind
  public let value: String
  public let command: String
  public let context: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: ShellCapabilityKind,
    value: String,
    command: String,
    context: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.value = value
    self.command = command
    self.context = context
    self.createdAt = createdAt
  }
}

public enum ShellPendingResolution: Sendable {
  case allowOnce
  case allowAlways
  case dismiss
}

public enum ShellCapabilityDecision: Equatable, Sendable {
  case allow
  case ask
}

/// Persisted state mirror of `AXPermissionStateSnapshot`: durable rules plus
/// the bounded pending-request inbox. Session-only grants are intentionally not
/// persisted here.
public struct ShellCapabilityStateSnapshot: Codable, Equatable, Sendable {
  public let rules: [ShellCapabilityRule]
  public let pendingRequests: [ShellPendingCapabilityRequest]

  public init(rules: [ShellCapabilityRule], pendingRequests: [ShellPendingCapabilityRequest]) {
    self.rules = rules
    self.pendingRequests = pendingRequests
  }
}

// MARK: - Prompting (mirrors AXPermissionPrompting)

public enum ShellPermissionPromptResponse: Sendable {
  case allowOnce
  case allowAlways
  case notNow
  case timedOut
}

public struct ShellPermissionPromptRequest: Sendable {
  public let kind: ShellCapabilityKind
  public let value: String
  public let command: String
  public let context: String

  public init(kind: ShellCapabilityKind, value: String, command: String, context: String) {
    self.kind = kind
    self.value = value
    self.command = command
    self.context = context
  }
}

public protocol ShellPermissionPrompting: Sendable {
  func prompt(_ request: ShellPermissionPromptRequest, timeout: TimeInterval) -> ShellPermissionPromptResponse
}

/// AppKit implementation of the synchronous approval experience, mirroring
/// `SystemAXPermissionPrompter`. The socket worker waits off-main-thread while
/// the alert runs in AppKit's modal loop; declining or timing out persists no
/// negative rule.
public final class SystemShellPermissionPrompter: ShellPermissionPrompting, @unchecked Sendable {
  public init() {}

  public func prompt(_ request: ShellPermissionPromptRequest, timeout: TimeInterval) -> ShellPermissionPromptResponse {
    if Thread.isMainThread {
      return present(request, timeout: timeout)
    }

    let lock = NSLock()
    var response: ShellPermissionPromptResponse = .timedOut
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      lock.lock()
      response = self.present(request, timeout: timeout)
      lock.unlock()
      completed.signal()
    }

    let waitResult = completed.wait(timeout: .now() + max(1, timeout + 1))
    guard waitResult == .success else { return .timedOut }
    lock.lock()
    defer { lock.unlock() }
    return response
  }

  private func present(_ request: ShellPermissionPromptRequest, timeout: TimeInterval) -> ShellPermissionPromptResponse {
    guard NSApp != nil else { return .timedOut }

    if NSApp.activationPolicy() == .accessory {
      NSApp.setActivationPolicy(.regular)
    }
    if !NSApp.isActive {
      NSApp.activate()
    }
    if !NSApp.isActive {
      NSRunningApplication.current.activate()
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = messageText(for: request)
    alert.informativeText = "OkBrain Agent requests to run:\n\(request.command)\n\n\(request.context)"
    alert.addButton(withTitle: "Allow Once")
    alert.addButton(withTitle: "Always Allow")
    alert.addButton(withTitle: "Not Now")
    alert.icon = NSApp.applicationIconImage

    let effectiveTimeout = max(1, timeout)
    let deadline = Date().addingTimeInterval(effectiveTimeout)
    let countdown = NSTextField(labelWithString: "This request expires in \(Int(effectiveTimeout)) seconds.")
    countdown.textColor = .secondaryLabelColor
    countdown.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    alert.accessoryView = countdown
    let countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      let seconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
      countdown.stringValue = "This request expires in \(seconds) second\(seconds == 1 ? "" : "s")."
    }

    var didTimeOut = false
    let timeoutWork = DispatchWorkItem {
      didTimeOut = true
      NSApp.abortModal()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + effectiveTimeout, execute: timeoutWork)

    let response = alert.runModal()
    countdownTimer.invalidate()
    timeoutWork.cancel()
    if didTimeOut { return .timedOut }

    switch response {
    case .alertFirstButtonReturn: return .allowOnce
    case .alertSecondButtonReturn: return .allowAlways
    default: return .notNow
    }
  }

  private func messageText(for request: ShellPermissionPromptRequest) -> String {
    switch request.kind {
    case .processExec:
      return "Allow executing programs under \(request.value)?"
    case .appleEventSend:
      return "Allow shell automation of \(request.value)?"
    }
  }
}

// MARK: - Coordinator (mirrors AXPermissionCoordinator)

public protocol ShellCapabilityCoordinating: Sendable {
  /// Resolves an Ask-tier capability. Returns silently when the capability is
  /// already allowed (persistent rule or session grant); otherwise prompts and
  /// throws `shell_permission_required` on decline/timeout.
  func authorize(kind: ShellCapabilityKind, value: String, command: String, context: String) throws
  func snapshot() -> ShellCapabilityStateSnapshot
}

/// Thread-safe mutable state shared by the request handler and the local UI.
/// Allow-once grants remain in-process; persistent rules and pending requests
/// are emitted through `onStateChange` for UserDefaults persistence. Mirrors
/// `AXPermissionCoordinator` semantics (default-Ask, bounded deduped inbox).
public final class ShellCapabilityCoordinator: ShellCapabilityCoordinating, @unchecked Sendable {
  /// A bounded inbox prevents an unavailable foreground UI from becoming an
  /// unbounded remote-memory queue. Repeated retries for the same kind/value
  /// share one pending request.
  public static let maximumPendingRequestCount = 50
  public static let promptTimeout: TimeInterval = 15

  private let lock = NSLock()
  private let prompter: ShellPermissionPrompting
  private let onStateChange: (@Sendable (ShellCapabilityStateSnapshot) -> Void)?
  private var rules: [ShellCapabilityRule]
  private var pendingRequests: [ShellPendingCapabilityRequest]
  /// Session-only Allow Once grants (kind+value; mode is irrelevant here).
  private var sessionGrants: [ShellCapabilityRule] = []

  public init(
    rules: [ShellCapabilityRule] = [],
    pendingRequests: [ShellPendingCapabilityRequest] = [],
    prompter: ShellPermissionPrompting = SystemShellPermissionPrompter(),
    onStateChange: (@Sendable (ShellCapabilityStateSnapshot) -> Void)? = nil
  ) {
    self.rules = Self.normalizedRules(rules)
    self.pendingRequests = Self.sanitizedPendingRequests(pendingRequests)
    self.prompter = prompter
    self.onStateChange = onStateChange
  }

  public func snapshot() -> ShellCapabilityStateSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return ShellCapabilityStateSnapshot(rules: rules, pendingRequests: pendingRequests)
  }

  /// Replacing the persistent rules immediately drops any pending request that
  /// is now satisfied by an Always Allow rule.
  public func replaceRules(_ nextRules: [ShellCapabilityRule]) {
    lock.lock()
    rules = Self.normalizedRules(nextRules)
    pendingRequests.removeAll { request in
      currentDecisionLocked(kind: request.kind, value: request.value) == .allow
    }
    let snapshot = ShellCapabilityStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
  }

  @discardableResult
  public func resolvePendingRequest(id: UUID, resolution: ShellPendingResolution) -> Bool {
    lock.lock()
    guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return false
    }
    let request = pendingRequests.remove(at: index)
    switch resolution {
    case .allowOnce:
      grantSessionLocked(kind: request.kind, value: request.value)
    case .allowAlways:
      replaceOrAppendRuleLocked(kind: request.kind, value: request.value, mode: .alwaysAllow)
    case .dismiss:
      break
    }
    let snapshot = ShellCapabilityStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  public func authorize(kind: ShellCapabilityKind, value: String, command: String, context: String) throws {
    lock.lock()
    let decision = currentDecisionLocked(kind: kind, value: value)
    lock.unlock()
    guard decision == .ask else { return }

    let response = prompter.prompt(
      ShellPermissionPromptRequest(kind: kind, value: value, command: command, context: context),
      timeout: Self.promptTimeout
    )

    switch response {
    case .allowOnce:
      lock.lock()
      grantSessionLocked(kind: kind, value: value)
      let didRemovePending = removeSatisfiedPendingLocked(kind: kind, value: value)
      let snapshot = didRemovePending ? ShellCapabilityStateSnapshot(rules: rules, pendingRequests: pendingRequests) : nil
      lock.unlock()
      if let snapshot { onStateChange?(snapshot) }
    case .allowAlways:
      lock.lock()
      replaceOrAppendRuleLocked(kind: kind, value: value, mode: .alwaysAllow)
      _ = removeSatisfiedPendingLocked(kind: kind, value: value)
      let snapshot = ShellCapabilityStateSnapshot(rules: rules, pendingRequests: pendingRequests)
      lock.unlock()
      onStateChange?(snapshot)
    case .notNow:
      throw permissionRequiredError(kind: kind, value: value, command: command, pending: false)
    case .timedOut:
      let queued = enqueuePending(kind: kind, value: value, command: command, context: context)
      throw permissionRequiredError(kind: kind, value: value, command: command, pending: queued)
    }
  }

  // MARK: - Decision

  private func currentDecisionLocked(kind: ShellCapabilityKind, value: String) -> ShellCapabilityDecision {
    if sessionGrants.contains(where: { Self.matches(ruleKind: $0.kind, ruleValue: $0.value, kind: kind, value: value) }) {
      return .allow
    }
    let matching = rules.filter { Self.matches(ruleKind: $0.kind, ruleValue: $0.value, kind: kind, value: value) }
    if let mostSpecific = matching.max(by: { $0.value.count < $1.value.count }),
       mostSpecific.mode == .alwaysAllow {
      return .allow
    }
    return .ask
  }

  private func grantSessionLocked(kind: ShellCapabilityKind, value: String) {
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionGrants.contains(where: { $0.kind == kind && $0.value == normalizedValue }) else { return }
    sessionGrants.append(ShellCapabilityRule(kind: kind, value: normalizedValue, mode: .alwaysAllow))
  }

  private func replaceOrAppendRuleLocked(kind: ShellCapabilityKind, value: String, mode: ShellCapabilityMode) {
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    rules.removeAll { $0.kind == kind && $0.value == normalizedValue }
    rules.append(ShellCapabilityRule(kind: kind, value: normalizedValue, mode: mode))
    rules = Self.normalizedRules(rules)
  }

  @discardableResult
  private func removeSatisfiedPendingLocked(kind: ShellCapabilityKind, value: String) -> Bool {
    let originalCount = pendingRequests.count
    pendingRequests.removeAll { request in
      request.kind == kind
        && request.value == value
        && currentDecisionLocked(kind: request.kind, value: request.value) == .allow
    }
    return pendingRequests.count != originalCount
  }

  /// Returns true when the request is represented in the bounded pending list
  /// (either added or already deduplicated). A full queue is reported as not
  /// pending so the remote side never receives a false promise.
  private func enqueuePending(kind: ShellCapabilityKind, value: String, command: String, context: String) -> Bool {
    let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedValue.isEmpty else { return false }
    lock.lock()
    if pendingRequests.contains(where: { $0.kind == kind && $0.value == normalizedValue }) {
      lock.unlock()
      return true
    }
    guard pendingRequests.count < Self.maximumPendingRequestCount else {
      lock.unlock()
      return false
    }
    pendingRequests.append(ShellPendingCapabilityRequest(
      kind: kind,
      value: normalizedValue,
      command: Self.bounded(command, 1000),
      context: context
    ))
    let snapshot = ShellCapabilityStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  private func permissionRequiredError(
    kind: ShellCapabilityKind,
    value: String,
    command: String,
    pending: Bool
  ) -> AgentProtocolError {
    let message: String
    switch kind {
    case .processExec:
      message = "Executing programs under \(value) requires local approval"
    case .appleEventSend:
      message = "Shell automation of \(value) requires local approval"
    }
    return AgentProtocolError.shellPermissionRequired(
      message,
      details: .object(
        "kind", .string(kind.rawValue),
        "value", .string(value),
        "command", .string(Self.bounded(command, 1000)),
        "pending", .bool(pending)
      )
    )
  }

  // MARK: - Matching & normalization

  /// A rule matches a requested capability when kinds agree and the value is
  /// covered. `.processExec` uses path-prefix semantics (a rule for `/tmp`
  /// covers `/tmp/foo`); `.appleEventSend` is a case-insensitive exact match.
  private static func matches(
    ruleKind: ShellCapabilityKind,
    ruleValue: String,
    kind: ShellCapabilityKind,
    value: String
  ) -> Bool {
    guard ruleKind == kind else { return false }
    switch kind {
    case .processExec:
      let rule = ruleValue.hasSuffix("/") ? String(ruleValue.dropLast()) : ruleValue
      return value == rule || value.hasPrefix(rule + "/")
    case .appleEventSend:
      return ruleValue.caseInsensitiveCompare(value) == .orderedSame
    }
  }

  private static func normalizedRules(_ input: [ShellCapabilityRule]) -> [ShellCapabilityRule] {
    var deduplicated: [String: ShellCapabilityRule] = [:]
    for rule in input {
      let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { continue }
      let normalized = ShellCapabilityRule(kind: rule.kind, value: value, mode: rule.mode)
      deduplicated[normalized.id] = normalized
    }
    return deduplicated.values.sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
      return lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
    }
  }

  private static func sanitizedPendingRequests(_ input: [ShellPendingCapabilityRequest]) -> [ShellPendingCapabilityRequest] {
    var seen = Set<String>()
    var sanitized: [ShellPendingCapabilityRequest] = []
    for request in input {
      let value = request.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { continue }
      let key = "\(request.kind.rawValue):\(value)"
      guard seen.insert(key).inserted else { continue }
      sanitized.append(ShellPendingCapabilityRequest(
        id: request.id,
        kind: request.kind,
        value: value,
        command: bounded(request.command, 1000),
        context: request.context,
        createdAt: request.createdAt
      ))
      if sanitized.count == maximumPendingRequestCount { break }
    }
    return sanitized
  }

  private static func bounded(_ value: String, _ limit: Int) -> String {
    value.count > limit ? String(value.prefix(limit)) + "…" : value
  }
}
