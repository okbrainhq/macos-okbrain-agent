import Darwin
import Foundation
import os.log

public enum SocketServerStatus: String, Equatable, Sendable {
  case stopped
  case starting
  case running
  case failed
}

public struct SocketServerSnapshot: Equatable, Sendable {
  public let status: SocketServerStatus
  public let socketPath: String
  public let errorMessage: String?
  public let startedAt: Date?

  public init(
    status: SocketServerStatus,
    socketPath: String,
    errorMessage: String? = nil,
    startedAt: Date? = nil
  ) {
    self.status = status
    self.socketPath = socketPath
    self.errorMessage = errorMessage
    self.startedAt = startedAt
  }
}

/// A UNIX-domain socket server that speaks the OKB1 binary frame protocol.
///
/// Resilience contract (the listener must never silently die):
/// - The accept loop runs on its own serial queue and ONLY accepts connections.
///   Each accepted client is handed off to a concurrent queue, so a slow, hung,
///   or malicious request handler can never block `accept()` again. (Previously
///   `handleClient` ran inline on the accept loop; a single hung request wedged
///   the loop, the listen backlog filled, and the kernel returned ECONNREFUSED
///   to every subsequent client — the whole agent appeared dead.)
/// - Transient `accept` errors are logged and skipped; fatal ones bubble up to a
///   supervisor that logs loudly and restarts the loop (rebinding the socket)
///   with backoff instead of tearing the server down permanently.
/// - Per-connection reads have a timeout so a silent/half-open client cannot hold
///   a handler thread forever.
/// - All notable failures are emitted to the unified log (subsystem
///   `com.okbrain.macos-agent`, category `socket-server`) and via `onStateChange`.
public final class UnixSocketServer {
  public typealias RequestHandler = (Data) -> Data
  public var onStateChange: ((SocketServerSnapshot) -> Void)?

  private let socketPath: String
  private let maxRequestBytes: Int
  private let requestHandler: RequestHandler

  /// Serial queue that runs the accept loop. It must never execute request
  /// handling code.
  private let acceptQueue = DispatchQueue(
    label: "com.okbrain.macos-agent.socket-server.accept",
    qos: .userInitiated
  )
  /// Concurrent queue for per-connection handling. Isolating handling here is
  /// what keeps the listener alive when an individual request hangs.
  private let clientQueue = DispatchQueue(
    label: "com.okbrain.macos-agent.socket-server.client",
    qos: .userInitiated,
    attributes: .concurrent
  )

  private let lock = NSLock()
  private var serverFD: Int32 = -1
  private var stopRequested = false
  private var started = false

  /// Bound on how long a silent client may hold a handler thread in `read()`.
  private let readTimeoutSeconds: Int = 60
  /// Give up restarting only after sustained fatal failures, and never silently.
  private let maxRestartAttempts = 50

  private static let logger = Logger(subsystem: "com.okbrain.macos-agent", category: "socket-server")

  public init(
    socketPath: String,
    maxRequestBytes: Int = 64 * 1024,
    requestHandler: @escaping RequestHandler
  ) {
    self.socketPath = socketPath
    self.maxRequestBytes = maxRequestBytes
    self.requestHandler = requestHandler
  }

  deinit {
    stop()
  }

  public func start() {
    lock.lock()
    if started {
      lock.unlock()
      return
    }
    started = true
    stopRequested = false
    lock.unlock()

    emit(SocketServerSnapshot(status: .starting, socketPath: socketPath))
    acceptQueue.async { [weak self] in
      self?.supervise()
    }
  }

  public func stop() {
    lock.lock()
    stopRequested = true
    started = false
    let fd = serverFD
    serverFD = -1
    lock.unlock()

    if fd >= 0 {
      Darwin.close(fd)
    }
  }

  // MARK: - Supervision

