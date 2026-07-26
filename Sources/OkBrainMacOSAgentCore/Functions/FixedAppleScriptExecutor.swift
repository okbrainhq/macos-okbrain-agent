import Darwin
import Foundation

/// Internal executor for source assembled exclusively by the curated catalog or
/// a locally approved template. It is deliberately not exposed as a socket API.
/// Both streams are drained concurrently with a shared byte budget, so a noisy
/// script cannot deadlock on a pipe or grow an unbounded in-memory response.
final class FixedAppleScriptExecutor: @unchecked Sendable {
  struct Output: Sendable {
    let stdout: String
    let stderr: String
  }

  enum ExecutionError: LocalizedError {
    case launch(String)
    case failed(String)
    case timedOut
    case outputTooLarge(Int)

    var errorDescription: String? {
      switch self {
      case .launch(let message), .failed(let message): message
      case .timedOut: "The approved AppleScript timed out."
      case .outputTooLarge(let limit): "The approved AppleScript exceeded the \(limit)-byte output limit."
      }
    }
  }

  private let maximumOutputBytes: Int
  private let terminationGracePeriod: TimeInterval

  init(maximumOutputBytes: Int = 1_024 * 1_024, terminationGracePeriod: TimeInterval = 1) {
    self.maximumOutputBytes = max(1, maximumOutputBytes)
    self.terminationGracePeriod = max(0.1, terminationGracePeriod)
  }

  func runAppleScript(_ source: String, timeout: TimeInterval = 15) throws -> Output {
    guard let sourceData = source.data(using: .utf8) else {
      throw ExecutionError.launch("Unable to encode an internal AppleScript template.")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
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
      throw ExecutionError.launch("Unable to start the internal AppleScript executor: \(error.localizedDescription)")
    }

    stdoutCollector.start()
    stderrCollector.start()
    do {
      try stdin.fileHandleForWriting.write(contentsOf: sourceData)
      try stdin.fileHandleForWriting.close()
    } catch {
      stopController.request(.timeout)
      _ = termination.wait(timeout: .now() + terminationGracePeriod)
      throw ExecutionError.launch("Unable to send the internal AppleScript template: \(error.localizedDescription)")
    }

    let effectiveTimeout = max(1, timeout)
    if termination.wait(timeout: .now() + effectiveTimeout) == .timedOut {
      stopController.request(.timeout)
      _ = termination.wait(timeout: .now() + terminationGracePeriod)
    }
    if process.isRunning {
      stopController.forceKill()
      _ = termination.wait(timeout: .now() + terminationGracePeriod)
    }

    // A child holding an inherited pipe open must not make the socket worker
    // wait forever after the main osascript process has been terminated.
    if !stdoutCollector.wait(timeout: .now() + terminationGracePeriod) {
      try? stdout.fileHandleForReading.close()
      _ = stdoutCollector.wait(timeout: .now() + terminationGracePeriod)
    }
    if !stderrCollector.wait(timeout: .now() + terminationGracePeriod) {
      try? stderr.fileHandleForReading.close()
      _ = stderrCollector.wait(timeout: .now() + terminationGracePeriod)
    }

    switch stopController.reason {
    case .timeout:
      throw ExecutionError.timedOut
    case .outputLimit:
      throw ExecutionError.outputTooLarge(maximumOutputBytes)
    case nil:
      break
    }

    if process.isRunning {
      stopController.forceKill()
      throw ExecutionError.timedOut
    }
    if let error = stdoutCollector.readError ?? stderrCollector.readError {
      throw ExecutionError.failed("Unable to read AppleScript output: \(error.localizedDescription)")
    }

    let capturedStdout = stdoutCollector.data
    let capturedStderr = stderrCollector.data
    guard process.terminationStatus == 0 else {
      let detail = String(data: capturedStderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      throw ExecutionError.failed(detail?.isEmpty == false ? detail! : "The internal AppleScript command failed.")
    }

    return Output(
      stdout: String(data: capturedStdout, encoding: .utf8) ?? "",
      stderr: String(data: capturedStderr, encoding: .utf8) ?? ""
    )
  }

  func appleScriptStringLiteral(_ text: String) -> String {
    let escaped = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }
}

private final class ProcessStopController: @unchecked Sendable {
  enum Reason: Equatable {
    case timeout
    case outputLimit
  }

  private let lock = NSLock()
  private let process: Process
  private let gracePeriod: TimeInterval
  private var storedReason: Reason?

  init(process: Process, gracePeriod: TimeInterval) {
    self.process = process
    self.gracePeriod = gracePeriod
  }

  var reason: Reason? {
    lock.lock()
    defer { lock.unlock() }
    return storedReason
  }

  func request(_ reason: Reason) {
    lock.lock()
    let shouldStop = storedReason == nil
    if storedReason == nil { storedReason = reason }
    lock.unlock()
    guard shouldStop else { return }

    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
      self?.forceKill()
    }
  }

  func forceKill() {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    guard pid > 0 else { return }
    _ = Darwin.kill(pid, SIGKILL)
  }
}

private final class OutputBudget: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private let onLimit: @Sendable () -> Void
  private var consumed = 0
  private var didExceed = false

  init(limit: Int, onLimit: @escaping @Sendable () -> Void) {
    self.limit = limit
    self.onLimit = onLimit
  }

  /// Reserves a bounded prefix of a pipe chunk. The first overflow triggers
  /// termination while readers keep draining until the process exits.
  func reserve(_ byteCount: Int) -> Int {
    lock.lock()
    let available = max(0, limit - consumed)
    let accepted = min(available, byteCount)
    consumed += accepted
    let shouldStop = byteCount > accepted && !didExceed
    if shouldStop { didExceed = true }
    lock.unlock()
    if shouldStop { onLimit() }
    return accepted
  }
}

private final class PipeCollector: @unchecked Sendable {
  private let handle: FileHandle
  private let budget: OutputBudget
  private let lock = NSLock()
  private let complete = DispatchGroup()
  private var captured = Data()
  private var storedReadError: Error?

  init(handle: FileHandle, budget: OutputBudget) {
    self.handle = handle
    self.budget = budget
  }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return captured
  }

  var readError: Error? {
    lock.lock()
    defer { lock.unlock() }
    return storedReadError
  }

  func start() {
    complete.enter()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      defer { self.complete.leave() }
      while true {
        do {
          guard let chunk = try self.handle.read(upToCount: 16_384), !chunk.isEmpty else { return }
          let accepted = self.budget.reserve(chunk.count)
          guard accepted > 0 else { continue }
          self.lock.lock()
          self.captured.append(chunk.prefix(accepted))
          self.lock.unlock()
        } catch {
          self.lock.lock()
          self.storedReadError = error
          self.lock.unlock()
          return
        }
      }
    }
  }

  func wait(timeout: DispatchTime) -> Bool {
    complete.wait(timeout: timeout) == .success
  }
}
