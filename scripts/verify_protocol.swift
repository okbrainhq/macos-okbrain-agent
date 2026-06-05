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

  try runFileEditingVerifier(permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .unknown)))
}

func runFileEditingVerifier(permissions: FakePermissionService) throws {
  let fileManager = FileManager.default
  let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("okbrain-agent-fs-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: rootURL) }

  let ignoredEnvironmentConfiguration = AgentConfiguration.current(
    environment: ["MACOS_AGENT_ALLOWED_ROOTS": rootURL.path],
    bundle: .main,
    fileEditingEnabled: false
  )
  expect(!ignoredEnvironmentConfiguration.fileEditing.enabled, "allowed roots environment variable must not enable file editing")

  let configuration = AgentConfiguration(
    socketPath: "/tmp/test-agent.sock",
    version: "9.9.9",
    build: "test",
    fileEditing: FileEditingConfiguration.toggleEnabled(
      true,
      allowedRoots: [FileEditingAllowedRoot(path: rootURL.path, mode: .readWrite)]
    )
  )
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: permissions,
    screenshots: FakeScreenshotService(capturedImage: CapturedImage(pngData: Data([0x89, 0x50]), width: 1, height: 1))
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(protocolName: AgentConfiguration.protocolV2Name, id: "fs_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "v2 status response should be ok")
  expectEqual(status.protocolName, AgentConfiguration.protocolV2Name, "v2 status protocol")
  expect(status.data?.capabilities.contains("fs.read") == true, "v2 status should expose fs.read")
  expectEqual(status.data?.fileEditing?.mode, .readWrite, "file editing mode")

  let workspace: Envelope<WorkspaceDescribePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_workspace",
      action: "workspace.describe",
      params: AgentRequestParams(root: rootURL.path)
    ),
    to: handler
  )
  expect(workspace.ok, "workspace.describe should be ok")
  expectEqual(workspace.data?.exists, true, "workspace exists")

  let write: Envelope<FileWritePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_write",
      action: "fs.write",
      params: AgentRequestParams(
        root: rootURL.path,
        path: "src/app.txt",
        content: "one\nreturn null\nthree\n",
        createDirs: true
      )
    ),
    to: handler
  )
  expect(write.ok, "fs.write should be ok")
  expectEqual(write.data?.path, "src/app.txt", "write path")
  expect(write.data?.sha256.isEmpty == false, "write sha")

  let read: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_read",
      action: "fs.read",
      params: AgentRequestParams(root: rootURL.path, path: "src/app.txt", startLine: 2, endLine: 2)
    ),
    to: handler
  )
  expect(read.ok, "fs.read should be ok")
  expectEqual(read.data?.content, "return null\n", "read line range")

  let patch: Envelope<FilePatchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_patch",
      action: "fs.patch",
      params: AgentRequestParams(
        root: rootURL.path,
        path: "src/app.txt",
        expectedSha256: write.data?.sha256,
        edits: [FilePatchEdit(oldText: "return null", newText: "return 42", startLine: 2)]
      )
    ),
    to: handler
  )
  expect(patch.ok, "fs.patch should be ok")
  expectEqual(patch.data?.changedLines, [2], "patch changed lines")

  let freshReadAfterPatch: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_read_after_patch",
      action: "fs.read",
      params: AgentRequestParams(root: rootURL.path, path: "src/app.txt", startLine: 1, endLine: 4)
    ),
    to: handler
  )
  expect(freshReadAfterPatch.ok, "fs.read after fs.patch should be ok")
  expectEqual(freshReadAfterPatch.data?.content, "one\nreturn 42\nthree\n", "fs.read should reflect patched content")
  expectEqual(freshReadAfterPatch.data?.lineCount, 3, "fs.read after patch line count")
  expectEqual(freshReadAfterPatch.data?.sha256, patch.data?.sha256, "fs.read after patch sha")

  let overwrite: Envelope<FileWritePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_write_overwrite",
      action: "fs.write",
      params: AgentRequestParams(
        root: rootURL.path,
        path: "src/app.txt",
        content: "one\nreturn 42\ninserted\nthree\n",
        expectedSha256: patch.data?.sha256
      )
    ),
    to: handler
  )
  expect(overwrite.ok, "fs.write overwrite should be ok")

  let freshReadAfterWrite: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_read_after_write",
      action: "fs.read",
      params: AgentRequestParams(root: rootURL.path, path: "src/app.txt", startLine: 1, endLine: 10)
    ),
    to: handler
  )
  expect(freshReadAfterWrite.ok, "fs.read after fs.write should be ok")
  expectEqual(freshReadAfterWrite.data?.content, "one\nreturn 42\ninserted\nthree\n", "fs.read should reflect overwritten content")
  expectEqual(freshReadAfterWrite.data?.lineCount, 4, "fs.read after write line count")
  expectEqual(freshReadAfterWrite.data?.sha256, overwrite.data?.sha256, "fs.read after write sha")

  let search: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_search",
      action: "fs.search",
      params: AgentRequestParams(root: rootURL.path, path: ".", glob: "*.txt", query: "return 42")
    ),
    to: handler
  )
  expect(search.ok, "fs.search should be ok")
  expectEqual(search.data?.matches.first?.path, "src/app.txt", "search match path")
  expectEqual(search.data?.matches.first?.line, 2, "search match line")

  let fileSearch: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_search_file",
      action: "fs.search",
      params: AgentRequestParams(root: rootURL.path, path: "src/app.txt", query: "inserted")
    ),
    to: handler
  )
  expect(fileSearch.ok, "fs.search should accept a single-file path")
  expect(fileSearch.data?.matches.count == 1, "single-file search should return one match")
  expectEqual(fileSearch.data?.matches.first?.path, "src/app.txt", "single-file search match path")
  expectEqual(fileSearch.data?.matches.first?.line, 3, "single-file search match line")

  let list: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_list",
      action: "fs.list",
      params: AgentRequestParams(root: rootURL.path, path: ".", recursive: true, glob: "*.txt")
    ),
    to: handler
  )
  expect(list.ok, "fs.list should be ok")
  expect(list.data?.entries.contains(where: { $0.path == "src/app.txt" }) == true, "list should include file")

  let escape: Envelope<EmptyPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolV2Name,
      id: "fs_escape",
      action: "fs.read",
      params: AgentRequestParams(root: rootURL.path, path: "../outside.txt")
    ),
    to: handler
  )
  expect(!escape.ok, "root escape should fail")
  expectEqual(escape.error?.code, "path_outside_root", "root escape error code")
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