  /// Keeps the accept loop alive. `runAcceptLoop` returns `nil` on a clean stop
  /// or an error message on a fatal failure; on a fatal failure we log loudly and
  /// restart (rebinding the socket) with a short backoff. The listener therefore
  /// never disappears without a trace.
  private func supervise() {
    var attempts = 0
    while !isStopRequested {
      let failure = runAcceptLoop()
      if isStopRequested {
        break
      }

      attempts += 1
      let message = failure ?? "accept loop exited unexpectedly"
      Self.logger.error(
        "Socket accept loop exited: \(message, privacy: .public) — restarting (attempt \(attempts))"
      )
      emit(SocketServerSnapshot(status: .failed, socketPath: socketPath, errorMessage: message))

      if attempts >= maxRestartAttempts {
        Self.logger.error(
          "Socket accept loop giving up after \(attempts) failed restarts; listener is DOWN on \(self.socketPath, privacy: .public)"
        )
        break
      }

      let delay = min(5.0, 0.25 * Double(attempts))
      Thread.sleep(forTimeInterval: delay)
      if !isStopRequested {
        emit(SocketServerSnapshot(status: .starting, socketPath: socketPath))
      }
    }

    if isStopRequested {
      emit(SocketServerSnapshot(status: .stopped, socketPath: socketPath))
    }
  }

  /// Binds, listens, and accepts until stopped or a fatal error occurs. Returns
  /// `nil` for a clean stop, or a human-readable error for a fatal failure that
  /// the supervisor should restart.
  private func runAcceptLoop() -> String? {
    let fd: Int32
    do {
      fd = try bindAndListen()
    } catch {
      return "bind/listen failed: \(describe(error))"
    }

    lock.lock()
    serverFD = fd
    lock.unlock()

    emit(SocketServerSnapshot(status: .running, socketPath: socketPath, startedAt: Date()))
    Self.logger.info("Socket server listening on \(self.socketPath, privacy: .public)")

    defer {
      lock.lock()
      let current = serverFD
      if current == fd {
        serverFD = -1
      }
      lock.unlock()

      if current >= 0 {
        Darwin.close(current)
      }
      unlinkIfSocketExists(socketPath)
    }

    while !isStopRequested {
      let clientFD = Darwin.accept(fd, nil, nil)
      if clientFD < 0 {
        if errno == EINTR {
          continue
        }
        if isStopRequested {
          break
        }
        if isTransientAcceptError(errno) {
          // Resource pressure or an aborted/raced connection: log and keep serving.
          Self.logger.error(
            "accept failed transiently: \(String(cString: strerror(errno)), privacy: .public); continuing"
          )
          Thread.sleep(forTimeInterval: 0.05)
          continue
        }
        // Fatal: the listening socket is unusable. Let the supervisor rebind.
        return "accept failed fatally: \(String(cString: strerror(errno)))"
      }

      // Hand off and immediately accept again. Never handle a client inline.
      clientQueue.async { [weak self] in
        self?.handleClient(clientFD)
      }
    }

    return nil
  }

  private func isTransientAcceptError(_ errorCode: Int32) -> Bool {
    switch errorCode {
    case ECONNABORTED, EWOULDBLOCK, EAGAIN, EMFILE, ENFILE, ENOBUFS, ENOMEM,
         EPROTO, EPERM, EFAULT, ECONNRESET, ETIMEDOUT, ENETDOWN, ENETUNREACH,
         ENETRESET, EHOSTDOWN, EHOSTUNREACH:
      return true
    default:
      return false
    }
  }

