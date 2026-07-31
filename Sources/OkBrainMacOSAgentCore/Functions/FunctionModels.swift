import Foundation

public enum FunctionTier: String, Codable, CaseIterable, Equatable, Sendable {
  case read
  case write
  case elevated

  public var label: String {
    switch self {
    case .read: "Read"
    case .write: "Write"
    case .elevated: "Elevated"
    }
  }
}

/// Immutable identity captured when a function request begins and revalidated
/// after any prompt or TCC wait. Template identity includes both its persistent
/// record ID and reviewed source digest, preventing a same-name replacement
/// from inheriting an in-flight authorization.
public enum FunctionExecutionIdentity: Equatable, Sendable {
  case builtIn(name: String)
  case template(id: UUID, sourceDigest: String)
}

public enum FunctionArgumentType: String, Codable, Equatable, Sendable {
  case string
  case stringArray
  case integer
  case number
  case boolean
}

public struct FunctionArg: Codable, Equatable, Sendable, Identifiable {
  public let name: String
  public let type: FunctionArgumentType
  public let required: Bool
  public let description: String
  public let enumValues: [String]?
  public let minimum: Double?
  public let maximum: Double?
  public let maxLength: Int?
  /// Item-count bounds for array arguments. `maxLength` continues to bound
  /// each string element for `.stringArray`.
  public let minItems: Int?
  public let maxItems: Int?

  public var id: String { name }

  public init(
    name: String,
    type: FunctionArgumentType,
    required: Bool,
    description: String,
    enumValues: [String]? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    maxLength: Int? = nil,
    minItems: Int? = nil,
    maxItems: Int? = nil
  ) {
    self.name = name
    self.type = type
    self.required = required
    self.description = description
    self.enumValues = enumValues
    self.minimum = minimum
    self.maximum = maximum
    self.maxLength = maxLength
    self.minItems = minItems
    self.maxItems = maxItems
  }
}

public struct FunctionArgumentViolation: Codable, Equatable, Sendable {
  public let argument: String
  public let reason: String

  public init(argument: String, reason: String) {
    self.argument = argument
    self.reason = reason
  }
}

public struct FunctionTarget: Codable, Equatable, Sendable {
  public let bundleID: String
  public let appName: String
  public let requiresAutomation: Bool

  public init(bundleID: String, appName: String, requiresAutomation: Bool) {
    self.bundleID = bundleID
    self.appName = appName
    self.requiresAutomation = requiresAutomation
  }

  public var permissionTarget: PermissionTarget {
    PermissionTarget(applicationBundleID: bundleID, appName: appName)
  }
}

public struct FunctionFileAccessRequirement: Equatable, Sendable {
  public let path: String
  public let intent: FileAccessIntent

  public init(path: String, intent: FileAccessIntent) {
    self.path = path
    self.intent = intent
  }
}

public struct FunctionExecutionPlan: Sendable {
  public let args: [String: JSONValue]
  /// App-specific target used for TCC Automation preflight and app metadata.
  public let target: FunctionTarget?
  /// Mandatory authorization target for every executable curated function.
  /// App functions derive it from `target`; unbound functions declare a real
  /// global category instead of bypassing the permission gate.
  public let permissionTarget: PermissionTarget?
  public let fileAccessRequirement: FunctionFileAccessRequirement?
  /// Populated by the handler only after the file service canonicalizes and
  /// authorizes an existing path. Backends must use this value, not raw args.
  public let resolvedFilePath: String?

  public init(
    args: [String: JSONValue],
    target: FunctionTarget? = nil,
    permissionTarget: PermissionTarget? = nil,
    fileAccessRequirement: FunctionFileAccessRequirement? = nil,
    resolvedFilePath: String? = nil
  ) {
    self.args = args
    self.target = target
    self.permissionTarget = permissionTarget ?? target?.permissionTarget
    self.fileAccessRequirement = fileAccessRequirement
    self.resolvedFilePath = resolvedFilePath
  }

  public func withResolvedFilePath(_ path: String) -> FunctionExecutionPlan {
    FunctionExecutionPlan(
      args: args,
      target: target,
      permissionTarget: permissionTarget,
      fileAccessRequirement: fileAccessRequirement,
      resolvedFilePath: path
    )
  }
}

public struct FunctionResult: Codable, Equatable, Sendable {
  public let value: JSONValue

  public init(value: JSONValue) {
    self.value = value
  }
}

