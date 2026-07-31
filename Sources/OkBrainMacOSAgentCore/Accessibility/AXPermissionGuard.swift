import AppKit
import Foundation

/// Persistent access levels. There is intentionally no stored Deny mode: no
/// rule is the default-deny state. Control includes all Observe access.
public enum AXAppPermissionMode: String, Codable, CaseIterable, Equatable, Sendable {
  case observe
  case control

  public var label: String {
    switch self {
    case .observe: "Observe"
    case .control: "Control"
    }
  }

  fileprivate func allows(_ intent: AXPermissionIntent) -> Bool {
    switch (self, intent) {
    case (.control, _), (.observe, .observe): true
    case (.observe, .control): false
    }
  }

  fileprivate static func strongest(_ lhs: AXAppPermissionMode?, _ rhs: AXAppPermissionMode?) -> AXAppPermissionMode? {
    switch (lhs, rhs) {
    case (.control, _), (_, .control): .control
    case (.observe, _), (_, .observe): .observe
    case (nil, nil): nil
    }
  }
}

public enum AXPermissionIntent: String, Codable, Equatable, Sendable {
  case observe
  case control

  public var label: String {
    switch self {
    case .observe: "Observe"
    case .control: "Control"
    }
  }

  fileprivate var requiredMode: AXAppPermissionMode {
    switch self {
    case .observe: .observe
    case .control: .control
    }
  }
}

/// A permission target is either a real application identity or a curated
/// global capability. Categories are not fake bundle identifiers: their kind
/// remains explicit through persistence, prompts, and dispatch.
public enum PermissionTargetKind: String, Codable, CaseIterable, Equatable, Sendable {
  case application
  case category

  public var label: String {
    switch self {
    case .application: "Application"
    case .category: "Global capability"
    }
  }
}

/// Stable categories for curated functions that do not operate on a specific
/// application. Keep these exhaustive and user-visible in the App Control UI.
public enum GlobalPermissionCategory: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
  case applicationDiscovery = "application-discovery"
  case menuBarExtras = "menu-bar-extras"
  case systemAudio = "system-audio"
  case clipboard
  case power
  case network
  case notifications
  case dialogs
  case display

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .applicationDiscovery: "Application Discovery"
    case .menuBarExtras: "Menu Bar Extras"
    case .systemAudio: "System Audio"
    case .clipboard: "Clipboard"
    case .power: "Power & Battery"
    case .network: "Network Information"
    case .notifications: "Notifications"
    case .dialogs: "User Dialogs"
    case .display: "Displays"
    }
  }

  public var summary: String {
    switch self {
    case .applicationDiscovery: "List running applications through app.list or ax.list-apps."
    case .menuBarExtras: "List status items from all running applications' menu bar extras."
    case .systemAudio: "Read or change system output volume and mute state."
    case .clipboard: "Read or replace plain-text clipboard contents."
    case .power: "Read battery capacity and charging state."
    case .network: "Read the current Wi-Fi network name."
    case .notifications: "Show notifications branded as OkBrain Agent."
    case .dialogs: "Show local OkBrain Agent dialogs and return the response."
    case .display: "Read connected display geometry and scale factors."
    }
  }

  public var symbolName: String {
    switch self {
    case .applicationDiscovery: "rectangle.stack"
    case .menuBarExtras: "menubar.rectangle"
    case .systemAudio: "speaker.wave.2"
    case .clipboard: "doc.on.clipboard"
    case .power: "battery.75percent"
    case .network: "wifi"
    case .notifications: "bell"
    case .dialogs: "text.bubble"
    case .display: "display"
    }
  }

  public var permissionTarget: PermissionTarget {
    PermissionTarget(category: self)
  }
}