  private var isStopRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopRequested
  }

  // MARK: - Bind / listen

  private func bindAndListen() throws -> Int32 {
    guard socketPath.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw AgentProtocolError.socketError("Socket path is too long: \(socketPath)")
    }

    try createParentDirectoryIfNeeded()
    try removeExistingSocketFile()

    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw AgentProtocolError.socketError("socket failed: \(String(cString: strerror(errno)))")
    }

    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
      for index in 0..<pathBytes.count {
        rawBuffer[index] = UInt8(bitPattern: pathBytes[index])
      }
    }

    let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.bind(fd, socketAddress, addressLength)
      }
    }

    guard bindResult == 0 else {
      let message = String(cString: strerror(errno))
      Darwin.close(fd)
      throw AgentProtocolError.socketError("bind failed: \(message)")
    }

    chmod(socketPath, mode_t(S_IRUSR | S_IWUSR))

    guard Darwin.listen(fd, 128) == 0 else {
      let message = String(cString: strerror(errno))
      Darwin.close(fd)
      throw AgentProtocolError.socketError("listen failed: \(message)")
    }

    return fd
  }

  // MARK: - Per-connection handling

  private func handleClient(_ clientFD: Int32) {
    defer {
      Darwin.close(clientFD)
    }

    var noSigPipe: Int32 = 1
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    // A silent or half-open client must not be able to hold this worker forever.
    var receiveTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
    setsockopt(
      clientFD,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &receiveTimeout,
      socklen_t(MemoryLayout<timeval>.size)
    )

    do {
      let requestData = try readRequest(from: clientFD)
      guard !requestData.isEmpty else {
        return
      }

      let responseData = requestHandler(requestData)
      try write(responseData, to: clientFD)
    } catch {
      Self.logger.debug("Connection handling ended: \(self.describe(error), privacy: .public)")
      return
    }
  }

  private func readRequest(from fd: Int32) throws -> Data {
    guard let prelude = try readExact(AgentBinaryFrame.preludeByteCount, from: fd, allowEmptyEOF: true) else {
      return Data()
    }

    let lengths = try AgentBinaryFrame.decodePrelude(prelude)
    guard lengths.headerByteCount <= maxRequestBytes,
          lengths.bodyByteCount <= maxRequestBytes - lengths.headerByteCount else {
      throw AgentProtocolError.invalidRequest("Request frame exceeds \(maxRequestBytes) bytes")
    }

    let headerData = try readExact(lengths.headerByteCount, from: fd, allowEmptyEOF: false) ?? Data()
    if lengths.bodyByteCount > 0 {
      _ = try readExact(lengths.bodyByteCount, from: fd, allowEmptyEOF: false)
      throw AgentProtocolError.invalidRequest("Request frame body is not supported")
    }

    return headerData
  }

  private func readExact(_ byteCount: Int, from fd: Int32, allowEmptyEOF: Bool) throws -> Data? {
    guard byteCount > 0 else {
      return Data()
    }

    var data = Data()
    data.reserveCapacity(byteCount)

    while data.count < byteCount {
      var buffer = [UInt8](repeating: 0, count: min(8192, byteCount - data.count))
      let bytesRead = Darwin.read(fd, &buffer, buffer.count)
      if bytesRead == 0 {
        if allowEmptyEOF && data.isEmpty {
          return nil
        }
        throw AgentProtocolError.socketError("read failed: unexpected EOF")
      }

      if bytesRead < 0 {
        if errno == EINTR {
          continue
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
          throw AgentProtocolError.socketError("read failed: timed out after \(readTimeoutSeconds)s")
        }
        throw AgentProtocolError.socketError("read failed: \(String(cString: strerror(errno)))")
      }

      data.append(contentsOf: buffer.prefix(bytesRead))
    }

    return data
  }

  private func write(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }

      var offset = 0
      while offset < data.count {
        let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
        if written < 0 {
          if errno == EINTR {
            continue
          }
          throw AgentProtocolError.socketError("write failed: \(String(cString: strerror(errno)))")
        }
        offset += written
      }
    }
  }

  // MARK: - Filesystem helpers

  private func createParentDirectoryIfNeeded() throws {
    let parentURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parentURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func removeExistingSocketFile() throws {
    var info = stat()
    if lstat(socketPath, &info) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw AgentProtocolError.socketError("Refusing to remove non-socket file at \(socketPath)")
      }

      guard unlink(socketPath) == 0 else {
        throw AgentProtocolError.socketError("Unable to remove stale socket: \(String(cString: strerror(errno)))")
      }
    } else if errno != ENOENT {
      throw AgentProtocolError.socketError("Unable to inspect socket path: \(String(cString: strerror(errno)))")
    }
  }

  private func unlinkIfSocketExists(_ path: String) {
    var info = stat()
    if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
      unlink(path)
    }
  }

  // MARK: - Helpers

  private func describe(_ error: Error) -> String {
    if let agentError = error as? AgentProtocolError {
      return agentError.message
    }
    return error.localizedDescription
  }

  private func emit(_ snapshot: SocketServerSnapshot) {
    onStateChange?(snapshot)
  }
}