public struct FunctionRunPayload: Codable, Equatable, Sendable {
  public let name: String
  public let result: FunctionResult

  public init(name: String, result: FunctionResult) {
    self.name = name
    self.result = result
  }
}

public struct FunctionCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public let name: String
  public let summary: String
  public let tier: FunctionTier
  public let args: [FunctionArg]
  public let enabled: Bool
  public let targetBundleID: String?
  /// Static permission metadata lets both the local UI and remote callers see
  /// the global category that an unbound function needs before execution.
  /// Dynamic app functions may leave this nil until concrete args are planned.
  public let permissionTarget: PermissionTarget?
  public let automationStatus: AutomationPermissionStatus?

  public var id: String { name }

  public init(
    name: String,
    summary: String,
    tier: FunctionTier,
    args: [FunctionArg],
    enabled: Bool,
    targetBundleID: String?,
    permissionTarget: PermissionTarget? = nil,
    automationStatus: AutomationPermissionStatus?
  ) {
    self.name = name
    self.summary = summary
    self.tier = tier
    self.args = args
    self.enabled = enabled
    self.targetBundleID = targetBundleID
    self.permissionTarget = permissionTarget
    self.automationStatus = automationStatus
  }
}

public struct FunctionListPayload: Codable, Equatable, Sendable {
  public let functions: [FunctionCatalogEntry]

  public init(functions: [FunctionCatalogEntry]) {
    self.functions = functions
  }
}

public struct FunctionProposal: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let description: String
  public let rationale: String
  public let exampleScript: String?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    description: String,
    rationale: String,
    exampleScript: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.rationale = rationale
    self.exampleScript = exampleScript
    self.createdAt = createdAt
  }
}

public struct FunctionProposalPayload: Codable, Equatable, Sendable {
  public let proposal: FunctionProposal

  public init(proposal: FunctionProposal) {
    self.proposal = proposal
  }
}

/// Data shown to the local user before an elevated proposal can be approved.
/// It is derived from the exact source and resolved target that approval will
/// bind, rather than from remote-provided display text alone.
public struct FunctionProposalApprovalPreview: Equatable, Sendable {
  public let proposalID: UUID
  public let sourceDigest: String
  public let targetBundleID: String
  public let targetAppName: String
  public let argumentNames: [String]
  public let tier: FunctionTier
  public let approvalEnablesExecution: Bool

  public init(
    proposalID: UUID,
    sourceDigest: String,
    targetBundleID: String,
    targetAppName: String,
    argumentNames: [String],
    tier: FunctionTier,
    approvalEnablesExecution: Bool
  ) {
    self.proposalID = proposalID
    self.sourceDigest = sourceDigest
    self.targetBundleID = targetBundleID
    self.targetAppName = targetAppName
    self.argumentNames = argumentNames
    self.tier = tier
    self.approvalEnablesExecution = approvalEnablesExecution
  }
}

public struct StoredFunctionTemplate: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let summary: String
  /// Exact, locally reviewed source. Its SHA-256 must equal `sourceDigest` at
  /// run time; metadata never infers a target from mutable source.
  public let script: String
  public let sourceDigest: String
  public let targetBundleID: String?
  public let targetAppName: String?
  public let requiresAutomation: Bool
  public let argumentNames: [String]
  public let approvedAt: Date

  public var isReviewed: Bool {
    guard let targetBundleID, let targetAppName else { return false }
    return !sourceDigest.isEmpty
      && !targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !targetAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && sourceDigest == TemplateSourceReview.digest(for: script)
      && argumentNames == TemplateSourceReview.placeholderNames(in: script)
  }

  public init(
    id: UUID = UUID(),
    name: String,
    summary: String,
    script: String,
    sourceDigest: String,
    targetBundleID: String,
    targetAppName: String,
    requiresAutomation: Bool,
    argumentNames: [String],
    approvedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.script = script
    self.sourceDigest = sourceDigest
    self.targetBundleID = targetBundleID
    self.targetAppName = targetAppName
    self.requiresAutomation = requiresAutomation
    self.argumentNames = argumentNames
    self.approvedAt = approvedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case summary
    case script
    case sourceDigest
    case targetBundleID
    case targetAppName
    case requiresAutomation
    case argumentNames
    case approvedAt
  }

  /// Legacy persisted templates intentionally decode but are fail-closed:
  /// missing reviewed metadata leaves `isReviewed == false` until the local
  /// user explicitly re-reviews the full source.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    summary = try container.decode(String.self, forKey: .summary)
    script = try container.decode(String.self, forKey: .script)
    sourceDigest = try container.decodeIfPresent(String.self, forKey: .sourceDigest) ?? ""
    targetBundleID = try container.decodeIfPresent(String.self, forKey: .targetBundleID)
    targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
    requiresAutomation = try container.decodeIfPresent(Bool.self, forKey: .requiresAutomation) ?? false
    argumentNames = try container.decodeIfPresent([String].self, forKey: .argumentNames) ?? []
    approvedAt = try container.decodeIfPresent(Date.self, forKey: .approvedAt) ?? Date.distantPast
  }
}

