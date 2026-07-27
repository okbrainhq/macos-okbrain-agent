import Darwin
import Foundation

/// Shared low-level process plumbing used by both the curated-function
/// AppleScript executor and the sandboxed shell executor. Both streams are
/// drained concurrently against a shared byte budget so a noisy child cannot
/// deadlock on a pipe or grow an unbounded in-memory response. These helpers
/// are internal (not `private`) so the sandboxed shell verifier can exercise
/// them when it compiles the whole `OkBrainMacOSAgentCore` module.

final class ProcessStopController: @unchecked Sendable {
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

final class OutputBudget: @unchecked Sendable {
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

final class PipeCollector: @unchecked Sendable {
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