public struct PermissionTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let kind: PermissionTargetKind
  public let identifier: String
  public let displayName: String
  /// A captured PID is meaningful only for application targets and is never
  /// used as a persistent identity.
  public let pid: Int32?

  public init(applicationBundleID: String, appName: String, pid: Int32? = nil) {
    self.kind = .application
    self.identifier = applicationBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.displayName = appName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? applicationBundleID
    self.pid = pid
  }

  /// Compatibility initializer used by the AX resolver. A missing bundle ID
  /// intentionally produces an invalid target that cannot be granted.
  public init(bundleID: String?, appName: String, pid: Int32? = nil) {
    self.init(applicationBundleID: bundleID ?? "", appName: appName, pid: pid)
  }

  public init(category: GlobalPermissionCategory) {
    kind = .category
    identifier = category.rawValue
    displayName = category.displayName
    pid = nil
  }

  public var id: String {
    "\(kind.rawValue):\(identifier.lowercased())"
  }

  public var bundleID: String? {
    guard kind == .application else { return nil }
    return identifier.nilIfEmpty
  }

  public var category: GlobalPermissionCategory? {
    guard kind == .category else { return nil }
    return GlobalPermissionCategory(rawValue: identifier)
  }

  /// Compatibility display name used by the existing AX request plumbing.
  public var appName: String { displayName }

  public var sessionKey: String { id }

  public var isValidated: Bool {
    switch kind {
    case .application:
      return Self.isValidApplicationBundleID(identifier)
    case .category:
      return GlobalPermissionCategory(rawValue: identifier) != nil
    }
  }

  public static func isValidApplicationBundleID(_ bundleID: String) -> Bool {
    guard bundleID.utf8.count <= 255 else { return false }
    let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy { character in
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case identifier
    case displayName
    case pid
    // Legacy persisted AX targets used these keys.
    case bundleID
    case appName
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let kind = try container.decodeIfPresent(PermissionTargetKind.self, forKey: .kind) {
      self.kind = kind
      identifier = try container.decode(String.self, forKey: .identifier).trimmingCharacters(in: .whitespacesAndNewlines)
      displayName = (try container.decodeIfPresent(String.self, forKey: .displayName))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? identifier
      pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
    } else {
      self.kind = .application
      identifier = (try container.decodeIfPresent(String.self, forKey: .bundleID))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      displayName = (try container.decodeIfPresent(String.self, forKey: .appName))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? identifier
      pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try container.encode(identifier, forKey: .identifier)
    try container.encode(displayName, forKey: .displayName)
    try container.encodeIfPresent(pid, forKey: .pid)
  }
}

/// Retain the historical name for source compatibility while allowing the rule
/// to cover both application and global-capability targets.
public struct AXAppPermissionRule: Codable, Equatable, Identifiable, Sendable {
  public let target: PermissionTarget
  public let mode: AXAppPermissionMode

  public var id: String { target.id }
  public var bundleID: String { target.bundleID ?? target.identifier }
  public var appName: String { target.displayName }

  public init(target: PermissionTarget, mode: AXAppPermissionMode) {
    self.target = target
    self.mode = mode
  }

  public init(bundleID: String, appName: String, mode: AXAppPermissionMode) {
    self.init(target: PermissionTarget(applicationBundleID: bundleID, appName: appName), mode: mode)
  }

  private enum CodingKeys: String, CodingKey {
    case target
    case mode
    // Legacy fields are decoded only so snapshot migration can safely drop
    // former deny rules instead of making all persisted state unreadable.
    case bundleID
    case appName
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawMode = try container.decode(String.self, forKey: .mode)
    guard let mode = AXAppPermissionMode(rawValue: rawMode.lowercased()) else {
      throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Unsupported permission mode")
    }
    if let target = try container.decodeIfPresent(PermissionTarget.self, forKey: .target) {
      self.init(target: target, mode: mode)
    } else {
      self.init(
        bundleID: try container.decode(String.self, forKey: .bundleID),
        appName: try container.decodeIfPresent(String.self, forKey: .appName) ?? "Unknown app",
        mode: mode
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(target, forKey: .target)
    try container.encode(mode.rawValue, forKey: .mode)
  }
}

public enum AXPermissionDecision: Equatable, Sendable {
  case allow
  case requiresApproval
}

/// Per-target authorization evaluation for AX and curated-function gates.
/// Absence is deny-by-default: it requires a manual or popup grant for either
/// Observe or Control.
public struct AXPermissionRuleEngine: Sendable {
  private let normalizedRules: [String: AXAppPermissionRule]

  public init(rules: [AXAppPermissionRule]) {
    var result: [String: AXAppPermissionRule] = [:]
    for rule in rules where rule.target.isValidated {
      result[rule.target.id] = AXAppPermissionRule(
        target: Self.normalizedTarget(rule.target),
        mode: rule.mode
      )
    }
    normalizedRules = result
  }

  public func rule(for target: PermissionTarget) -> AXAppPermissionRule? {
    normalizedRules[target.id]
  }

  public func rule(for bundleID: String?) -> AXAppPermissionRule? {
    guard let bundleID else { return nil }
    return rule(for: PermissionTarget(applicationBundleID: bundleID, appName: bundleID))
  }

  public func decision(for target: PermissionTarget, intent: AXPermissionIntent) -> AXPermissionDecision {
    guard target.isValidated, let rule = rule(for: target) else {
      return .requiresApproval
    }
    return rule.mode.allows(intent) ? .allow : .requiresApproval
  }

  public func decision(for bundleID: String?, intent: AXPermissionIntent) -> AXPermissionDecision {
    guard let bundleID else { return .requiresApproval }
    return decision(for: PermissionTarget(applicationBundleID: bundleID, appName: bundleID), intent: intent)
  }

  private static func normalizedTarget(_ target: PermissionTarget) -> PermissionTarget {
    switch target.kind {
    case .application:
      PermissionTarget(applicationBundleID: target.identifier, appName: target.displayName)
    case .category:
      // isValidated above guarantees this conversion succeeds.
      PermissionTarget(category: GlobalPermissionCategory(rawValue: target.identifier)!)
    }
  }
}

public typealias AXPermissionTarget = PermissionTarget

public struct AXResolvedTarget: Equatable, Sendable {
  public let target: AXPermissionTarget
  /// The PID captured before permission evaluation and used for dispatch. This
  /// closes the frontmost-app race for synthetic events.
  public let pid: Int32?
  public let wasResolved: Bool

  public init(target: AXPermissionTarget, pid: Int32?, wasResolved: Bool) {
    self.target = target
    self.pid = pid
    self.wasResolved = wasResolved
  }
}

public protocol AXTargetResolving: Sendable {
  func resolve(params: AgentRequestParams, useFrontmostFallback: Bool) throws -> AXResolvedTarget

  /// Verifies that a captured PID still belongs to the same resolved bundle
  /// immediately before a control event is dispatched. This intentionally
  /// fails closed for resolvers that cannot validate process identity.
  func isStillCurrent(_ resolution: AXResolvedTarget) -> Bool
}

public extension AXTargetResolving {
  func isStillCurrent(_ resolution: AXResolvedTarget) -> Bool {
    false
  }
}

public final class SystemAXTargetResolver: AXTargetResolving, @unchecked Sendable {
  public init() {}

  public func resolve(params: AgentRequestParams, useFrontmostFallback: Bool) throws -> AXResolvedTarget {
    // targetPid wins because it is the actual CGEvent destination. The resolved
    // PID is later passed through to the service so guard and dispatch agree.
    if let pid = params.targetPid {
      return resolution(forPID: pid, fallbackName: params.appName ?? "Unknown app")
    }
    if let pid = params.pid {
      return resolution(forPID: pid, fallbackName: params.appName ?? "Unknown app")
    }
    if let appName = params.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
      return try resolution(forAppName: appName)
    }
    if useFrontmostFallback, let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated {
      return resolved(app)
    }
    return AXResolvedTarget(
      target: AXPermissionTarget(bundleID: nil, appName: "Unknown app", pid: nil),
      pid: nil,
      wasResolved: false
    )
  }

  public func isStillCurrent(_ resolution: AXResolvedTarget) -> Bool {
    guard resolution.wasResolved,
          let pid = resolution.pid,
          let expectedBundleID = resolution.target.bundleID,
          let app = NSRunningApplication(processIdentifier: pid),
          !app.isTerminated,
          app.bundleIdentifier?.caseInsensitiveCompare(expectedBundleID) == .orderedSame else {
      return false
    }
    return app.processIdentifier == pid
  }

  private func resolution(forPID pid: Int32, fallbackName: String) -> AXResolvedTarget {
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
      return AXResolvedTarget(
        target: AXPermissionTarget(bundleID: nil, appName: fallbackName, pid: pid),
        pid: pid,
        wasResolved: false
      )
    }
    return resolved(app)
  }

  private func resolution(forAppName appName: String) throws -> AXResolvedTarget {
    let apps = runningApps()
    if let exactName = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame }) {
      return resolved(exactName)
    }
    if let exactBundle = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(appName) == .orderedSame }) {
      return resolved(exactBundle)
    }

    let partialMatches = apps.filter {
      $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
        || $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
    }
    if partialMatches.count == 1, let match = partialMatches.first {
      return resolved(match)
    }
    if partialMatches.count > 1 {
      let names = partialMatches.compactMap(\.localizedName).sorted().joined(separator: ", ")
      throw AgentProtocolError.invalidRequest("App target '\(appName)' is ambiguous: \(names)")
    }

    return AXResolvedTarget(
      target: AXPermissionTarget(bundleID: nil, appName: appName, pid: nil),
      pid: nil,
      wasResolved: false
    )
  }

  private func runningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isTerminated
    }
  }

  private func resolved(_ app: NSRunningApplication) -> AXResolvedTarget {
    AXResolvedTarget(
      target: AXPermissionTarget(
        bundleID: app.bundleIdentifier,
        appName: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
        pid: app.processIdentifier
      ),
      pid: app.processIdentifier,
      wasResolved: true
    )
  }
}

