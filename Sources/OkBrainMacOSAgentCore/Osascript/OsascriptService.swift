import Foundation

/// Result of running an AppleScript / JXA snippet through `/usr/bin/osascript`.
public struct OsascriptRunPayload: Codable, Equatable, Sendable {
  /// Normalized language that was executed: "applescript" or "javascript".
  public let language: String
  /// Process exit code reported by `osascript` (0 on success).
  public let exitCode: Int
  /// Captured standard output.
  public let stdout: String
  /// Captured standard error (includes a timeout note when `timedOut` is true).
  public let stderr: String
  /// True when the script was terminated because it exceeded the timeout.
  public let timedOut: Bool

  public init(language: String, exitCode: Int, stdout: String, stderr: String, timedOut: Bool) {
    self.language = language
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
  }
}

public protocol OsascriptServicing: Sendable {
  func run(script: String, language: String, timeout: TimeInterval) throws -> OsascriptRunPayload
}

/// Runs AppleScript / JXA by piping the source into `/usr/bin/osascript` over
/// stdin. Feeding the script via stdin (instead of `-e`) means multi-line
/// scripts and embedded quotes need no shell escaping and there is no argument
/// length limit.
public final class SystemOsascriptService: OsascriptServicing, @unchecked Sendable {
  public static let defaultTimeout: TimeInterval = 30
  public static let maxTimeout: TimeInterval = 300

  public init() {}

  public func run(script: String, language: String, timeout: TimeInterval) throws -> OsascriptRunPayload {
    guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentProtocolError.invalidRequest("script is required for osascript.run")
    }

    let normalizedLanguage = Self.normalizedLanguage(language)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = normalizedLanguage == "javascript" ? ["-l", "JavaScript"] : []

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      throw AgentProtocolError.invalidRequest("Failed to launch osascript: \(error.localizedDescription)")
    }

    // Watchdog that terminates a runaway script.
    let effectiveTimeout = Self.effectiveTimeout(timeout)
    let timedOut = TimeoutFlag()
    let watchdog = DispatchWorkItem { [weak process] in
      guard let process, process.isRunning else {
        return
      }
      timedOut.set(true)
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout, execute: watchdog)

    // Feed the script via stdin, then close so osascript sees EOF.
    if let stdinData = script.data(using: .utf8) {
      try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
    }
    try? stdinPipe.fileHandleForWriting.close()

    // Read stdout and stderr concurrently so a full pipe buffer on one stream
    // cannot deadlock the child while we block on the other.
    var stderrData = Data()
    let stderrQueue = DispatchQueue(label: "okbrain.osascript.stderr")
    stderrQueue.async {
      stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    }
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    stderrQueue.sync {}

    process.waitUntilExit()
    watchdog.cancel()

    let exitCode = Int(process.terminationStatus)
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    var stderr = String(data: stderrData, encoding: .utf8) ?? ""
    let didTimeOut = timedOut.get()

    if didTimeOut {
      let timeoutMessage = "osascript timed out after \(Int(effectiveTimeout))s"
      stderr = stderr.isEmpty ? timeoutMessage : "\(stderr)\n\(timeoutMessage)"
    }

    return OsascriptRunPayload(
      language: normalizedLanguage,
      exitCode: exitCode,
      stdout: stdout,
      stderr: stderr,
      timedOut: didTimeOut
    )
  }

  static func normalizedLanguage(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "javascript" || value == "jxa" {
      return "javascript"
    }
    return "applescript"
  }

  static func effectiveTimeout(_ requested: TimeInterval) -> TimeInterval {
    guard requested.isFinite, requested > 0 else {
      return defaultTimeout
    }
    return min(requested, maxTimeout)
  }
}

private final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set(_ newValue: Bool) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