public struct FunctionRuntimeStateSnapshot: Codable, Equatable, Sendable {
  public let enabledFunctionNames: [String]
  public let proposals: [FunctionProposal]
  public let templates: [StoredFunctionTemplate]

  public init(enabledFunctionNames: [String], proposals: [FunctionProposal], templates: [StoredFunctionTemplate]) {
    self.enabledFunctionNames = enabledFunctionNames
    self.proposals = proposals
    self.templates = templates
  }
}

/// Mutable state controlled only by the local app UI. It is intentionally
/// separate from the socket handler so tests can use a pure in-memory store.
public final class FunctionRuntimeState: @unchecked Sendable {
  private static let maxProposals = 50
  private static let maxProposalTextLength = 20_000

  private let lock = NSLock()
  private let onStateChange: (@Sendable (FunctionRuntimeStateSnapshot) -> Void)?
  private let templateTargetResolver: TemplateTargetResolving
  private var enabledFunctionNames: Set<String>
  private var proposals: [FunctionProposal]
  private var templates: [StoredFunctionTemplate]

  public init(
    enabledFunctionNames: [String] = [],
    proposals: [FunctionProposal] = [],
    templates: [StoredFunctionTemplate] = [],
    templateTargetResolver: TemplateTargetResolving = SystemTemplateTargetResolver(),
    onStateChange: (@Sendable (FunctionRuntimeStateSnapshot) -> Void)? = nil
  ) {
    self.templateTargetResolver = templateTargetResolver
    self.templates = templates
    let legacyNames = Set(templates.filter { !$0.isReviewed }.map { $0.name.lowercased() })
    self.enabledFunctionNames = Set(enabledFunctionNames.map { $0.lowercased() }).subtracting(legacyNames)
    self.proposals = proposals
    self.onStateChange = onStateChange
  }

  public func snapshot() -> FunctionRuntimeStateSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return FunctionRuntimeStateSnapshot(
      enabledFunctionNames: enabledFunctionNames.sorted(),
      proposals: proposals,
      templates: templates
    )
  }

  public func isEnabled(_ functionName: String, tier: FunctionTier) -> Bool {
    if tier == .read { return true }
    lock.lock()
    defer { lock.unlock() }
    return enabledFunctionNames.contains(functionName.lowercased())
  }

  public func setEnabled(_ enabled: Bool, for functionName: String) {
    let normalizedName = functionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedName.isEmpty else { return }
    lock.lock()
    if enabled {
      enabledFunctionNames.insert(normalizedName)
    } else {
      enabledFunctionNames.remove(normalizedName)
    }
    let snapshot = currentSnapshotLocked()
    lock.unlock()
    onStateChange?(snapshot)
  }

  /// Returns only templates whose persisted target and source digest still
  /// match the locally reviewed source. Legacy templates remain visible in the
  /// settings UI but cannot become executable by a stale enable flag.
  public func executableTemplate(named name: String) -> StoredFunctionTemplate? {
    lock.lock()
    defer { lock.unlock() }
    return templates.first {
      $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.isReviewed
    }
  }

  public func executableTemplate(id: UUID, sourceDigest: String) -> StoredFunctionTemplate? {
    lock.lock()
    defer { lock.unlock() }
    return templates.first {
      $0.id == id && $0.isReviewed && $0.sourceDigest.caseInsensitiveCompare(sourceDigest) == .orderedSame
    }
  }

  public func isTemplateExecutable(_ template: StoredFunctionTemplate) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return template.isReviewed
      && templates.contains(where: {
        $0.id == template.id
          && $0.isReviewed
          && $0.sourceDigest.caseInsensitiveCompare(template.sourceDigest) == .orderedSame
      })
      && enabledFunctionNames.contains(template.name.lowercased())
  }

  public func submitProposal(
    name: String,
    description: String,
    rationale: String,
    exampleScript: String?
  ) throws -> FunctionProposal {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedScript = exampleScript?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    var violations: [FunctionArgumentViolation] = []

    let namePattern = try! NSRegularExpression(pattern: "^[a-z][a-z0-9.-]{2,80}$")
    let nameRange = NSRange(normalizedName.startIndex..., in: normalizedName)
    if namePattern.firstMatch(in: normalizedName, options: [], range: nameRange) == nil {
      violations.append(.init(argument: "name", reason: "Use 3–81 lowercase letters, numbers, dots, or hyphens; start with a letter."))
    }
    if normalizedDescription.isEmpty || normalizedDescription.count > 1_000 {
      violations.append(.init(argument: "description", reason: "Provide 1–1000 characters."))
    }
    if normalizedRationale.isEmpty || normalizedRationale.count > 2_000 {
      violations.append(.init(argument: "rationale", reason: "Provide 1–2000 characters."))
    }
    if let normalizedScript, normalizedScript.count > Self.maxProposalTextLength {
      violations.append(.init(argument: "exampleScript", reason: "Must be at most \(Self.maxProposalTextLength) characters."))
    }
    if !violations.isEmpty {
      throw invalidArgsError("Proposal validation failed", violations: violations)
    }

    lock.lock()
    guard proposals.count < Self.maxProposals else {
      lock.unlock()
      throw AgentProtocolError.functionFailed("The proposal inbox is full", details: .object("limit", .number(Double(Self.maxProposals))))
    }
    guard !proposals.contains(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame })
            && !templates.contains(where: { $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame }) else {
      lock.unlock()
      throw invalidArgsError("Proposal validation failed", violations: [
        .init(argument: "name", reason: "A proposal or approved template already uses this name.")
      ])
    }

    let proposal = FunctionProposal(
      name: normalizedName,
      description: normalizedDescription,
      rationale: normalizedRationale,
      exampleScript: normalizedScript
    )
    proposals.append(proposal)
    let snapshot = currentSnapshotLocked()
    lock.unlock()
    onStateChange?(snapshot)
    return proposal
  }

  @discardableResult
  public func rejectProposal(id: UUID) -> Bool {
    lock.lock()
    guard let index = proposals.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return false
    }
    proposals.remove(at: index)
    let snapshot = currentSnapshotLocked()
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  /// Builds the local confirmation data from the immutable proposal source.
  /// Target resolution is repeated during approval, so this preview never acts
  /// as a durable authorization by itself.
  public func approvalPreview(id: UUID) throws -> FunctionProposalApprovalPreview {
    lock.lock()
    guard let proposal = proposals.first(where: { $0.id == id }) else {
      lock.unlock()
      throw AgentProtocolError.invalidRequest("The proposal no longer exists")
    }
    guard let script = proposal.exampleScript?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else {
      lock.unlock()
      throw invalidArgsError("Proposal validation failed", violations: [
        .init(argument: "exampleScript", reason: "An AppleScript template is required before approval.")
      ])
    }
    lock.unlock()

    let review = try TemplateSourceReview.review(source: script, targetResolver: templateTargetResolver)
    return FunctionProposalApprovalPreview(
      proposalID: proposal.id,
      sourceDigest: review.sourceDigest,
      targetBundleID: review.target.bundleID,
      targetAppName: review.target.appName,
      argumentNames: review.argumentNames,
      tier: .elevated,
      approvalEnablesExecution: true
    )
  }

  /// Approves a proposal only when the local full-source confirmation submits
  /// the exact digest that was displayed to the user. The reviewed target is
  /// resolved now and persisted; runtime never infers a target from source.
  public func approveProposal(id: UUID, approvedSourceDigest: String) throws -> StoredFunctionTemplate {
    lock.lock()
    guard let proposal = proposals.first(where: { $0.id == id }) else {
      lock.unlock()
      throw AgentProtocolError.invalidRequest("The proposal no longer exists")
    }
    guard let script = proposal.exampleScript?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else {
      lock.unlock()
      throw invalidArgsError("Proposal validation failed", violations: [
        .init(argument: "exampleScript", reason: "An AppleScript template is required before approval.")
      ])
    }
    lock.unlock()

    let review = try TemplateSourceReview.review(source: script, targetResolver: templateTargetResolver)
    guard review.sourceDigest.caseInsensitiveCompare(approvedSourceDigest.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
      throw invalidArgsError("Proposal validation failed", violations: [
        .init(argument: "sourceDigest", reason: "The full-source confirmation does not match the reviewed template.")
      ])
    }

    let template = StoredFunctionTemplate(
      name: proposal.name,
      summary: proposal.description,
      script: script,
      sourceDigest: review.sourceDigest,
      targetBundleID: review.target.bundleID,
      targetAppName: review.target.appName,
      requiresAutomation: review.target.requiresAutomation,
      argumentNames: review.argumentNames
    )

    lock.lock()
    guard let index = proposals.firstIndex(where: { $0.id == id }),
          proposals[index].exampleScript?.trimmingCharacters(in: .whitespacesAndNewlines) == script else {
      lock.unlock()
      throw AgentProtocolError.invalidRequest("The proposal changed before approval could finish")
    }
    proposals.remove(at: index)
    templates.removeAll { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }
    templates.append(template)
    // Explicit local full-source approval is the enable action for a template.
    enabledFunctionNames.insert(template.name.lowercased())
    let snapshot = currentSnapshotLocked()
    lock.unlock()
    onStateChange?(snapshot)
    return template
  }

  /// Preserves legacy data while moving an unreviewed template back into the
  /// inbox so the user can inspect and approve its exact source again.
  @discardableResult
  public func requeueLegacyTemplateForReview(id: UUID) -> Bool {
    lock.lock()
    guard let index = templates.firstIndex(where: { $0.id == id }), !templates[index].isReviewed,
          proposals.count < Self.maxProposals else {
      lock.unlock()
      return false
    }
    let template = templates.remove(at: index)
    guard !proposals.contains(where: { $0.name.caseInsensitiveCompare(template.name) == .orderedSame }) else {
      templates.insert(template, at: index)
      lock.unlock()
      return false
    }
    enabledFunctionNames.remove(template.name.lowercased())
    proposals.append(FunctionProposal(
      name: template.name,
      description: template.summary,
      rationale: "Re-review required because this template was approved before target-bound source metadata existed.",
      exampleScript: template.script
    ))
    let snapshot = currentSnapshotLocked()
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  public func removeTemplate(id: UUID) -> Bool {
    lock.lock()
    guard let index = templates.firstIndex(where: { $0.id == id }) else {
      lock.unlock()
      return false
    }
    let template = templates.remove(at: index)
    enabledFunctionNames.remove(template.name.lowercased())
    let snapshot = currentSnapshotLocked()
    lock.unlock()
    onStateChange?(snapshot)
    return true
  }

  private func currentSnapshotLocked() -> FunctionRuntimeStateSnapshot {
    FunctionRuntimeStateSnapshot(
      enabledFunctionNames: enabledFunctionNames.sorted(),
      proposals: proposals,
      templates: templates
    )
  }
}