public enum AXPermissionPromptResponse: Sendable {
  case allowOnce
  case allowAlways
  case notNow
  case timedOut
}

public struct AXPermissionPromptRequest: Sendable {
  public let target: PermissionTarget
  public let intent: AXPermissionIntent
  public let action: String
  public let context: String

  public init(target: PermissionTarget, intent: AXPermissionIntent, action: String, context: String) {
    self.target = target
    self.intent = intent
    self.action = action
    self.context = context
  }
}

public protocol AXPermissionPrompting: Sendable {
  func prompt(_ request: AXPermissionPromptRequest, timeout: TimeInterval) -> AXPermissionPromptResponse
}

/// AppKit implementation of the synchronous 15-second approval experience.
/// The socket worker waits off-main-thread while the alert runs in AppKit's
/// modal loop; declining or timing out persists no negative rule.
public final class SystemAXPermissionPrompter: AXPermissionPrompting, @unchecked Sendable {
  public init() {}

  public func prompt(_ request: AXPermissionPromptRequest, timeout: TimeInterval) -> AXPermissionPromptResponse {
    if Thread.isMainThread {
      return present(request, timeout: timeout)
    }

    let lock = NSLock()
    var response: AXPermissionPromptResponse = .timedOut
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

  private func present(_ request: AXPermissionPromptRequest, timeout: TimeInterval) -> AXPermissionPromptResponse {
    guard NSApp != nil else { return .timedOut }

    // Ensure the app can become key: accessory-policy apps cannot present
    // modal alerts, so promote to regular before activating.
    if NSApp.activationPolicy() == .accessory {
      NSApp.setActivationPolicy(.regular)
    }

    // Attempt activation with multiple strategies. Even if all fail, we still
    // present the alert below — it may appear behind other windows but the
    // user can reach it via the Dock/menu bar instead of silently timing out.
    if !NSApp.isActive {
      NSApp.activate()
    }
    if !NSApp.isActive {
      NSRunningApplication.current.activate()
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Allow \(request.intent.label.lowercased()) access to \(request.target.displayName)?"
    alert.informativeText = "OkBrain Agent requests \(request.action). \(request.context)"
    alert.addButton(withTitle: "Allow Once")
    alert.addButton(withTitle: "Always Allow \(request.intent.label)")
    alert.addButton(withTitle: "Not Now")
    if request.target.kind == .application,
       let pid = request.target.pid,
       let icon = NSRunningApplication(processIdentifier: pid)?.icon {
      alert.icon = icon
    } else {
      alert.icon = NSApp.applicationIconImage
    }

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
}

public struct AXPendingPermissionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let target: PermissionTarget
  public let intent: AXPermissionIntent
  public let action: String
  public let context: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    target: PermissionTarget,
    intent: AXPermissionIntent = .control,
    action: String,
    context: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.target = target
    self.intent = intent
    self.action = action
    self.context = context
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case target
    case intent
    case action
    case context
    case createdAt
  }

  /// Prior releases only queued Control requests. Treat missing intent as
  /// Control so existing pending work keeps its original, safer semantics.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    target = try container.decode(PermissionTarget.self, forKey: .target)
    intent = try container.decodeIfPresent(AXPermissionIntent.self, forKey: .intent) ?? .control
    action = try container.decode(String.self, forKey: .action)
    context = try container.decode(String.self, forKey: .context)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}

public enum AXPendingPermissionResolution: Sendable {
  case allowOnce
  case allowAlways
  case dismiss
}

public struct AXPermissionStateSnapshot: Codable, Equatable, Sendable {
  public let rules: [AXAppPermissionRule]
  public let pendingRequests: [AXPendingPermissionRequest]

