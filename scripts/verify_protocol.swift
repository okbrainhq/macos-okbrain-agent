import Darwin
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
  expect(actual == expected, "\(message). Expected \(expected), got \(actual)")
}

func runProtocolVerifier() throws {
  let configuration = AgentConfiguration(
    socketPath: "/tmp/test-agent.sock",
    version: "9.9.9",
    build: "test",
    maxScreenshotBytes: 1024,
    maxRequestBytes: 1024
  )
  let screenshot = CapturedImage(pngData: Data([0x89, 0x50, 0x4E, 0x47]), width: 64, height: 32)
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .granted, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot)
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(id: "req_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "status response should be ok")
  expectEqual(status.id, "req_status", "status id")
  expectEqual(status.data?.socketPath, "/tmp/test-agent.sock", "status socket path")
  expectEqual(status.data?.permissions.screenRecording, .granted, "screen permission")
  expectEqual(status.data?.permissions.accessibility, .denied, "accessibility permission")
  expectEqual(status.data?.capabilities, [
    "screenshot.full",
    "screenshot.window",
    "screenshot.region",
    "screenshot.cursor"
  ], "capabilities")

  let capture: Envelope<ScreenshotCapturePayload> = try send(
    AgentRequest(
      id: "req_capture",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "png", includeCursor: false)
    ),
    to: handler
  )
  expect(capture.ok, "capture response should be ok")
  expectEqual(capture.data?.mimeType, "image/png", "capture mime type")
  expectEqual(capture.data?.base64, screenshot.pngData.base64EncodedString(), "capture base64")
  expectEqual(capture.data?.width, 64, "capture width")
  expectEqual(capture.data?.height, 32, "capture height")

  let deniedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .unknown)),
    screenshots: FakeScreenshotService(capturedImage: screenshot)
  )
  let denied: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "req_denied",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "png", includeCursor: false)
    ),
    to: deniedHandler
  )
  expect(!denied.ok, "denied capture should fail")
  expectEqual(denied.id, "req_denied", "denied id")
  expectEqual(denied.error?.code, "permission_denied", "denied code")

  let wrongProtocol: Envelope<EmptyPayload> = try send(
    AgentRequest(protocolName: "wrong.protocol", id: "req_wrong_protocol", action: "agent.info", params: nil),
    to: handler
  )
  expect(!wrongProtocol.ok, "wrong protocol should fail")
  expectEqual(wrongProtocol.error?.code, "protocol_mismatch", "protocol mismatch code")

  let legacy: Envelope<ScreenshotCapturePayload> = try send(
    AgentRequest(protocolName: nil, id: "legacy_1", action: "capture_full", params: nil),
    to: handler
  )
  expect(legacy.ok, "legacy capture_full should be accepted")
  expectEqual(legacy.id, "legacy_1", "legacy id")
}

func runSocketVerifier() throws {
  let socketPath = "/private/tmp/oka-\(UUID().uuidString.prefix(8)).sock"
  defer { unlink(socketPath) }
  let stateLock = NSLock()
  var isRunning = false
  var latestSnapshot: SocketServerSnapshot?
  let server = UnixSocketServer(socketPath: socketPath, maxRequestBytes: 1024) { requestData in
    expectEqual(String(data: requestData, encoding: .utf8), #"{"action":"ping"}"#, "socket request data")
    return Data(#"{"protocol":"okbrain.macos-agent.v1","id":"req_socket","ok":true,"data":{"pong":true}}"#.utf8)
  }

  server.onStateChange = { snapshot in
    stateLock.lock()
    latestSnapshot = snapshot
    if snapshot.status == .running {
      isRunning = true
    }
    stateLock.unlock()
  }
  server.start()
  defer { server.stop() }

  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    stateLock.lock()
    let ready = isRunning
    stateLock.unlock()
    if ready {
      break
    }
    usleep(10_000)
  }

  stateLock.lock()
  let ready = isRunning
  let snapshot = latestSnapshot
  stateLock.unlock()
  let snapshotLabel = snapshot.map { "\($0.status.rawValue): \($0.errorMessage ?? "no error")" } ?? "no state"
  expect(ready, "socket server did not start; latest state \(snapshotLabel)")

  let fd = try connectUnixSocket(path: socketPath)
  defer { Darwin.close(fd) }

  try writeAll(Data(#"{"action":"ping"}"#.utf8) + Data([0x0A]), to: fd)
  let response = try readLine(from: fd)
  expect(response.contains(#""ok":true"#), "socket response ok")
  expect(response.contains(#""pong":true"#), "socket response pong")
}

func send<T: Decodable>(_ request: AgentRequest, to handler: AgentRequestHandler) throws -> Envelope<T> {
  let requestData = try JSONEncoder().encode(request)
  let responseData = handler.handle(requestData: requestData)
  return try JSONDecoder().decode(Envelope<T>.self, from: responseData)
}

func connectUnixSocket(path: String) throws -> Int32 {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  expect(fd >= 0, "socket client fd")

  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = path.utf8CString
  withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
    for index in 0..<pathBytes.count {
      rawBuffer[index] = UInt8(bitPattern: pathBytes[index])
    }
  }

  let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
      Darwin.connect(fd, socketAddress, addressLength)
    }
  }

  if result != 0 {
    let message = String(cString: strerror(errno))
    Darwin.close(fd)
    throw NSError(domain: "ProtocolVerifier", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  return fd
}

func writeAll(_ data: Data, to fd: Int32) throws {
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }

    var offset = 0
    while offset < data.count {
      let written = Darwin.write(fd, baseAddress.advanced(by: offset), data.count - offset)
      if written < 0 {
        throw NSError(domain: "ProtocolVerifier", code: 2)
      }
      offset += written
    }
  }
}

func readLine(from fd: Int32) throws -> String {
  var data = Data()
  var byte: UInt8 = 0

  while true {
    let count = Darwin.read(fd, &byte, 1)
    if count == 0 {
      break
    }

    if count < 0 {
      throw NSError(domain: "ProtocolVerifier", code: 3)
    }

    if byte == 0x0A {
      break
    }

    data.append(byte)
  }

  return String(data: data, encoding: .utf8) ?? ""
}

struct FakePermissionService: PermissionChecking {
  let payload: AgentPermissionsPayload

  func currentPermissions() -> AgentPermissionsPayload {
    payload
  }

  func requestScreenRecordingAccess() -> Bool {
    payload.screenRecording == .granted
  }

  func requestAccessibilityAccess(prompt: Bool) -> Bool {
    payload.accessibility == .granted
  }
}

struct FakeScreenshotService: ScreenshotCapturing {
  let capturedImage: CapturedImage

  func capture(_ params: AgentRequestParams) throws -> CapturedImage {
    capturedImage
  }
}

struct Envelope<T: Decodable>: Decodable {
  let protocolName: String
  let id: String
  let ok: Bool
  let data: T?
  let error: VerifierErrorPayload?

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case ok
    case data
    case error
  }
}

struct VerifierErrorPayload: Decodable {
  let code: String
  let message: String
}

struct EmptyPayload: Decodable {}

@main
struct ProtocolVerifier {
  static func main() {
    do {
      try runProtocolVerifier()
      try runSocketVerifier()
      print("Protocol verifier passed")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