/// Runtime context supplied only by the guarded request handler. It lets
/// catalog functions query an already-established observation grant without
/// giving their implementation authority to alter permission state.
public struct FunctionExecutionContext: Sendable {
  public let canObserveApp: @Sendable (AXPermissionTarget) -> Bool

  public init(canObserveApp: @escaping @Sendable (AXPermissionTarget) -> Bool) {
    self.canObserveApp = canObserveApp
  }

  public static let unrestricted = FunctionExecutionContext(canObserveApp: { _ in true })
}

public enum FunctionOutputLimits {
  /// Function results are encoded before framing and must stay bounded even
  /// when a non-AppleScript backend (for example the clipboard) returns data.
  public static let maximumEncodedResultBytes = 1_024 * 1_024

  public static func validate(_ result: FunctionResult) throws {
    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(result)
    } catch {
      throw AgentProtocolError.functionFailed(
        "Function result could not be encoded safely.",
        details: .object("reason", .string(error.localizedDescription))
      )
    }
    guard encoded.count <= maximumEncodedResultBytes else {
      throw AgentProtocolError.functionFailed(
        "Function result exceeds the \(maximumEncodedResultBytes)-byte output limit.",
        details: .object("limit", .number(Double(maximumEncodedResultBytes)))
      )
    }
  }
}