  public init(rules: [AXAppPermissionRule], pendingRequests: [AXPendingPermissionRequest]) {
    self.rules = rules
    self.pendingRequests = pendingRequests
  }

  private enum CodingKeys: String, CodingKey {
    case rules
    case pendingRequests
  }

  /// Migrate persisted v1 rules while adopting default-deny. Legacy `deny`
  /// records deliberately become no rule; legacy Observe/Control records are
  /// preserved. This avoids accidentally turning a historical denial into an
  /// allow while keeping the entire UserDefaults state decodable.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let persistedRules = try container.decodeIfPresent([PersistedPermissionRule].self, forKey: .rules) ?? []
    rules = persistedRules.compactMap(\.rule)
    pendingRequests = try container.decodeIfPresent([AXPendingPermissionRequest].self, forKey: .pendingRequests) ?? []
  }

  private struct PersistedPermissionRule: Decodable {
    let target: PermissionTarget?
    let bundleID: String?
    let appName: String?
    let mode: String

    private enum CodingKeys: String, CodingKey {
      case target
      case bundleID
      case appName
      case mode
    }

    var rule: AXAppPermissionRule? {
      guard let mode = AXAppPermissionMode(rawValue: mode.lowercased()) else {
        // Includes legacy "deny", which is now represented by no rule.
        return nil
      }
      let target = target ?? PermissionTarget(bundleID: bundleID, appName: appName ?? bundleID ?? "Unknown app")
      guard target.isValidated else { return nil }
      return AXAppPermissionRule(target: target, mode: mode)
    }
  }
}

