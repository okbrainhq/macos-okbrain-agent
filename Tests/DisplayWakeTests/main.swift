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
  func menuClick(query: AXElementQuery, title: String) throws -> AXMenuActionPayload {
    AXMenuActionPayload(
      action: "ax.menu-click",
      appName: query.appName ?? "Test",
      path: [title],
      item: AXElementNode(role: "AXMenuBarItem", subrole: nil, title: title, label: nil, identifier: nil, value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil)
    )
  }
  func menuNavigate(query: AXElementQuery, path: [String]) throws -> AXMenuActionPayload {
    AXMenuActionPayload(
      action: "ax.menu-navigate",
      appName: query.appName ?? "Test",
      path: path,
      item: AXElementNode(role: "AXMenuItem", subrole: nil, title: path.last, label: nil, identifier: nil, value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil)
    )
  }
  func menuListItems(query: AXElementQuery) throws -> AXMenuListPayload {
    AXMenuListPayload(appName: query.appName ?? "Test", items: [AXMenuItemPayload(title: "File", enabled: true)])
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
  func ensureFrontmost(pid: Int32?) {}
}

struct FakeReadFunction: MacOSFunction {
  let name = "test.read"
  let summary = "A test-only read function."
  let tier: FunctionTier = .read
  let argSchema: [FunctionArg] = []
  let catalogTargetBundleID: String? = nil

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(
      args: try validateFunctionArgs(args, schema: []),
      permissionTarget: GlobalPermissionCategory.power.permissionTarget
    )
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    FunctionResult(value: .object("ok", .bool(true)))
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
    try functionRunTriggersDisplayWake()
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
      functionRegistry: FunctionRegistry(functions: [FakeReadFunction()]),
      axPermissionCoordinator: AXPermissionCoordinator(rules: [
        AXAppPermissionRule(target: GlobalPermissionCategory.power.permissionTarget, mode: .observe),
        AXAppPermissionRule(target: GlobalPermissionCategory.applicationDiscovery.permissionTarget, mode: .observe)
      ]),
      displayWakeFactory: { settleDelay in spy.makeWake(settleDelay: settleDelay) }
    )
  }

  /// functions.run must trigger the display wake factory.
  private static func functionRunTriggersDisplayWake() throws {
    let spy = DisplayWakeSpy()
    let handler = makeHandler(spy: spy)
    spy.pendingAction = "functions.run"

    let result: Envelope<FunctionRunPayload> = try send(
      AgentRequest(
        id: "test_function_wake",
        action: "functions.run",
        params: AgentRequestParams(functionName: "test.read", args: [:])
      ),
      to: handler
    )

    expect(result.ok, "functions.run should succeed")
    expectEqual(spy.callCount, 1, "functions.run must trigger display wake factory")
    expectEqual(spy.invocations.first?.action, "functions.run", "factory should record functions.run action")
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
    spy.pendingAction = "functions.run"

    let _: Envelope<FunctionRunPayload> = try send(
      AgentRequest(
        id: "test_release",
        action: "functions.run",
        params: AgentRequestParams(functionName: "test.read", args: [:])
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
    spy.pendingAction = "functions.run"

    let _: Envelope<FunctionRunPayload> = try send(
      AgentRequest(
        id: "test_settle",
        action: "functions.run",
        params: AgentRequestParams(functionName: "test.read", args: [:])
      ),
      to: handler
    )

    expectEqual(spy.invocations.first?.settleDelay, 0.5, "settle delay must be 0.5s")
  }
}
