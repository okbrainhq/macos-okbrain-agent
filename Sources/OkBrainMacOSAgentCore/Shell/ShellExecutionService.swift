import Darwin
import Foundation

public struct ShellExecutionRequest: Sendable {
  public var command: String
  public var cwd: String
  public var env: [String: String]
  public var timeoutSeconds: Int

  public init(command: String, cwd: String, env: [String: String] = [:], timeoutSeconds: Int = 120) {
    self.command = command
    self.cwd = cwd
    self.env = env
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct ShellExecutionOutcome: Sendable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32
  public let timedOut: Bool
  public let outputTruncated: Bool

  public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool, outputTruncated: Bool) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.outputTruncated = outputTruncated
  }
}

/// A single auditable shell execution record. stdout/stderr contents and env
/// values are deliberately excluded (protocol/08 §9.6).
public struct ShellAuditEvent: Identifiable, Sendable {
  public enum Decision: String, Sendable {
    case allow
    case askGrant
    case askDenied
    case block
    case deniedBySandbox
    case timeout
    case outputLimit
    case error
  }

  public let id: UUID
  public let command: String
  public let cwd: String
  public let classification: String
  public let decision: Decision
  public let exitCode: Int32?
  public let date: Date

  public init(
    id: UUID = UUID(),
    command: String,
    cwd: String,
    classification: String,
    decision: Decision,
    exitCode: Int32?,
    date: Date = Date()
  ) {
    self.id = id
    self.command = command
    self.cwd = cwd
    self.classification = classification
    self.decision = decision
    self.exitCode = exitCode
    self.date = date
  }
}

public protocol ShellExecuting: Sendable {
  func execute(_ request: ShellExecutionRequest, fileRules: [FileEditingAllowedRoot]) throws -> ShellExecutionOutcome
  func statusPayload(fileRules: [FileEditingAllowedRoot], enabled: Bool) -> ShellStatusPayload
}

/// Runs a command string inside a per-execution Seatbelt sandbox derived from
/// the live file rules. Mirrors the `FixedAppleScriptExecutor` plumbing:
/// concurrent stdout/stderr drain, shared 1 MiB budget, timeout → terminate →
/// force-kill, and exit-code reporting. The sandbox profile is regenerated on
/// every call so rule edits are never cached (protocol/08 §9.1).
public final class ShellExecutionService: ShellExecuting, @unchecked Sendable {
  public static let sandboxExecPath = "/usr/bin/sandbox-exec"
  public static let shellPath = "/bin/bash"
  public static let maximumTimeoutSeconds = 1800
  public static let defaultTimeoutSeconds = 120

  /// Environment keys that may pass into the sandbox (protocol/08 §12.2).
  public static let allowedEnvKeys: Set<String> = [
    "PATH", "HOME", "LANG", "LC_ALL", "TERM", "TZ", "TMPDIR"
  ]

  private let maximumOutputBytes: Int
  private let terminationGracePeriod: TimeInterval
  private let profileGenerator: SBPLProfileGenerator
  private let classifier: ShellCommandClassifier
  private let capabilityCoordinator: ShellCapabilityCoordinating?
  private let auditSink: (@Sendable (ShellAuditEvent) -> Void)?

  public init(
    maximumOutputBytes: Int = 1_024 * 1_024,
    terminationGracePeriod: TimeInterval = 1,
    profileGenerator: SBPLProfileGenerator = SBPLProfileGenerator(),
    classifier: ShellCommandClassifier = ShellCommandClassifier(),
    capabilityCoordinator: ShellCapabilityCoordinating? = nil,
    auditSink: (@Sendable (ShellAuditEvent) -> Void)? = nil
  ) {
    self.maximumOutputBytes = max(1, maximumOutputBytes)
    self.terminationGracePeriod = max(0.1, terminationGracePeriod)
    self.profileGenerator = profileGenerator
    self.classifier = classifier
    self.capabilityCoordinator = capabilityCoordinator
    self.auditSink = auditSink
  }

  public var isSandboxAvailable: Bool {
    FileManager.default.isExecutableFile(atPath: Self.sandboxExecPath)
  }