/// Thread-safe mutable state shared by the request handler and the local UI.
/// Allow-once grants remain in-process; persistent rules and pending requests
/// are emitted through `onStateChange` for UserDefaults persistence.
public final class AXPermissionCoordinator: @unchecked Sendable {
  /// A bounded inbox prevents an unavailable foreground UI from becoming an
  /// unbounded remote-memory queue. Repeated retries for the same target,
  /// intent, and action share one pending request.
  public static let maximumPendingRequestCount = 50

  private let lock = NSLock()
  private let prompter: AXPermissionPrompting
  private let onStateChange: (@Sendable (AXPermissionStateSnapshot) -> Void)?
  private var rules: [AXAppPermissionRule]
  private var pendingRequests: [AXPendingPermissionRequest]
  private var sessionGrants: [String: AXAppPermissionMode] = [:]

  public init(
    rules: [AXAppPermissionRule] = [],
    pendingRequests: [AXPendingPermissionRequest] = [],
    prompter: AXPermissionPrompting = SystemAXPermissionPrompter(),
    onStateChange: (@Sendable (AXPermissionStateSnapshot) -> Void)? = nil
  ) {
    self.rules = Self.normalizedRules(rules)
    self.pendingRequests = Self.sanitizedPendingRequests(pendingRequests)
    self.prompter = prompter
    self.onStateChange = onStateChange
  }

