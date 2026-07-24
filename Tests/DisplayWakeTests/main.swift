import Foundation
import OkBrainMacOSAgentCore

// MARK: - Test helpers

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
  expect(actual == expected, "\(message). Expected \(expected), got \(actual)")
}

// MARK: - Spy DisplayWaking

final class SpyDisplayWake: DisplayWaking, @unchecked Sendable {
  private let lock = NSLock()
  private var _released = false

  var released: Bool {
    lock.lock(); defer { lock.unlock() }
    return _released
  }

  func release() {
    lock.lock()
    _released = true
    lock.unlock()
  }
}

/// Records every factory invocation so tests can assert which actions
/// triggered a display-wake and with what settle delay.
final class DisplayWakeSpy: @unchecked Sendable {
  private let lock = NSLock()
  private var _invocations: [(action: String, settleDelay: TimeInterval)] = []
  private var _lastWake: SpyDisplayWake?

  /// The action label is set by the test *before* sending the request so the
  /// factory can record it (the factory closure itself has no access to the
  /// action string).
  var pendingAction: String = ""

  var invocations: [(action: String, settleDelay: TimeInterval)] {
    lock.lock(); defer { lock.unlock() }
    return _invocations
  }

  var lastWake: SpyDisplayWake? {
    lock.lock(); defer { lock.unlock() }
    return _lastWake
  }

  var callCount: Int {
    lock.lock(); defer { lock.unlock() }
    return _invocations.count
  }

  func makeWake(settleDelay: TimeInterval) -> (any DisplayWaking)? {
    let wake = SpyDisplayWake()
    lock.lock()
    _invocations.append((action: pendingAction, settleDelay: settleDelay))
    _lastWake = wake
    lock.unlock()
    return wake
  }
}

// MARK: - Fake services (minimal)

struct FakePermissionService: PermissionChecking {
  func currentPermissions() -> AgentPermissionsPayload {
    AgentPermissionsPayload(screenRecording: .granted, accessibility: .granted)
  }
  func requestScreenRecordingAccess() -> Bool { true }
  func requestAccessibilityAccess(prompt: Bool) -> Bool { true }
}

struct FakeScreenshotService: ScreenshotCapturing {
  func capture(_ params: AgentRequestParams) throws -> CapturedImage {
    CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1)
  }
}

struct FakeAccessibilityService: AccessibilityServicing {
  func listApps() throws -> AXAppListPayload { AXAppListPayload(apps: []) }
  func listWindows(query: AXElementQuery) throws -> AXWindowListPayload {
    AXWindowListPayload(pid: 0, app: "Test", windows: [])
  }
  func tree(query: AXElementQuery) throws -> AXTreePayload {
    AXTreePayload(pid: 0, app: "Test", window: nil, truncated: false, root: AXElementNode(
      role: "AXWindow", subrole: nil, title: nil, label: nil, identifier: nil,
      value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
    ))
  }
  func find(query: AXElementQuery, limit: Int) throws -> AXFindPayload {
    AXFindPayload(matches: [], truncated: false)
  }
  func perform(query: AXElementQuery, action: String) throws -> AXPerformPayload {
    AXPerformPayload(action: action, element: AXElementNode(
      role: "AXButton", subrole: nil, title: nil, label: nil, identifier: nil,
      value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
    ))
  }
  func value(query: AXElementQuery) throws -> AXValuePayload {
    AXValuePayload(element: AXElementNode(
      role: "AXTextField", subrole: nil, title: nil, label: nil, identifier: nil,
      value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
    ))
  }
  func setValue(query: AXElementQuery, value: String) throws -> AXValuePayload {
    try self.value(query: query)
  }
  func typeText(_ text: String, targetPid: Int32?) throws {}
  func keyPress(key: String, modifiers: [String], targetPid: Int32?) throws {}
  func clickAt(x: Double, y: Double, button: String, clickCount: Int, targetPid: Int32?) throws {}
  func scroll(query: AXElementQuery, deltaX: Int, deltaY: Int, x: Double?, y: Double?, targetPid: Int32?) throws {}
  func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, targetPid: Int32?) throws {}
}

final class FakeOsascriptService: OsascriptServicing, @unchecked Sendable {
  func run(script: String, language: String, timeout: TimeInterval) throws -> OsascriptRunPayload {
    OsascriptRunPayload(language: language, exitCode: 0, stdout: "ok\n", stderr: "", timedOut: false)
  }
}

// MARK: - Envelope decoding

struct Envelope<T: Decodable>: Decodable {
  let ok: Bool
  let data: T?
  let error: ErrorPayload?

  private enum CodingKeys: String, CodingKey {
    case ok, data, error
  }
}

struct ErrorPayload: Decodable {
  let code: String
  let message: String
}

struct EmptyPayload: Decodable {}