  public func execute(
    _ request: ShellExecutionRequest,
    fileRules: [FileEditingAllowedRoot]
  ) throws -> ShellExecutionOutcome {
    let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else {
      throw AgentProtocolError.invalidRequest("command is required for sh.exec")
    }

    // 1. cwd must resolve inside a read-write file rule (protocol/08 §9.3).
    let engine = FilePermissionRuleEngine(rules: normalizedRules(fileRules))
    guard let resolvedCwd = FilePermissionRuleEngine.normalizedAbsolutePath(request.cwd) else {
      throw AgentProtocolError.invalidRequest("cwd must be an absolute path")
    }
    let cwdDecision = engine.decision(for: resolvedCwd)
    guard cwdDecision.canWrite else {
      throw AgentProtocolError.invalidRequest("cwd '\(resolvedCwd)' must resolve inside a read-write file permission rule")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw AgentProtocolError.invalidRequest("cwd '\(resolvedCwd)' is not an existing directory")
    }

    // 2. Pre-flight classification (defense-in-depth; Allow/Ask/Block tiering).
    let classificationLabel: String
    switch classifier.classify(command: command, fileRules: fileRules) {
    case .allowed:
      classificationLabel = "allowed"
    case .ask(let kind, let value, let reason):
      let label = "\(kind.rawValue):\(value)"
      guard let coordinator = capabilityCoordinator else {
        // Fail closed: an Ask intent with no local prompter cannot be resolved.
        audit(command: command, cwd: resolvedCwd, classification: label, decision: .askDenied, exitCode: nil)
        throw AgentProtocolError.shellPermissionRequired(
          reason + " (no local prompter available)",
          details: .object(
            "kind", .string(kind.rawValue),
            "value", .string(value),
            "command", .string(command),
            "pending", .bool(false)
          )
        )
      }
      do {
        try coordinator.authorize(kind: kind, value: value, command: command, context: reason)
      } catch {
        audit(command: command, cwd: resolvedCwd, classification: label, decision: .askDenied, exitCode: nil)
        throw error
      }
      classificationLabel = label
    case .blocked(let kind, let value, let reason):
      audit(command: command, cwd: resolvedCwd, classification: "\(kind.rawValue):\(value)", decision: .block, exitCode: nil)
      throw AgentProtocolError.shellPermissionBlocked(
        reason,
        details: .object(
          "kind", .string(kind.rawValue),
          "value", .string(value),
          "command", .string(command),
          "pending", .bool(false)
        )
      )
    }

    guard isSandboxAvailable else {
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .error, exitCode: nil)
      throw AgentProtocolError.internalError("sandbox-exec is not available on this host")
    }

    // 3. Regenerate the profile from live stores for this execution only.
    let profile = profileGenerator.profile(
      fileRules: normalizedRules(fileRules),
      tempWritePrefixes: tempWritePrefixes(),
      userHome: NSHomeDirectory()
    )

    // 4. Spawn sandbox-exec → bash -c command, with sanitized env.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.sandboxExecPath)
    process.arguments = ["-p", profile, Self.shellPath, "-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: resolvedCwd)
    process.environment = sanitizedEnvironment(request.env)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in termination.signal() }
    let stopController = ProcessStopController(process: process, gracePeriod: terminationGracePeriod)
    let budget = OutputBudget(limit: maximumOutputBytes) {
      stopController.request(.outputLimit)
    }
    let stdoutCollector = PipeCollector(handle: stdout.fileHandleForReading, budget: budget)
    let stderrCollector = PipeCollector(handle: stderr.fileHandleForReading, budget: budget)