  public func snapshot() -> AXPermissionStateSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return AXPermissionStateSnapshot(rules: rules, pendingRequests: pendingRequests)
  }

  /// Replacing or removing a persistent rule immediately revokes any
  /// session-only grant for that same target. No stale Allow Once survives a
  /// manual downgrade/removal.
  public func replaceRules(_ nextRules: [AXAppPermissionRule]) {
    lock.lock()
    let normalized = Self.normalizedRules(nextRules)
    let currentByID = Dictionary(uniqueKeysWithValues: rules.map { ($0.target.id, $0.mode) })
    let nextByID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.target.id, $0.mode) })
    let changedIDs = Set(currentByID.keys).union(nextByID.keys).filter { currentByID[$0] != nextByID[$0] }
    for id in changedIDs {
      sessionGrants.removeValue(forKey: id)
    }
    rules = normalized
    pendingRequests.removeAll { request in
      currentDecisionLocked(for: request.target, intent: request.intent) == .allow
    }
    let snapshot = AXPermissionStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
  }

  /// Non-prompting observation check used only when an operation has already
  /// been authorized for its category/target. A missing rule is false.
  public func allowsObservation(of target: PermissionTarget) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return currentDecisionLocked(for: target, intent: .observe) == .allow
  }

  public func authorizeObservation(
    target: PermissionTarget,
    action: String,
    context: String = "Requested by the remote agent."
  ) throws {
    try authorize(target: target, intent: .observe, action: action, context: context)
  }

  public func authorizeControl(
    target: PermissionTarget,
    action: String,
    context: String = "Requested by the remote agent."
  ) throws {
    try authorize(target: target, intent: .control, action: action, context: context)
  }

  /// Rechecks a previously approved operation without displaying a second
  /// prompt. Call this immediately before an irreversible dispatch.
  public func recheckObservationWithoutPrompt(target: PermissionTarget, action: String) throws {
    try recheckWithoutPrompt(target: target, intent: .observe, action: action)
  }

  public func recheckControlWithoutPrompt(target: PermissionTarget, action: String) throws {
    try recheckWithoutPrompt(target: target, intent: .control, action: action)
  }

  @discardableResult
  public func resolvePendingRequest(id: UUID, resolution: AXPendingPermissionResolution) -> Bool {
    lock.lock()
    guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return false
    }
    let request = pendingRequests.remove(at: index)
    switch resolution {
    case .allowOnce:
      grantSessionAccessLocked(to: request.target, mode: request.intent.requiredMode)
    case .allowAlways:
      replaceOrAppendRuleLocked(target: request.target, mode: request.intent.requiredMode)
    case .dismiss:
      // Dismissing one pending escalation is not a revocation. In particular,
      // an existing Observe Allow Once must survive dismissing a later Control
      // request for that same target.
      break
    }
    let snapshot = AXPermissionStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  private func authorize(
    target: PermissionTarget,
    intent: AXPermissionIntent,
    action: String,
    context: String
  ) throws {
    guard target.isValidated else {
      throw invalidPromptTargetError(target: target, intent: intent, action: action)
    }

    lock.lock()
    let decision = currentDecisionLocked(for: target, intent: intent)
    lock.unlock()
    guard decision == .requiresApproval else { return }

    guard let request = Self.sanitizedPromptRequest(target: target, intent: intent, action: action, context: context) else {
      throw invalidPromptTargetError(target: target, intent: intent, action: action)
    }
    let response = prompter.prompt(request, timeout: 15)

    switch response {
    case .allowOnce:
      guard grantSessionAccessIfPermitted(to: request.target, mode: request.intent.requiredMode) else {
        throw permissionRequiredError(target: request.target, intent: request.intent, action: request.action, pending: false)
      }
    case .allowAlways:
      guard persistAccessIfPermitted(target: request.target, mode: request.intent.requiredMode) else {
        throw permissionRequiredError(target: request.target, intent: request.intent, action: request.action, pending: false)
      }
    case .notNow:
      throw permissionRequiredError(target: request.target, intent: request.intent, action: request.action, pending: false)
    case .timedOut:
      let queued = enqueuePending(request)
      throw permissionRequiredError(target: request.target, intent: request.intent, action: request.action, pending: queued)
    }
  }

  private func recheckWithoutPrompt(target: PermissionTarget, intent: AXPermissionIntent, action: String) throws {
    lock.lock()
    let decision = currentDecisionLocked(for: target, intent: intent)
    lock.unlock()
    guard decision == .allow else {
      throw permissionRequiredError(target: target, intent: intent, action: action, pending: false)
    }
  }

  private func currentDecisionLocked(for target: PermissionTarget, intent: AXPermissionIntent) -> AXPermissionDecision {
    guard target.isValidated else { return .requiresApproval }
    let persistentMode = AXPermissionRuleEngine(rules: rules).rule(for: target)?.mode
    let effectiveMode = AXAppPermissionMode.strongest(persistentMode, sessionGrants[target.sessionKey])
    return effectiveMode?.allows(intent) == true ? .allow : .requiresApproval
  }

  private func grantSessionAccessIfPermitted(to target: PermissionTarget, mode: AXAppPermissionMode) -> Bool {
    guard target.isValidated else { return false }
    lock.lock()
    grantSessionAccessLocked(to: target, mode: mode)
    let didRemovePending = removeSatisfiedPendingRequestsLocked(for: target)
    let snapshot = didRemovePending ? AXPermissionStateSnapshot(rules: rules, pendingRequests: pendingRequests) : nil
    lock.unlock()
    if let snapshot { onStateChange?(snapshot) }
    return true
  }

  private func grantSessionAccessLocked(to target: PermissionTarget, mode: AXAppPermissionMode) {
    sessionGrants[target.sessionKey] = AXAppPermissionMode.strongest(sessionGrants[target.sessionKey], mode)
  }

  private func persistAccessIfPermitted(target: PermissionTarget, mode: AXAppPermissionMode) -> Bool {
    guard target.isValidated else { return false }
    lock.lock()
    replaceOrAppendRuleLocked(target: target, mode: mode)
    _ = removeSatisfiedPendingRequestsLocked(for: target)
    let snapshot = AXPermissionStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  private func replaceOrAppendRuleLocked(target: PermissionTarget, mode: AXAppPermissionMode) {
    guard target.isValidated else { return }
    rules.removeAll { $0.target.id == target.id }
    rules.append(AXAppPermissionRule(target: target, mode: mode))
    rules = Self.normalizedRules(rules)
  }

  @discardableResult
  private func removeSatisfiedPendingRequestsLocked(for target: PermissionTarget) -> Bool {
    let originalCount = pendingRequests.count
    pendingRequests.removeAll { request in
      request.target.id == target.id
        && currentDecisionLocked(for: request.target, intent: request.intent) == .allow
    }
    return pendingRequests.count != originalCount
  }

  /// Returns true when the request is represented in the bounded pending list
  /// (either added or already deduplicated). A full queue or invalid target is
  /// reported as not pending so the remote side never receives a false promise.
  private func enqueuePending(_ request: AXPermissionPromptRequest) -> Bool {
    guard let safeRequest = Self.sanitizedPromptRequest(
      target: request.target,
      intent: request.intent,
      action: request.action,
      context: request.context
    ) else {
      return false
    }
    lock.lock()
    let key = Self.pendingKey(target: safeRequest.target, intent: safeRequest.intent, action: safeRequest.action)
    if pendingRequests.contains(where: {
      Self.pendingKey(target: $0.target, intent: $0.intent, action: $0.action) == key
    }) {
      lock.unlock()
      return true
    }
    guard pendingRequests.count < Self.maximumPendingRequestCount else {
      lock.unlock()
      return false
    }
    pendingRequests.append(AXPendingPermissionRequest(
      target: safeRequest.target,
      intent: safeRequest.intent,
      action: safeRequest.action,
      context: safeRequest.context
    ))
    let snapshot = AXPermissionStateSnapshot(rules: rules, pendingRequests: pendingRequests)
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  private func permissionRequiredError(
    target: PermissionTarget,
    intent: AXPermissionIntent,
    action: String,
    pending: Bool,
    message: String? = nil
  ) -> AgentProtocolError {
    AgentProtocolError.appPermissionRequired(
      message ?? "\(intent.label) access to \(target.displayName) requires local approval",
      details: permissionDetails(target: target, intent: intent, action: action, pending: pending)
    )
  }

  private func invalidPromptTargetError(
    target: PermissionTarget,
    intent: AXPermissionIntent,
    action: String
  ) -> AgentProtocolError {
    AgentProtocolError.appPermissionRequired(
      "Access requires a resolvable application or supported global capability.",
      details: permissionDetails(target: target, intent: intent, action: action, pending: false)
    )
  }

  private func permissionDetails(
    target: PermissionTarget,
    intent: AXPermissionIntent,
    action: String,
    pending: Bool
  ) -> JSONValue {
    var details: [String: JSONValue] = [
      "targetKind": .string(target.kind.rawValue),
      "targetID": .string(target.identifier),
      "targetName": .string(target.displayName),
      "intent": .string(intent.rawValue),
      "action": .string(action),
      "pending": .bool(pending)
    ]
    switch target.kind {
    case .application:
      details["bundleID"] = target.bundleID.map(JSONValue.string) ?? .null
      details["appName"] = .string(target.displayName)
    case .category:
      details["categoryID"] = .string(target.identifier)
    }
    return .object(details)
  }

  private static func normalizedRules(_ input: [AXAppPermissionRule]) -> [AXAppPermissionRule] {
    var deduplicated: [String: AXAppPermissionRule] = [:]
    for rule in input where rule.target.isValidated {
      let normalizedTarget: PermissionTarget
      switch rule.target.kind {
      case .application:
        normalizedTarget = PermissionTarget(applicationBundleID: rule.target.identifier, appName: rule.target.displayName)
      case .category:
        normalizedTarget = PermissionTarget(category: GlobalPermissionCategory(rawValue: rule.target.identifier)!)
      }
      deduplicated[normalizedTarget.id] = AXAppPermissionRule(target: normalizedTarget, mode: rule.mode)
    }
    return deduplicated.values.sorted { lhs, rhs in
      lhs.target.displayName.localizedCaseInsensitiveCompare(rhs.target.displayName) == .orderedAscending
    }
  }

  private static func sanitizedPromptRequest(
    target: PermissionTarget,
    intent: AXPermissionIntent,
    action: String,
    context: String
  ) -> AXPermissionPromptRequest? {
    let displayName = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
    guard target.isValidated,
          target.pid.map({ $0 > 0 }) ?? true,
          isSafePromptText(displayName, maximumUTF8Bytes: 255),
          isSafePromptText(normalizedAction, maximumUTF8Bytes: 256),
          isSafePromptText(normalizedContext, maximumUTF8Bytes: 2_000, allowsEmpty: true) else {
      return nil
    }

    let normalizedTarget: PermissionTarget
    switch target.kind {
    case .application:
      normalizedTarget = PermissionTarget(applicationBundleID: target.identifier, appName: displayName, pid: target.pid)
    case .category:
      normalizedTarget = PermissionTarget(category: GlobalPermissionCategory(rawValue: target.identifier)!)
    }
    return AXPermissionPromptRequest(
      target: normalizedTarget,
      intent: intent,
      action: normalizedAction,
      context: normalizedContext
    )
  }

  private static func sanitizedPendingRequests(_ input: [AXPendingPermissionRequest]) -> [AXPendingPermissionRequest] {
    var seen = Set<String>()
    var sanitized: [AXPendingPermissionRequest] = []
    for request in input {
      guard let safeRequest = sanitizedPromptRequest(
        target: request.target,
        intent: request.intent,
        action: request.action,
        context: request.context
      ) else {
        continue
      }
      let key = pendingKey(target: safeRequest.target, intent: safeRequest.intent, action: safeRequest.action)
      guard seen.insert(key).inserted else { continue }
      sanitized.append(AXPendingPermissionRequest(
        id: request.id,
        target: safeRequest.target,
        intent: safeRequest.intent,
        action: safeRequest.action,
        context: safeRequest.context,
        createdAt: request.createdAt
      ))
      if sanitized.count == maximumPendingRequestCount { break }
    }
    return sanitized
  }

  private static func isSafePromptText(_ value: String, maximumUTF8Bytes: Int, allowsEmpty: Bool = false) -> Bool {
    guard (allowsEmpty || !value.isEmpty), value.utf8.count <= maximumUTF8Bytes else { return false }
    return value.unicodeScalars.allSatisfy { $0.value >= 0x20 }
  }

  private static func pendingKey(target: PermissionTarget, intent: AXPermissionIntent, action: String) -> String {
    "\(target.sessionKey)|\(intent.rawValue)|\(action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
