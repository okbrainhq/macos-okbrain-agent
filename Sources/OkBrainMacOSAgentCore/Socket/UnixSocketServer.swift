import Darwin
import Foundation

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

public final class UnixSocketServer {
  public typealias RequestHandler = (Data) -> Data
  public var onStateChange: ((SocketServerSnapshot) -> Void)?

  private let socketPath: String
  private let maxRequestBytes: Int
  private let requestHandler: RequestHandler
  private let queue = DispatchQueue(label: "com.okbrain.macos-agent.socket-server", qos: .userInitiated)
  private let lock = NSLock()
  private var serverFD: Int32 = -1
  private var stopRequested = false
  private var started = false

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
    queue.async { [weak self] in
      self?.run()
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

  private func run() {
    do {
      let fd = try bindAndListen()
      lock.lock()
      serverFD = fd
      lock.unlock()

      emit(SocketServerSnapshot(status: .running, socketPath: socketPath, startedAt: Date()))

      while !isStopRequested {
        let clientFD = Darwin.accept(fd, nil, nil)
        if clientFD < 0 {
          if errno == EINTR {
            continue
          }
          if isStopRequested {
            break
          }
          throw AgentProtocolError.socketError("accept failed: \(String(cString: strerror(errno)))")
        }

        handleClient(clientFD)
      }
    } catch let error as AgentProtocolError {
      if !isStopRequested {
        emit(SocketServerSnapshot(status: .failed, socketPath: socketPath, errorMessage: error.message))
      }
    } catch {
      if !isStopRequested {
        emit(SocketServerSnapshot(status: .failed, socketPath: socketPath, errorMessage: error.localizedDescription))
      }
    }

    lock.lock()
    let fd = serverFD
    serverFD = -1
    started = false
    lock.unlock()

    if fd >= 0 {
      Darwin.close(fd)
    }
    unlinkIfSocketExists(socketPath)

    if isStopRequested {
      emit(SocketServerSnapshot(status: .stopped, socketPath: socketPath))
    }
  }

  private var isStopRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopRequested
  }

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

    guard Darwin.listen(fd, 16) == 0 else {
      let message = String(cString: strerror(errno))
      Darwin.close(fd)
      throw AgentProtocolError.socketError("listen failed: \(message)")
    }

    return fd
  }

  private func handleClient(_ clientFD: Int32) {
    defer {
      Darwin.close(clientFD)
    }

    var noSigPipe: Int32 = 1
    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    do {
      let requestData = try readRequest(from: clientFD)
      guard !requestData.isEmpty else {
        return
      }

      var responseData = requestHandler(requestData)
      responseData.append(0x0A)
      try write(responseData, to: clientFD)
    } catch {
      return
    }
  }

  private func readRequest(from fd: Int32) throws -> Data {
    var data = Data()
    var byte: UInt8 = 0

    while data.count < maxRequestBytes {
      let bytesRead = Darwin.read(fd, &byte, 1)
      if bytesRead == 0 {
        return data
      }

      if bytesRead < 0 {
        if errno == EINTR {
          continue
        }
        throw AgentProtocolError.socketError("read failed: \(String(cString: strerror(errno)))")
      }

      if byte == 0x0A {
        return data
      }

      data.append(byte)
    }

    throw AgentProtocolError.invalidRequest("Request exceeds \(maxRequestBytes) bytes")
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

  private func emit(_ snapshot: SocketServerSnapshot) {
    onStateChange?(snapshot)
  }
}