public protocol MacOSFunction: Sendable {
  var name: String { get }
  var summary: String { get }
  var tier: FunctionTier { get }
  /// Whether the backend requires the process-level macOS Accessibility grant
  /// in addition to its App & Global Access permission target.
  var requiresAccessibility: Bool { get }
  var executionIdentity: FunctionExecutionIdentity { get }
  var argSchema: [FunctionArg] { get }
  /// A static app target may be used for catalog display; dynamic targets
  /// belong in the execution plan produced after validating concrete args.
  var catalogTargetBundleID: String? { get }
  /// Static authorization metadata, including global categories. Dynamic app
  /// targets may remain nil until concrete args are planned.
  var catalogPermissionTarget: PermissionTarget? { get }

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan
  func run(plan: FunctionExecutionPlan) throws -> FunctionResult
  func run(plan: FunctionExecutionPlan, context: FunctionExecutionContext) throws -> FunctionResult
}

public extension MacOSFunction {
  var requiresAccessibility: Bool { false }

  var executionIdentity: FunctionExecutionIdentity {
    .builtIn(name: name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  var catalogPermissionTarget: PermissionTarget? {
    guard let bundleID = catalogTargetBundleID else { return nil }
    return PermissionTarget(applicationBundleID: bundleID, appName: bundleID)
  }

  func run(plan: FunctionExecutionPlan, context: FunctionExecutionContext) throws -> FunctionResult {
    try run(plan: plan)
  }
}

public func validateFunctionArgs(
  _ args: [String: JSONValue],
  schema: [FunctionArg]
) throws -> [String: JSONValue] {
  let schemaByName = Dictionary(uniqueKeysWithValues: schema.map { ($0.name, $0) })
  var violations: [FunctionArgumentViolation] = []

  for key in args.keys where schemaByName[key] == nil {
    violations.append(.init(argument: key, reason: "Unknown argument."))
  }

  for arg in schema {
    guard let value = args[arg.name] else {
      if arg.required {
        violations.append(.init(argument: arg.name, reason: "Required argument is missing."))
      }
      continue
    }

    switch (arg.type, value) {
    case (.string, .string(let text)):
      if let maxLength = arg.maxLength, text.count > maxLength {
        violations.append(.init(argument: arg.name, reason: "Must be at most \(maxLength) characters."))
      }
      if let values = arg.enumValues,
         !values.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
        violations.append(.init(argument: arg.name, reason: "Must be one of: \(values.joined(separator: ", "))."))
      }
    case (.stringArray, .array(let values)):
      if let minItems = arg.minItems, values.count < minItems {
        violations.append(.init(argument: arg.name, reason: "Must contain at least \(minItems) item\(minItems == 1 ? "" : "s")."))
      }
      if let maxItems = arg.maxItems, values.count > maxItems {
        violations.append(.init(argument: arg.name, reason: "Must contain at most \(maxItems) items."))
      }
      for (index, value) in values.enumerated() {
        guard case .string(let text) = value else {
          violations.append(.init(argument: "\(arg.name)[\(index)]", reason: "Expected string."))
          continue
        }
        if let maxLength = arg.maxLength, text.count > maxLength {
          violations.append(.init(argument: "\(arg.name)[\(index)]", reason: "Must be at most \(maxLength) characters."))
        }
      }
    case (.integer, .number(let number)):
      if number.rounded() != number {
        violations.append(.init(argument: arg.name, reason: "Must be an integer."))
      }
      validateRange(number, argument: arg, violations: &violations)
    case (.number, .number(let number)):
      validateRange(number, argument: arg, violations: &violations)
    case (.boolean, .bool):
      break
    default:
      violations.append(.init(argument: arg.name, reason: "Expected \(arg.type.rawValue)."))
    }
  }

  if !violations.isEmpty {
    throw invalidArgsError("Function argument validation failed", violations: violations)
  }
  return args
}

private func validateRange(
  _ number: Double,
  argument: FunctionArg,
  violations: inout [FunctionArgumentViolation]
) {
  guard number.isFinite else {
    violations.append(.init(argument: argument.name, reason: "Must be a finite number."))
    return
  }
  if let minimum = argument.minimum, number < minimum {
    violations.append(.init(argument: argument.name, reason: "Must be at least \(minimum)."))
  }
  if let maximum = argument.maximum, number > maximum {
    violations.append(.init(argument: argument.name, reason: "Must be at most \(maximum)."))
  }
}

public func invalidArgsError(_ message: String, violations: [FunctionArgumentViolation]) -> AgentProtocolError {
  AgentProtocolError.invalidArgs(message, details: violationsDetails(violations))
}

public func violationsDetails(_ violations: [FunctionArgumentViolation]) -> JSONValue {
  .object(
    "violations",
    .array(violations.map { violation in
      .object("argument", .string(violation.argument), "reason", .string(violation.reason))
    })
  )
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