    do {
      try process.run()
    } catch {
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .error, exitCode: nil)
      throw AgentProtocolError.internalError("Unable to start sandbox-exec: \(error.localizedDescription)")
    }

    stdoutCollector.start()
    stderrCollector.start()

    let effectiveTimeout = TimeInterval(min(max(1, request.timeoutSeconds), Self.maximumTimeoutSeconds))
    if termination.wait(timeout: .now() + effectiveTimeout) == .timedOut {
      stopController.request(.timeout)
      _ = termination.wait(timeout: .now() + terminationGracePeriod)
    }
    if process.isRunning {
      stopController.forceKill()
      _ = termination.wait(timeout: .now() + terminationGracePeriod)
    }

    // A child holding an inherited pipe open must not hang the socket worker.
    if !stdoutCollector.wait(timeout: .now() + terminationGracePeriod) {
      try? stdout.fileHandleForReading.close()
      _ = stdoutCollector.wait(timeout: .now() + terminationGracePeriod)
    }
    if !stderrCollector.wait(timeout: .now() + terminationGracePeriod) {
      try? stderr.fileHandleForReading.close()
      _ = stderrCollector.wait(timeout: .now() + terminationGracePeriod)
    }

    let capturedStdout = String(data: stdoutCollector.data, encoding: .utf8) ?? ""
    let capturedStderr = String(data: stderrCollector.data, encoding: .utf8) ?? ""

    switch stopController.reason {
    case .timeout:
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .timeout, exitCode: nil)
      throw AgentProtocolError.shellTimeout("Shell command exceeded the \(Int(effectiveTimeout))s timeout")
    case .outputLimit:
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .outputLimit, exitCode: nil)
      throw AgentProtocolError.shellOutputLimit("Shell command exceeded the \(maximumOutputBytes)-byte output limit")
    case nil:
      break
    }

    if process.isRunning {
      stopController.forceKill()
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .timeout, exitCode: nil)
      throw AgentProtocolError.shellTimeout("Shell command exceeded the \(Int(effectiveTimeout))s timeout")
    }

    let exitCode = process.terminationStatus

    // 5a. Detect a nested sandbox failure: macOS refuses sandbox_apply from
    // inside any deny-based sandbox profile, so tools that spawn their own
    // sandbox-exec (e.g. SwiftPM) fail with "sandbox_apply: Operation not
    // permitted". Surface actionable guidance instead of a generic denial.
    let combinedOutput = capturedStderr + "\n" + capturedStdout
    if exitCode != 0, combinedOutput.contains("sandbox_apply: Operation not permitted") {
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .deniedBySandbox, exitCode: exitCode)
      throw AgentProtocolError.shellDeniedBySandbox(
        "A process tried to apply its own sandbox (nested sandbox_apply), which macOS forbids inside the agent shell's deny-based sandbox profile. Re-run the tool with its built-in sandboxing disabled (e.g. `swift build --disable-sandbox`, `swift test --disable-sandbox`); the agent shell sandbox still confines the command.",
        details: .object(
          "operation", .string("nested-sandbox-apply"),
          "command", .string(command),
          "exitCode", .number(Double(exitCode))
        )
      )
    }

    // 5b. Detect an unanticipated kernel denial (EPERM from sandboxd). This is a
    // best-effort parse; v1 ships pre-flight classification as the primary gate.
    if exitCode != 0, let deniedOp = deniedSandboxOperation(in: capturedStderr) {
      audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .deniedBySandbox, exitCode: exitCode)
      throw AgentProtocolError.shellDeniedBySandbox(
        "The sandbox denied an operation: \(deniedOp)",
        details: .object(
          "operation", .string(deniedOp),
          "command", .string(command),
          "exitCode", .number(Double(exitCode))
        )
      )
    }

    audit(command: command, cwd: resolvedCwd, classification: classificationLabel, decision: .allow, exitCode: exitCode)
    return ShellExecutionOutcome(
      stdout: capturedStdout,
      stderr: capturedStderr,
      exitCode: exitCode,
      timedOut: false,
      outputTruncated: false
    )
  }

  public func statusPayload(fileRules: [FileEditingAllowedRoot], enabled: Bool) -> ShellStatusPayload {
    let rules = normalizedRules(fileRules)
    let capabilitySnapshot = capabilityCoordinator?.snapshot()
    return ShellStatusPayload(
      enabled: enabled,
      sandboxAvailable: isSandboxAvailable,
      networkPolicy: "open (v1: unrestricted outbound/inbound/local; see protocol/08 §4.3)",
      trustedExecPrefixes: SBPLProfileGenerator.trustedExecPrefixes,
      fileRules: rules.map { ShellFileRuleSummary(path: $0.path, mode: $0.mode) },
      blockSummary: [
        "file-write denied: " + SBPLProfileGenerator.blockWritePrefixes.joined(separator: ", "),
        "TCC/system-policy read-write denied: " + SBPLProfileGenerator.blockReadWritePrefixes.joined(separator: ", "),
        "denied ops: authorization-right-obtain, nvram*, file-write-mount/unmount, file-write-setugid",
        "denied mach services: " + SBPLProfileGenerator.blockedMachServices.joined(separator: ", ")
      ],
      capabilityRules: (capabilitySnapshot?.rules ?? []).map {
        ShellCapabilityRuleSummary(kind: $0.kind, value: $0.value, mode: $0.mode)
      },
      pendingCapabilityCount: capabilitySnapshot?.pendingRequests.count ?? 0
    )
  }

  // MARK: - Helpers

  private func normalizedRules(_ rules: [FileEditingAllowedRoot]) -> [FileEditingAllowedRoot] {
    rules.compactMap { rule in
      guard rule.mode.canRead,
            let normalized = FilePermissionRuleEngine.normalizedAbsolutePath(rule.path) else { return nil }
      return FileEditingAllowedRoot(path: normalized, mode: rule.mode)
    }
  }

  private func tempWritePrefixes() -> [String] {
    var prefixes: [String] = ["/private/tmp", "/tmp"]
    if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"],
       let normalized = FilePermissionRuleEngine.normalizedAbsolutePath(tmpdir) {
      prefixes.append(normalized)
    }
    return prefixes
  }

  private func sanitizedEnvironment(_ requested: [String: String]) -> [String: String] {
    let base = ProcessInfo.processInfo.environment
    var result: [String: String] = [:]
    for key in Self.allowedEnvKeys {
      if let value = base[key] {
        result[key] = value
      }
    }
    for (key, value) in requested where Self.allowedEnvKeys.contains(key) {
      result[key] = value
    }
    return result
  }

  /// Best-effort detection of a Seatbelt denial in stderr. Returns the denied
  /// SBPL operation name when one can be parsed.
  private func deniedSandboxOperation(in stderr: String) -> String? {
    guard stderr.contains("deny(") || stderr.contains("Operation not permitted") || stderr.contains("Sandbox:") else {
      return nil
    }
    if let range = stderr.range(of: #"deny\(\d+\)\s+([a-z0-9-]+)"#, options: .regularExpression) {
      let match = String(stderr[range])
      let parts = match.split(separator: " ")
      if let op = parts.last {
        return String(op)
      }
    }
    return "unknown"
  }

  private func audit(command: String, cwd: String, classification: String, decision: ShellAuditEvent.Decision, exitCode: Int32?) {
    guard let auditSink else { return }
    // Bound the logged command; never include stdout contents or env values.
    let boundedCommand = command.count > 1000 ? String(command.prefix(1000)) + "…" : command
    auditSink(ShellAuditEvent(command: boundedCommand, cwd: cwd, classification: classification, decision: decision, exitCode: exitCode))
  }
}