func send<T: Decodable>(_ request: AgentRequest, to handler: AgentRequestHandler) throws -> Envelope<T> {
  let requestData = try JSONEncoder().encode(request)
  let responseData = handler.handle(requestData: requestData)
  let frame = try AgentBinaryFrame.decode(responseData)
  return try JSONDecoder().decode(Envelope<T>.self, from: frame.headerData)
}

// MARK: - Tests

@main
enum DisplayWakeTests {
  static func main() throws {
    try osascriptRunTriggersDisplayWake()
    try axActionTriggersDisplayWake()
    try nonRemoteActionDoesNotTriggerDisplayWake()
    try displayWakeIsReleasedAfterHandling()
    try displayWakeSettleDelayIsCorrect()
    print("✅ Display wake integration tests passed")
  }

  private static func makeHandler(spy: DisplayWakeSpy) -> AgentRequestHandler {
    AgentRequestHandler(
      configuration: AgentConfiguration(
        socketPath: "/tmp/test-display-wake.sock",
        version: "9.9.9",
        build: "test",
        maxScreenshotBytes: 1024,
        maxRequestBytes: 1024
      ),
      permissions: FakePermissionService(),
      screenshots: FakeScreenshotService(),
      accessibility: FakeAccessibilityService(),
      osascript: FakeOsascriptService(),
      displayWakeFactory: { settleDelay in spy.makeWake(settleDelay: settleDelay) }
    )
  }

  /// osascript.run must trigger the display wake factory.
  private static func osascriptRunTriggersDisplayWake() throws {
    let spy = DisplayWakeSpy()
    let handler = makeHandler(spy: spy)
    spy.pendingAction = "osascript.run"

    let result: Envelope<OsascriptRunPayload> = try send(
      AgentRequest(
        id: "test_osascript_wake",
        action: "osascript.run",
        params: AgentRequestParams(script: "return 1", language: "applescript", timeout: 5)
      ),
      to: handler
    )

    expect(result.ok, "osascript.run should succeed")
    expectEqual(spy.callCount, 1, "osascript.run must trigger display wake factory")
    expectEqual(spy.invocations.first?.action, "osascript.run", "factory should record osascript.run action")
  }

  /// ax.* actions must trigger the display wake factory.
  private static func axActionTriggersDisplayWake() throws {
    let spy = DisplayWakeSpy()
    let handler = makeHandler(spy: spy)
    spy.pendingAction = "ax.list-apps"

    let result: Envelope<AXAppListPayload> = try send(
      AgentRequest(id: "test_ax_wake", action: "ax.list-apps", params: AgentRequestParams()),
      to: handler
    )

    expect(result.ok, "ax.list-apps should succeed")
    expectEqual(spy.callCount, 1, "ax.list-apps must trigger display wake factory")
    expectEqual(spy.invocations.first?.action, "ax.list-apps", "factory should record ax.list-apps action")
  }

  /// Non-remote-control actions (e.g. agent.status) must NOT trigger the wake factory.
  private static func nonRemoteActionDoesNotTriggerDisplayWake() throws {
    let spy = DisplayWakeSpy()
    let handler = makeHandler(spy: spy)
    spy.pendingAction = "agent.status"

    let result: Envelope<AgentStatusPayload> = try send(
      AgentRequest(id: "test_status_no_wake", action: "agent.status", params: AgentRequestParams()),
      to: handler
    )

    expect(result.ok, "agent.status should succeed")
    expectEqual(spy.callCount, 0, "agent.status must NOT trigger display wake factory")
  }

  /// The wake guard's release() must be called after the request is handled.
  private static func displayWakeIsReleasedAfterHandling() throws {
    let spy = DisplayWakeSpy()
    let handler = makeHandler(spy: spy)
    spy.pendingAction = "osascript.run"

    let _: Envelope<OsascriptRunPayload> = try send(
      AgentRequest(
        id: "test_release",
        action: "osascript.run",
        params: AgentRequestParams(script: "return 1", language: "applescript", timeout: 5)
      ),
      to: handler
    )

    expect(spy.lastWake != nil, "a wake guard should have been created")
    expect(spy.lastWake!.released, "wake guard release() must be called after handling")
  }

  /// The settle delay passed to the factory must be 0.5 (matching the handler).
  private static func displayWakeSettleDelayIsCorrect() throws {
    let spy = DisplayWakeSpy()
    let handler = makeHandler(spy: spy)
    spy.pendingAction = "osascript.run"

    let _: Envelope<OsascriptRunPayload> = try send(
      AgentRequest(
        id: "test_settle",
        action: "osascript.run",
        params: AgentRequestParams(script: "return 1", language: "applescript", timeout: 5)
      ),
      to: handler
    )

    expectEqual(spy.invocations.first?.settleDelay, 0.5, "settle delay must be 0.5s")
  }
}
