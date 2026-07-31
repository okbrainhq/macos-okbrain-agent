import AppKit
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
  let screenshot = CapturedImage(data: Data([0x52, 0x49, 0x46, 0x46]), mimeType: "image/webp", width: 64, height: 32)
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
    "screenshot.cursor",
    "screenshot.webp",
    "screenshot.binary",
    "functions.list",
    "functions.run",
    "functions.propose"
  ], "capabilities")

  let capture = try sendFrame(
    AgentRequest(
      id: "req_capture",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "webp", includeCursor: false, quality: 80)
    ),
    to: handler,
    as: ScreenshotCapturePayload.self
  )
  expect(capture.envelope.ok, "capture response should be ok")
  expectEqual(capture.envelope.data?.mimeType, "image/webp", "capture mime type")
  expectEqual(capture.envelope.data?.encoding, "binary", "capture encoding")
  expectEqual(capture.envelope.data?.byteLength, screenshot.data.count, "capture byte length")
  expectEqual(capture.bodyData, screenshot.data, "capture binary body")
  expectEqual(capture.envelope.data?.width, 64, "capture width")
  expectEqual(capture.envelope.data?.height, 32, "capture height")

  let deniedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .unknown)),
    screenshots: FakeScreenshotService(capturedImage: screenshot)
  )
  let denied: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "req_denied",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "webp", includeCursor: false, quality: 80)
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

  try verifyScreenshotPidRaise(configuration: configuration, screenshot: screenshot)

  try runAccessibilityVerifier(configuration: configuration)

  try runGuardrailsAndFunctionsVerifier(configuration: configuration)
  try verifyMenuBarExtraFunctions(configuration: configuration, screenshot: screenshot)
  try verifyWindowAndMenuFunctions(configuration: configuration, screenshot: screenshot)

  try runConfigurationVerifier()
  try runFileEditingVerifier(permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .unknown)))
}

func runAccessibilityVerifier(configuration: AgentConfiguration) throws {
  let screenshot = CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1)
  let axPermissions = FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted))
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: axPermissions,
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: FakeAccessibilityService(),
    axPermissionCoordinator: AXPermissionCoordinator(
      rules: [AXAppPermissionRule(bundleID: "com.apple.TextEdit", appName: "TextEdit", mode: .control)],
      prompter: FakePermissionPrompter(response: .allowOnce)
    ),
    axTargetResolver: FakeAXTargetResolver()
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(id: "req_ax_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "ax status should be ok")
  expect(status.data?.capabilities.contains("ax.find") == true, "ax capabilities should be listed when accessibility is granted")
  for action in ["ax.menu-click", "ax.menu-navigate", "ax.menu-list"] {
    expect(status.data?.capabilities.contains(action) == true, "\(action) capability should be listed when accessibility is granted")
  }

  let apps: Envelope<AXAppListPayload> = try send(
    AgentRequest(id: "req_ax_apps", action: "ax.list-apps", params: AgentRequestParams()),
    to: handler
  )
  expect(apps.ok, "ax.list-apps should be ok")
  expectEqual(apps.data?.apps.first?.name, "TextEdit", "ax.list-apps app name")
  expectEqual(apps.data?.apps.first?.pid, 4242, "ax.list-apps pid")

  let windows: Envelope<AXWindowListPayload> = try send(
    AgentRequest(id: "req_ax_windows", action: "ax.list-windows", params: AgentRequestParams(appName: "TextEdit")),
    to: handler
  )
  expect(windows.ok, "ax.list-windows should be ok")
  expectEqual(windows.data?.windows.first?.title, "Untitled", "ax.list-windows window title")

  let tree: Envelope<AXTreePayload> = try send(
    AgentRequest(id: "req_ax_tree", action: "ax.get-tree", params: AgentRequestParams(appName: "TextEdit", depth: 4)),
    to: handler
  )
  expect(tree.ok, "ax.get-tree should be ok")
  expectEqual(tree.data?.root.role, "AXWindow", "ax.get-tree root role")
  expectEqual(tree.data?.root.children?.first?.title, "OK", "ax.get-tree child title")

  let find: Envelope<AXFindPayload> = try send(
    AgentRequest(id: "req_ax_find", action: "ax.find", params: AgentRequestParams(appName: "TextEdit", role: "AXButton", title: "OK")),
    to: handler
  )
  expect(find.ok, "ax.find should be ok")
  expectEqual(find.data?.matches.first?.identifier, "okButton", "ax.find identifier")

  let perform: Envelope<AXPerformPayload> = try send(
    AgentRequest(id: "req_ax_perform", action: "ax.perform", params: AgentRequestParams(appName: "TextEdit", role: "AXButton", title: "OK", action: "press")),
    to: handler
  )
  expect(perform.ok, "ax.perform should be ok")
  expectEqual(perform.data?.action, "press", "ax.perform action")

  let menuClick: Envelope<AXMenuActionPayload> = try send(
    AgentRequest(id: "req_ax_menu_click", action: "ax.menu-click", params: AgentRequestParams(appName: "TextEdit", title: "File")),
    to: handler
  )
  expect(menuClick.ok, "ax.menu-click should be ok")
  expectEqual(menuClick.data?.action, "ax.menu-click", "ax.menu-click action")
  expectEqual(menuClick.data?.path, ["File"], "ax.menu-click path")

  let menuNavigate: Envelope<AXMenuActionPayload> = try send(
    AgentRequest(
      id: "req_ax_menu_navigate",
      action: "ax.menu-navigate",
      params: AgentRequestParams(appName: "TextEdit", menuPath: ["File", "New"])
    ),
    to: handler
  )
  expect(menuNavigate.ok, "ax.menu-navigate should be ok")
  expectEqual(menuNavigate.data?.path, ["File", "New"], "ax.menu-navigate path")
  expectEqual(menuNavigate.data?.item.title, "New", "ax.menu-navigate final item")

  let menuList: Envelope<AXMenuListPayload> = try send(
    AgentRequest(id: "req_ax_menu_list", action: "ax.menu-list", params: AgentRequestParams(appName: "TextEdit")),
    to: handler
  )
  expect(menuList.ok, "ax.menu-list should be ok")
  expectEqual(menuList.data?.appName, "TextEdit", "ax.menu-list app name")
  expectEqual(menuList.data?.items.map(\.title), ["TextEdit", "File", "Edit"], "ax.menu-list item titles")

  let missingMenuTitle: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_menu_click_missing", action: "ax.menu-click", params: AgentRequestParams(appName: "TextEdit", title: " ")),
    to: handler
  )
  expect(!missingMenuTitle.ok, "ax.menu-click without a title should fail")
  expectEqual(missingMenuTitle.error?.code, "invalid_request", "missing menu title error code")

  let missingMenuPath: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_menu_navigate_missing", action: "ax.menu-navigate", params: AgentRequestParams(appName: "TextEdit", menuPath: [])),
    to: handler
  )
  expect(!missingMenuPath.ok, "ax.menu-navigate without a path should fail")
  expectEqual(missingMenuPath.error?.code, "invalid_request", "missing menu path error code")

  let emptyMenuPathSegment: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_menu_navigate_empty_segment", action: "ax.menu-navigate", params: AgentRequestParams(appName: "TextEdit", menuPath: ["File", " "])),
    to: handler
  )
  expect(!emptyMenuPathSegment.ok, "ax.menu-navigate with an empty path segment should fail")
  expectEqual(emptyMenuPathSegment.error?.code, "invalid_request", "empty menu path segment error code")

  let filePathRoundTrip = AgentRequest(
    id: "req_file_path_round_trip",
    action: "fs.read",
    params: AgentRequestParams(path: "/tmp/project/README.md")
  )
  let decodedFilePathRoundTrip = try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(filePathRoundTrip))
  expectEqual(decodedFilePathRoundTrip.params?.path, "/tmp/project/README.md", "string file path must round-trip")
  expectEqual(decodedFilePathRoundTrip.params?.menuPath, nil, "string file path must not decode as a menu path")

  let menuPathRoundTrip = AgentRequest(
    id: "req_menu_path_round_trip",
    action: "ax.menu-navigate",
    params: AgentRequestParams(menuPath: ["File", "New"])
  )
  let encodedMenuPathRoundTrip = try JSONEncoder().encode(menuPathRoundTrip)
  let menuPathRequestObject = try JSONSerialization.jsonObject(with: encodedMenuPathRoundTrip) as? [String: Any]
  let menuPathParamsObject = menuPathRequestObject?["params"] as? [String: Any]
  expectEqual(menuPathParamsObject?["path"] as? [String], ["File", "New"], "menu path must encode on the path wire key")
  let decodedMenuPathRoundTrip = try JSONDecoder().decode(AgentRequest.self, from: encodedMenuPathRoundTrip)
  expectEqual(decodedMenuPathRoundTrip.params?.menuPath, ["File", "New"], "array menu path must round-trip")
  expectEqual(decodedMenuPathRoundTrip.params?.path, nil, "array menu path must not decode as a file path")

  let rawMenuNavigate: Envelope<AXMenuActionPayload> = try sendRaw(
    Data(#"{"protocol":"okbrain.macos-agent.v3","id":"req_ax_menu_navigate_raw","action":"ax.menu-navigate","params":{"appName":"TextEdit","path":["File","New"]}}"#.utf8),
    to: handler
  )
  expect(rawMenuNavigate.ok, "raw JSON array path should dispatch ax.menu-navigate")
  expectEqual(rawMenuNavigate.data?.path, ["File", "New"], "raw JSON menu path")

  let malformedMenuPath: Envelope<EmptyPayload> = try sendRaw(
    Data(#"{"protocol":"okbrain.macos-agent.v3","id":"req_ax_menu_navigate_malformed","action":"ax.menu-navigate","params":{"appName":"TextEdit","path":42}}"#.utf8),
    to: handler
  )
  expect(!malformedMenuPath.ok, "non-string/non-array path should fail decoding")
  expectEqual(malformedMenuPath.error?.code, "invalid_request", "malformed menu path error code")

  let observeOnlyHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: axPermissions,
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: FakeAccessibilityService(),
    axPermissionCoordinator: AXPermissionCoordinator(
      rules: [AXAppPermissionRule(bundleID: "com.apple.TextEdit", appName: "TextEdit", mode: .observe)],
      prompter: FakePermissionPrompter(response: .notNow)
    ),
    axTargetResolver: FakeAXTargetResolver()
  )
  let observedMenuList: Envelope<AXMenuListPayload> = try send(
    AgentRequest(id: "req_ax_menu_list_observe", action: "ax.menu-list", params: AgentRequestParams(appName: "TextEdit")),
    to: observeOnlyHandler
  )
  expect(observedMenuList.ok, "Observe permission should allow ax.menu-list")
  let blockedMenuClick: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_menu_click_observe", action: "ax.menu-click", params: AgentRequestParams(appName: "TextEdit", title: "File")),
    to: observeOnlyHandler
  )
  expect(!blockedMenuClick.ok, "Observe permission must not allow ax.menu-click")
  expectEqual(blockedMenuClick.error?.code, "app_permission_required", "menu click requires Control")

  let frontmostMenuTarget = AXResolvedTarget(
    target: AXPermissionTarget(bundleID: "com.example.MenuTarget", appName: "Menu Target", pid: 987),
    pid: 987,
    wasResolved: true
  )
  let frontmostMenuResolver = RecordingAXTargetResolver(resolution: frontmostMenuTarget, isCurrent: true)
  let frontmostMenuAccessibility = RecordingAccessibilityService(apps: [])
  let frontmostMenuHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: axPermissions,
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: frontmostMenuAccessibility,
    axPermissionCoordinator: AXPermissionCoordinator(
      rules: [AXAppPermissionRule(bundleID: "com.example.MenuTarget", appName: "Menu Target", mode: .control)]
    ),
    axTargetResolver: frontmostMenuResolver
  )
  let _: Envelope<AXMenuListPayload> = try send(
    AgentRequest(id: "req_ax_menu_list_frontmost", action: "ax.menu-list", params: AgentRequestParams()),
    to: frontmostMenuHandler
  )
  let _: Envelope<AXMenuActionPayload> = try send(
    AgentRequest(id: "req_ax_menu_click_frontmost", action: "ax.menu-click", params: AgentRequestParams(title: "File")),
    to: frontmostMenuHandler
  )
  let _: Envelope<AXMenuActionPayload> = try send(
    AgentRequest(id: "req_ax_menu_navigate_frontmost", action: "ax.menu-navigate", params: AgentRequestParams(menuPath: ["File", "New"])),
    to: frontmostMenuHandler
  )
  expectEqual(frontmostMenuResolver.frontmostFallbackRequests, [true, true, true], "all high-level menu actions must use frontmost fallback")
  expectEqual(frontmostMenuAccessibility.menuQueryPIDs, [987, 987, 987], "menu dispatch must use the authorized captured PID")

  let getValue: Envelope<AXValuePayload> = try send(
    AgentRequest(id: "req_ax_get_value", action: "ax.get-value", params: AgentRequestParams(appName: "TextEdit", identifier: "nameField")),
    to: handler
  )
  expect(getValue.ok, "ax.get-value should be ok")
  expectEqual(getValue.data?.element.value, .string("hello"), "ax.get-value value")

  let setValue: Envelope<AXValuePayload> = try send(
    AgentRequest(id: "req_ax_set_value", action: "ax.set-value", params: AgentRequestParams(appName: "TextEdit", identifier: "nameField", value: "world")),
    to: handler
  )
  expect(setValue.ok, "ax.set-value should be ok")

  let typeText: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_type", action: "ax.type-text", params: AgentRequestParams(text: "hello world")),
    to: handler
  )
  expect(typeText.ok, "ax.type-text should be ok")

  let keyPress: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_key", action: "ax.key-press", params: AgentRequestParams(key: "s", modifiers: ["command"])),
    to: handler
  )
  expect(keyPress.ok, "ax.key-press should be ok")

  let scroll: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_scroll", action: "ax.scroll", params: AgentRequestParams(appName: "TextEdit", deltaY: 5)),
    to: handler
  )
  expect(scroll.ok, "ax.scroll should be ok")

  let clickAt: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "req_ax_click", action: "ax.click-at", params: AgentRequestParams(x: 120, y: 340)),
    to: handler
  )
  expect(clickAt.ok, "ax.click-at should be ok")

  let missingValue: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_set_value_missing", action: "ax.set-value", params: AgentRequestParams(appName: "TextEdit", identifier: "nameField")),
    to: handler
  )
  expect(!missingValue.ok, "ax.set-value without value should fail")
  expectEqual(missingValue.error?.code, "invalid_request", "missing value error code")

  let missingCoords: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_click_missing", action: "ax.click-at", params: AgentRequestParams(x: 1)),
    to: handler
  )
  expect(!missingCoords.ok, "ax.click-at without y should fail")
  expectEqual(missingCoords.error?.code, "invalid_request", "missing coords error code")

  let deniedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .granted, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: FakeAccessibilityService()
  )
  let denied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_ax_denied", action: "ax.list-apps", params: AgentRequestParams()),
    to: deniedHandler
  )
  expect(!denied.ok, "ax action should fail without accessibility permission")
  expectEqual(denied.error?.code, "permission_denied", "ax permission denied code")

  let deniedStatus: Envelope<AgentStatusPayload> = try send(
    AgentRequest(id: "req_ax_denied_status", action: "agent.status", params: AgentRequestParams()),
    to: deniedHandler
  )
  expect(deniedStatus.ok, "denied status should be ok")
  expect(deniedStatus.data?.capabilities.contains("ax.find") == false, "ax capabilities must be hidden when accessibility is denied")
  for action in ["ax.menu-click", "ax.menu-navigate", "ax.menu-list"] {
    expect(deniedStatus.data?.capabilities.contains(action) == false, "\(action) capability must be hidden when accessibility is denied")
  }
}

func runGuardrailsAndFunctionsVerifier(configuration: AgentConfiguration) throws {
  let screenshot = CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1)
  let functionState = FunctionRuntimeState()
  let registry = FunctionRegistry(functions: [VerifierReadFunction(), VerifierWriteFunction()])
  let allowCoordinator = AXPermissionCoordinator(
    rules: [
      AXAppPermissionRule(bundleID: "com.example.TestApp", appName: "Test App", mode: .control),
      AXAppPermissionRule(target: GlobalPermissionCategory.power.permissionTarget, mode: .observe)
    ],
    prompter: FakePermissionPrompter(response: .allowOnce)
  )
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: registry,
    functionState: functionState,
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: allowCoordinator,
    axTargetResolver: FakeAXTargetResolver()
  )

  let catalog: Envelope<FunctionListPayload> = try send(
    AgentRequest(id: "req_functions_list", action: "functions.list", params: AgentRequestParams()),
    to: handler
  )
  expect(catalog.ok, "functions.list should be ok")
  expect(catalog.data?.functions.contains(where: { $0.name == "test.read" }) == true, "functions.list should include registered functions")

  let read: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "req_functions_read", action: "functions.run", params: AgentRequestParams(functionName: "test.read", args: ["message": .string("hello")])),
    to: handler
  )
  expect(read.ok, "enabled tier-1 function should run")
  expectEqual(read.data?.result.value, .object("message", .string("hello")), "tier-1 result")

  let invalidArgs: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_functions_invalid", action: "functions.run", params: AgentRequestParams(functionName: "test.read", args: [:])),
    to: handler
  )
  expect(!invalidArgs.ok, "invalid function args should fail")
  expectEqual(invalidArgs.error?.code, "invalid_args", "invalid args error code")

  let disabled: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_functions_disabled", action: "functions.run", params: AgentRequestParams(functionName: "test.write", args: [:])),
    to: handler
  )
  expect(!disabled.ok, "tier-2 function must be disabled by default")
  expectEqual(disabled.error?.code, "function_disabled", "disabled function error code")

  functionState.setEnabled(true, for: "test.write")
  let write: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "req_functions_write", action: "functions.run", params: AgentRequestParams(functionName: "test.write", args: [:])),
    to: handler
  )
  expect(write.ok, "enabled and allowed tier-2 function should run")

  let unknownFunction: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_unknown_function", action: "functions.run", params: AgentRequestParams(functionName: "missing.function", args: [:])),
    to: handler
  )
  expect(!unknownFunction.ok, "unknown function should fail")
  expectEqual(unknownFunction.error?.code, "unknown_function", "unknown function error code")

  let removedRawScript: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_removed_raw_script", action: "osascript.run", params: AgentRequestParams()),
    to: handler
  )
  expect(!removedRawScript.ok, "raw osascript action must be removed")
  expectEqual(removedRawScript.error?.code, "unknown_action", "removed raw osascript error code")

  let proposal: Envelope<FunctionProposalPayload> = try send(
    AgentRequest(
      id: "req_functions_propose",
      action: "functions.propose",
      params: AgentRequestParams(name: "sample.template", description: "A safe sample", rationale: "Verification", exampleScript: "return $value")
    ),
    to: handler
  )
  expect(proposal.ok, "functions.propose should store a proposal")
  expectEqual(functionState.snapshot().proposals.count, 1, "proposal inbox count")

  let unapprovedState = FunctionRuntimeState(enabledFunctionNames: ["test.write"])
  let unapprovedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: registry,
    functionState: unapprovedState,
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(
      prompter: FakePermissionPrompter(response: .notNow)
    ),
    axTargetResolver: FakeAXTargetResolver()
  )
  let unapprovedControl: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "req_function_unapproved", action: "functions.run", params: AgentRequestParams(functionName: "test.write", args: [:])),
    to: unapprovedHandler
  )
  expect(!unapprovedControl.ok, "default-deny must block an unapproved function write")
  expectEqual(unapprovedControl.error?.code, "app_permission_required", "app permission error code")
  guard case .object(let permissionDetails)? = unapprovedControl.error?.details else {
    throw NSError(domain: "ProtocolVerifier", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing app permission details"])
  }
  expectEqual(permissionDetails["bundleID"], .string("com.example.TestApp"), "app permission bundle detail")
  expectEqual(permissionDetails["pending"], .bool(false), "Not Now must not report a pending request")

  let engine = AXPermissionRuleEngine(rules: [])
  expectEqual(engine.decision(for: nil, intent: .observe), .requiresApproval, "unknown app reads should require approval")
  expectEqual(engine.decision(for: nil, intent: .control), .requiresApproval, "unknown app writes should require approval")
  let observeEngine = AXPermissionRuleEngine(rules: [
    AXAppPermissionRule(bundleID: "com.example.Observe", appName: "Observe", mode: .observe)
  ])
  expectEqual(observeEngine.decision(for: "com.example.Observe", intent: .observe), .allow, "Observe should allow reads")
  expectEqual(observeEngine.decision(for: "com.example.Observe", intent: .control), .requiresApproval, "Observe should not allow control")

  let timeoutCoordinator = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .timedOut))
  do {
    try timeoutCoordinator.authorizeControl(target: AXPermissionTarget(bundleID: "com.example.Pending", appName: "Pending"), action: "ax.perform")
    expect(false, "timed-out prompt should require permission")
  } catch let error as AgentProtocolError {
    expectEqual(error.code, "app_permission_required", "timeout permission error")
  }
  expectEqual(timeoutCoordinator.snapshot().pendingRequests.count, 1, "timed-out prompt should enqueue a pending request")

  let unsafeProposal = try functionState.submitProposal(
    name: "unsafe.template",
    description: "Unsafe",
    rationale: "Verifier",
    exampleScript: "do shell script \"id\""
  )
  do {
    _ = try functionState.approveProposal(
      id: unsafeProposal.id,
      approvedSourceDigest: TemplateSourceReview.digest(for: unsafeProposal.exampleScript ?? "")
    )
    expect(false, "unsafe template should not be approvable")
  } catch let error as AgentProtocolError {
    expectEqual(error.code, "invalid_args", "unsafe template rejection code")
  }

  print("Verifier: permission coordinator hardening")
  try verifyPermissionCoordinatorHardening()
  print("Verifier: visibility and captured PID dispatch")
  try verifyVisibilityAndCapturedPIDDispatch(configuration: configuration, screenshot: screenshot)
  print("Verifier: final function gates and automation")
  try verifyFunctionFinalGateAndAutomationBranches(configuration: configuration, screenshot: screenshot)
  print("Verifier: global permission categories")
  try verifyGlobalPermissionCategories(configuration: configuration, screenshot: screenshot)
  print("Verifier: stored template review and output bounds")
  try verifyStoredTemplateReviewAndOutputBounds()
}

func expectAgentErrorCode(_ code: String, operation: () throws -> Void) throws -> AgentProtocolError {
  do {
    try operation()
  } catch let error as AgentProtocolError {
    expectEqual(error.code, code, "protocol error code")
    return error
  }
  throw NSError(domain: "ProtocolVerifier", code: 5, userInfo: [NSLocalizedDescriptionKey: "Expected protocol error \(code)"])
}

func verifyPermissionCoordinatorHardening() throws {
  let target = AXPermissionTarget(bundleID: "com.example.Session", appName: "Session App", pid: 77)

  let defaultDeny = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .notNow))
  _ = try expectAgentErrorCode("app_permission_required") {
    try defaultDeny.authorizeObservation(target: target, action: "ax.get-tree")
  }
  _ = try expectAgentErrorCode("app_permission_required") {
    try defaultDeny.authorizeControl(target: target, action: "ax.perform")
  }
  expect(defaultDeny.snapshot().rules.isEmpty, "Not Now must not persist a negative rule")

  let observeOnce = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .allowOnce))
  try observeOnce.authorizeObservation(target: target, action: "ax.get-tree")
  try observeOnce.recheckObservationWithoutPrompt(target: target, action: "ax.get-tree")
  _ = try expectAgentErrorCode("app_permission_required") {
    try observeOnce.recheckControlWithoutPrompt(target: target, action: "ax.perform")
  }
  expect(observeOnce.snapshot().rules.isEmpty, "Allow Once Observe must remain session-only")

  let escalationPrompter = SequencePermissionPrompter(responses: [.allowOnce, .timedOut])
  let observeThenDismissControl = AXPermissionCoordinator(prompter: escalationPrompter)
  try observeThenDismissControl.authorizeObservation(target: target, action: "ax.get-tree")
  _ = try expectAgentErrorCode("app_permission_required") {
    try observeThenDismissControl.authorizeControl(target: target, action: "ax.perform")
  }
  guard let pendingControlID = observeThenDismissControl.snapshot().pendingRequests.first?.id else {
    throw NSError(domain: "ProtocolVerifier", code: 13, userInfo: [NSLocalizedDescriptionKey: "Expected a pending Control escalation"])
  }
  expect(
    observeThenDismissControl.resolvePendingRequest(id: pendingControlID, resolution: .dismiss),
    "dismissed Control escalation should be removed"
  )
  try observeThenDismissControl.recheckObservationWithoutPrompt(target: target, action: "ax.get-tree")
  _ = try expectAgentErrorCode("app_permission_required") {
    try observeThenDismissControl.recheckControlWithoutPrompt(target: target, action: "ax.perform")
  }

  let observeAlways = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .allowAlways))
  try observeAlways.authorizeObservation(target: target, action: "ax.get-tree")
  expectEqual(observeAlways.snapshot().rules.first?.mode, .observe, "Always Allow Observe should persist Observe")
  _ = try expectAgentErrorCode("app_permission_required") {
    try observeAlways.recheckControlWithoutPrompt(target: target, action: "ax.perform")
  }

  let controlAlways = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .allowAlways))
  try controlAlways.authorizeControl(target: target, action: "ax.perform")
  expectEqual(controlAlways.snapshot().rules.first?.mode, .control, "Always Allow Control should persist Control")
  try controlAlways.recheckObservationWithoutPrompt(target: target, action: "ax.get-tree")
  try controlAlways.recheckControlWithoutPrompt(target: target, action: "ax.perform")
  controlAlways.replaceRules([])
  _ = try expectAgentErrorCode("app_permission_required") {
    try controlAlways.recheckObservationWithoutPrompt(target: target, action: "ax.get-tree")
  }

  let timeout = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .timedOut))
  let timeoutError = try expectAgentErrorCode("app_permission_required") {
    try timeout.authorizeObservation(target: target, action: "ax.get-tree")
  }
  guard case .object(let timeoutDetails)? = timeoutError.details else {
    throw NSError(domain: "ProtocolVerifier", code: 6, userInfo: [NSLocalizedDescriptionKey: "Timed-out approval lacks details"])
  }
  expectEqual(timeoutDetails["pending"], .bool(true), "timeout should report a queued request")
  expectEqual(timeout.snapshot().pendingRequests.first?.intent, .observe, "pending request must retain requested intent")
  _ = try expectAgentErrorCode("app_permission_required") {
    try timeout.authorizeObservation(target: target, action: "ax.get-tree")
  }
  expectEqual(timeout.snapshot().pendingRequests.count, 1, "identical timeouts must deduplicate")
  if let pendingID = timeout.snapshot().pendingRequests.first?.id {
    expect(timeout.resolvePendingRequest(id: pendingID, resolution: .allowAlways), "pending Observe request should resolve")
    expect(timeout.snapshot().pendingRequests.isEmpty, "resolved pending request should be removed")
    try timeout.recheckObservationWithoutPrompt(target: target, action: "ax.get-tree")
  } else {
    throw NSError(domain: "ProtocolVerifier", code: 12, userInfo: [NSLocalizedDescriptionKey: "Expected a pending Observe request"])
  }

  let capped = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .timedOut))
  for index in 0..<(AXPermissionCoordinator.maximumPendingRequestCount + 1) {
    let candidate = AXPermissionTarget(bundleID: "com.example.Pending\(index)", appName: "Pending \(index)")
    _ = try expectAgentErrorCode("app_permission_required") {
      try capped.authorizeControl(target: candidate, action: "ax.perform")
    }
  }
  expectEqual(capped.snapshot().pendingRequests.count, AXPermissionCoordinator.maximumPendingRequestCount, "pending inbox must be capped")

  let persistedPending = AXPermissionCoordinator(pendingRequests: [
    AXPendingPermissionRequest(
      target: AXPermissionTarget(bundleID: "com.example.Loaded", appName: "Loaded"),
      intent: .control,
      action: "ax.perform",
      context: "first"
    ),
    AXPendingPermissionRequest(
      target: AXPermissionTarget(bundleID: "com.example.Loaded", appName: "Loaded"),
      intent: .control,
      action: "ax.perform",
      context: "duplicate"
    ),
    AXPendingPermissionRequest(
      target: AXPermissionTarget(bundleID: "com.example.Invalid", appName: String(repeating: "x", count: 256)),
      intent: .control,
      action: "ax.perform",
      context: "invalid"
    )
  ])
  expectEqual(persistedPending.snapshot().pendingRequests.count, 1, "loaded pending requests must be sanitized and deduplicated")

  let recordingPrompter = CountingPermissionPrompter(response: .timedOut)
  let unresolved = AXPermissionCoordinator(prompter: recordingPrompter)
  let unresolvedError = try expectAgentErrorCode("app_permission_required") {
    try unresolved.authorizeControl(
      target: AXPermissionTarget(bundleID: nil, appName: "Spoofed Safari"),
      action: "ax.perform"
    )
  }
  guard case .object(let unresolvedDetails)? = unresolvedError.details else {
    throw NSError(domain: "ProtocolVerifier", code: 10, userInfo: [NSLocalizedDescriptionKey: "Unresolved target lacks details"])
  }
  expectEqual(unresolvedDetails["pending"], .bool(false), "unresolved spoofable targets must not queue pending approval")
  expectEqual(recordingPrompter.count, 0, "unresolved targets must not show an approval prompt")

  let invalidObservePrompter = CountingPermissionPrompter(response: .timedOut)
  let invalidObserve = AXPermissionCoordinator(prompter: invalidObservePrompter)
  let invalidObserveError = try expectAgentErrorCode("app_permission_required") {
    try invalidObserve.authorizeObservation(
      target: PermissionTarget(applicationBundleID: "invalid", appName: "Invalid"),
      action: "ax.get-tree"
    )
  }
  guard case .object(let invalidObserveDetails)? = invalidObserveError.details else {
    throw NSError(domain: "ProtocolVerifier", code: 14, userInfo: [NSLocalizedDescriptionKey: "Invalid Observe target lacks details"])
  }
  expectEqual(invalidObserveDetails["intent"], .string("observe"), "invalid Observe errors must preserve the requested intent")
  expectEqual(invalidObservePrompter.count, 0, "invalid Observe targets must not show a prompt")

  let global = GlobalPermissionCategory.clipboard.permissionTarget
  let globalObserve = AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .allowAlways))
  try globalObserve.authorizeObservation(target: global, action: "functions.run → system.get-clipboard")
  expectEqual(globalObserve.snapshot().rules.first?.target.kind, .category, "global grants must remain category targets")
  expectEqual(globalObserve.snapshot().rules.first?.target.identifier, GlobalPermissionCategory.clipboard.rawValue, "global category ID")
  _ = try expectAgentErrorCode("app_permission_required") {
    try globalObserve.recheckControlWithoutPrompt(target: global, action: "functions.run → system.set-clipboard")
  }

  let legacyJSON: [String: Any] = [
    "rules": [
      ["bundleID": "com.example.LegacyDeny", "appName": "Legacy Deny", "mode": "deny"],
      ["bundleID": "com.example.LegacyObserve", "appName": "Legacy Observe", "mode": "observe"]
    ],
    "pendingRequests": []
  ]
  let migrated = try JSONDecoder().decode(
    AXPermissionStateSnapshot.self,
    from: JSONSerialization.data(withJSONObject: legacyJSON)
  )
  expectEqual(migrated.rules.count, 1, "legacy deny rules must migrate to default-deny absence")
  expectEqual(migrated.rules.first?.mode, .observe, "legacy Observe should survive migration")

  let currentSnapshot = AXPermissionStateSnapshot(
    rules: [AXAppPermissionRule(target: GlobalPermissionCategory.network.permissionTarget, mode: .observe)],
    pendingRequests: []
  )
  let roundTrip = try JSONDecoder().decode(
    AXPermissionStateSnapshot.self,
    from: JSONEncoder().encode(currentSnapshot)
  )
  expectEqual(roundTrip, currentSnapshot, "current generalized permission state must round-trip through persistence")
}

func verifyScreenshotPidRaise(configuration: AgentConfiguration, screenshot: CapturedImage) throws {
  let accessibility = RecordingAccessibilityService(apps: [])
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .granted, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: accessibility
  )

  // A capture that names a pid raises that app to the front first (best-effort).
  let withPid = try sendFrame(
    AgentRequest(
      id: "req_capture_pid",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "webp", pid: 701)
    ),
    to: handler,
    as: ScreenshotCapturePayload.self
  )
  expect(withPid.envelope.ok, "capture with pid should be ok")
  expectEqual(accessibility.frontmostPIDs, [Int32?(701)], "capture with pid must raise that app before capturing")

  // A capture without a pid must not raise anything.
  let withoutPid = try sendFrame(
    AgentRequest(
      id: "req_capture_no_pid",
      action: "screenshot.capture",
      params: AgentRequestParams(mode: "full", format: "webp")
    ),
    to: handler,
    as: ScreenshotCapturePayload.self
  )
  expect(withoutPid.envelope.ok, "capture without pid should be ok")
  expectEqual(accessibility.frontmostPIDs, [Int32?(701)], "capture without pid must not raise any app")
}

func verifyVisibilityAndCapturedPIDDispatch(configuration: AgentConfiguration, screenshot: CapturedImage) throws {
  let visible = AXAppPayload(pid: 701, name: "Visible", bundleId: "com.example.Visible", active: true, windowCount: 1)
  let hidden = AXAppPayload(pid: 702, name: "Hidden", bundleId: "com.example.Hidden", active: false, windowCount: 1)
  let accessibility = RecordingAccessibilityService(apps: [visible, hidden])
  let resolution = AXResolvedTarget(
    target: AXPermissionTarget(bundleID: "com.example.Visible", appName: "Visible", pid: 701),
    pid: 701,
    wasResolved: true
  )
  let resolver = RecordingAXTargetResolver(resolution: resolution, isCurrent: true)
  let discoveryDeniedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: accessibility,
    axPermissionCoordinator: AXPermissionCoordinator(
      prompter: FakePermissionPrompter(response: .notNow)
    ),
    axTargetResolver: resolver
  )
  let discoveryDenied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "ax_list_apps_default_deny", action: "ax.list-apps", params: AgentRequestParams()),
    to: discoveryDeniedHandler
  )
  expect(!discoveryDenied.ok, "ax.list-apps must require the Application Discovery Observe grant")
  expectEqual(discoveryDenied.error?.code, "app_permission_required", "Application Discovery default-deny code")

  let coordinator = AXPermissionCoordinator(rules: [
    AXAppPermissionRule(bundleID: "com.example.Visible", appName: "Visible", mode: .control),
    AXAppPermissionRule(target: GlobalPermissionCategory.applicationDiscovery.permissionTarget, mode: .observe)
  ], prompter: FakePermissionPrompter(response: .notNow))
  let handler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: accessibility,
    axPermissionCoordinator: coordinator,
    axTargetResolver: resolver
  )

  let listed: Envelope<AXAppListPayload> = try send(
    AgentRequest(id: "filtered_ax_apps", action: "ax.list-apps", params: AgentRequestParams()),
    to: handler
  )
  expect(listed.ok, "Application Discovery grant should allow ax.list-apps")
  expectEqual(
    listed.data?.apps.map(\.bundleId),
    ["com.example.Visible", "com.example.Hidden"],
    "Application Discovery should return the global process list after explicit approval"
  )

  let typed: Envelope<AXSimpleResultPayload> = try send(
    AgentRequest(id: "captured_frontmost_pid", action: "ax.type-text", params: AgentRequestParams(text: "hello")),
    to: handler
  )
  expect(typed.ok, "captured PID dispatch should succeed")
  expectEqual(accessibility.typedPIDs, [701], "synthetic input must use the authorized captured PID")
  expectEqual(resolver.frontmostFallbackRequests, [true], "untargeted synthetic input must resolve the frontmost target")

  let staleAccessibility = RecordingAccessibilityService(apps: [visible])
  let staleHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    accessibility: staleAccessibility,
    axPermissionCoordinator: AXPermissionCoordinator(
      rules: [AXAppPermissionRule(bundleID: "com.example.Visible", appName: "Visible", mode: .control)],
      prompter: FakePermissionPrompter(response: .notNow)
    ),
    axTargetResolver: RecordingAXTargetResolver(resolution: resolution, isCurrent: false)
  )
  let stale: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "stale_frontmost_pid", action: "ax.type-text", params: AgentRequestParams(text: "hello")),
    to: staleHandler
  )
  expect(!stale.ok, "stale PID must be rejected before synthetic input")
  expectEqual(stale.error?.code, "app_permission_required", "stale target error code")
  expect(staleAccessibility.typedPIDs.isEmpty, "stale PID must not receive input")
}

func verifyFunctionFinalGateAndAutomationBranches(configuration: AgentConfiguration, screenshot: CapturedImage) throws {
  let target = FunctionTarget(bundleID: "com.example.TestApp", appName: "Test App", requiresAutomation: true)

  func makeHandler(
    function: any MacOSFunction,
    state: FunctionRuntimeState,
    automation: AutomationPermissionServicing,
    coordinator: AXPermissionCoordinator,
    remoteEnabled: @escaping @Sendable () -> Bool = { true }
  ) -> AgentRequestHandler {
    AgentRequestHandler(
      configuration: configuration,
      permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
      screenshots: FakeScreenshotService(capturedImage: screenshot),
      functionRegistry: FunctionRegistry(functions: [function]),
      functionState: state,
      automationPermissions: automation,
      axPermissionCoordinator: coordinator,
      axTargetResolver: FakeAXTargetResolver(),
      remoteControlEnabled: remoteEnabled
    )
  }

  let readCounter = LockedCounter()
  let targetedRead = ProbeFunction(name: "probe.read", tier: .read, target: target, counter: readCounter)
  let unapprovedRead = makeHandler(
    function: targetedRead,
    state: FunctionRuntimeState(),
    automation: FakeAutomationPermissionService(status: .authorized),
    coordinator: AXPermissionCoordinator(
      prompter: FakePermissionPrompter(response: .notNow)
    )
  )
  let readUnapproved: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "tier_one_observation_unapproved", action: "functions.run", params: AgentRequestParams(functionName: "probe.read", args: [:])),
    to: unapprovedRead
  )
  expect(!readUnapproved.ok, "targeted Tier-1 functions must require Observe approval")
  expectEqual(readUnapproved.error?.code, "app_permission_required", "Tier-1 observation gate code")
  expectEqual(readCounter.value, 0, "unapproved Tier-1 function must not run")

  let hiddenRunning = ApplicationDescriptor(
    bundleID: "com.example.Hidden",
    appName: "Hidden Running",
    pid: 733,
    frontmost: false
  )
  let hiddenStopped = ApplicationDescriptor(
    bundleID: "com.example.Stopped",
    appName: "Hidden Stopped"
  )
  let appResolver = FakeApplicationResolver(
    running: [hiddenRunning],
    names: [
      "Hidden Running": .resolved(hiddenRunning),
      "Hidden Stopped": .resolved(hiddenStopped),
      "Missing App": .notFound,
      "Ambiguous App": .ambiguous
    ]
  )
  let appStateHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: FunctionRegistry.standard(applicationResolver: appResolver),
    functionState: FunctionRuntimeState(),
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(
      prompter: FakePermissionPrompter(response: .notNow)
    ),
    axTargetResolver: FakeAXTargetResolver()
  )
  let hiddenAppQuery: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "app_is_running_denied",
      action: "functions.run",
      params: AgentRequestParams(functionName: "app.is-running", args: ["bundleID": .string(hiddenRunning.bundleID)])
    ),
    to: appStateHandler
  )
  expect(!hiddenAppQuery.ok, "app.is-running must not disclose an unapproved bundle")
  expectEqual(hiddenAppQuery.error?.code, "app_permission_required", "app.is-running bundle default-deny code")

  let hiddenRunningName: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "app_is_running_running_name_denied",
      action: "functions.run",
      params: AgentRequestParams(functionName: "app.is-running", args: ["name": .string(hiddenRunning.appName)])
    ),
    to: appStateHandler
  )
  expect(!hiddenRunningName.ok, "running app name must be authorized before status is disclosed")
  expectEqual(hiddenRunningName.error?.code, "app_permission_required", "running app name default-deny code")

  let hiddenStoppedName: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "app_is_running_stopped_name_denied",
      action: "functions.run",
      params: AgentRequestParams(functionName: "app.is-running", args: ["name": .string(hiddenStopped.appName)])
    ),
    to: appStateHandler
  )
  expect(!hiddenStoppedName.ok, "non-running app name must be authorized before false is disclosed")
  expectEqual(hiddenStoppedName.error?.code, "app_permission_required", "non-running app name default-deny code")

  let unresolvedName: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "app_is_running_unresolved_name",
      action: "functions.run",
      params: AgentRequestParams(functionName: "app.is-running", args: ["name": .string("Missing App")])
    ),
    to: appStateHandler
  )
  expect(!unresolvedName.ok, "unresolved app names must not return an unauthorized false status")
  expectEqual(unresolvedName.error?.code, "app_not_found", "unresolved app name code")

  let ambiguousName: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "app_is_running_ambiguous_name",
      action: "functions.run",
      params: AgentRequestParams(functionName: "app.is-running", args: ["name": .string("Ambiguous App")])
    ),
    to: appStateHandler
  )
  expect(!ambiguousName.ok, "ambiguous app names must not return an unauthorized status")
  expectEqual(ambiguousName.error?.code, "app_not_found", "ambiguous app name code")

  let unknownBundlePrompter = CountingPermissionPrompter(response: .allowAlways)
  let unknownBundleHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: FunctionRegistry.standard(applicationResolver: FakeApplicationResolver()),
    functionState: FunctionRuntimeState(),
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(prompter: unknownBundlePrompter),
    axTargetResolver: FakeAXTargetResolver()
  )
  let unknownBundle: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "app_is_running_unknown_bundle",
      action: "functions.run",
      params: AgentRequestParams(functionName: "app.is-running", args: ["bundleID": .string("com.example.Invented")])
    ),
    to: unknownBundleHandler
  )
  expect(!unknownBundle.ok, "an unknown bundle must not create a permission prompt")
  expectEqual(unknownBundle.error?.code, "app_not_found", "unknown app bundle code")
  expectEqual(unknownBundlePrompter.count, 0, "unknown app bundle must not be grantable")

  let tccCounter = LockedCounter()
  let tccState = FunctionRuntimeState(enabledFunctionNames: ["probe.tcc"])
  let tccAutomation = MutatingAutomationPermissionService(initial: .notDetermined, afterRequest: .authorized)
  let tccHandler = makeHandler(
    function: ProbeFunction(name: "probe.tcc", tier: .write, target: target, counter: tccCounter),
    state: tccState,
    automation: tccAutomation,
    coordinator: AXPermissionCoordinator(rules: [AXAppPermissionRule(bundleID: target.bundleID, appName: target.appName, mode: .control)])
  )
  let tccAllowed: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "tcc_prompt_allowed", action: "functions.run", params: AgentRequestParams(functionName: "probe.tcc", args: [:])),
    to: tccHandler
  )
  expect(tccAllowed.ok, "not-determined TCC status should retry after an authorized request")
  expectEqual(tccAutomation.requestCount, 1, "not-determined TCC must request once")
  expectEqual(tccCounter.value, 1, "authorized function should run once")

  let deniedTCCCounter = LockedCounter()
  let deniedTCCHandler = makeHandler(
    function: ProbeFunction(name: "probe.tcc-denied", tier: .write, target: target, counter: deniedTCCCounter),
    state: FunctionRuntimeState(enabledFunctionNames: ["probe.tcc-denied"]),
    automation: FakeAutomationPermissionService(status: .denied),
    coordinator: AXPermissionCoordinator(rules: [AXAppPermissionRule(bundleID: target.bundleID, appName: target.appName, mode: .control)])
  )
  let deniedTCC: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "tcc_denied", action: "functions.run", params: AgentRequestParams(functionName: "probe.tcc-denied", args: [:])),
    to: deniedTCCHandler
  )
  expect(!deniedTCC.ok, "denied TCC should block function dispatch")
  expectEqual(deniedTCC.error?.code, "automation_permission_required", "TCC denied error code")
  expectEqual(deniedTCCCounter.value, 0, "TCC-denied function must not run")

  let globalCounter = LockedCounter()
  let globalState = FunctionRuntimeState(enabledFunctionNames: ["probe.global"])
  let globalFlag = LockedBoolean(true)
  let globalAutomation = MutatingAutomationPermissionService(initial: .notDetermined, afterRequest: .authorized) {
    globalFlag.value = false
  }
  let globalHandler = makeHandler(
    function: ProbeFunction(name: "probe.global", tier: .write, target: target, counter: globalCounter),
    state: globalState,
    automation: globalAutomation,
    coordinator: AXPermissionCoordinator(rules: [AXAppPermissionRule(bundleID: target.bundleID, appName: target.appName, mode: .control)]),
    remoteEnabled: { globalFlag.value }
  )
  let globalRevoked: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "global_revoked_during_tcc", action: "functions.run", params: AgentRequestParams(functionName: "probe.global", args: [:])),
    to: globalHandler
  )
  expect(!globalRevoked.ok, "global remote-control revocation must be rechecked after TCC")
  expectEqual(globalRevoked.error?.code, "invalid_request", "global revocation error code")
  expectEqual(globalCounter.value, 0, "globally revoked function must not run")

  let toggleCounter = LockedCounter()
  let toggleState = FunctionRuntimeState(enabledFunctionNames: ["probe.toggle"])
  let toggleAutomation = MutatingAutomationPermissionService(initial: .notDetermined, afterRequest: .authorized) {
    toggleState.setEnabled(false, for: "probe.toggle")
  }
  let toggleHandler = makeHandler(
    function: ProbeFunction(name: "probe.toggle", tier: .write, target: target, counter: toggleCounter),
    state: toggleState,
    automation: toggleAutomation,
    coordinator: AXPermissionCoordinator(rules: [AXAppPermissionRule(bundleID: target.bundleID, appName: target.appName, mode: .control)])
  )
  let disabledAfterPrompt: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "function_disabled_during_tcc", action: "functions.run", params: AgentRequestParams(functionName: "probe.toggle", args: [:])),
    to: toggleHandler
  )
  expect(!disabledAfterPrompt.ok, "function toggle must be rechecked after TCC")
  expectEqual(disabledAfterPrompt.error?.code, "function_disabled", "revoked function toggle error code")
  expectEqual(toggleCounter.value, 0, "disabled function must not run")

  let ruleCounter = LockedCounter()
  let ruleCoordinator = AXPermissionCoordinator(rules: [AXAppPermissionRule(bundleID: target.bundleID, appName: target.appName, mode: .control)])
  let ruleAutomation = MutatingAutomationPermissionService(initial: .notDetermined, afterRequest: .authorized) {
    ruleCoordinator.replaceRules([])
  }
  let ruleHandler = makeHandler(
    function: ProbeFunction(name: "probe.rule", tier: .write, target: target, counter: ruleCounter),
    state: FunctionRuntimeState(enabledFunctionNames: ["probe.rule"]),
    automation: ruleAutomation,
    coordinator: ruleCoordinator
  )
  let ruleRevoked: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "app_rule_revoked_during_tcc", action: "functions.run", params: AgentRequestParams(functionName: "probe.rule", args: [:])),
    to: ruleHandler
  )
  expect(!ruleRevoked.ok, "app rule changes must be rechecked after TCC")
  expectEqual(ruleRevoked.error?.code, "app_permission_required", "revoked app rule error code")
  expectEqual(ruleCounter.value, 0, "app-rule revoked function must not run")

  let templateSource = """
  tell application id "com.example.TestApp"
    return $value
  end tell
  """
  let templateResolver = StaticTemplateTargetResolver(targets: [target.bundleID.lowercased(): target])
  let templateState = FunctionRuntimeState(templateTargetResolver: templateResolver)
  let originalProposal = try templateState.submitProposal(
    name: "identity.template",
    description: "Identity regression",
    rationale: "Verifier",
    exampleScript: templateSource
  )
  let originalTemplate = try templateState.approveProposal(
    id: originalProposal.id,
    approvedSourceDigest: TemplateSourceReview.digest(for: templateSource.trimmingCharacters(in: .whitespacesAndNewlines))
  )
  let replacementAutomation = MutatingAutomationPermissionService(initial: .notDetermined, afterRequest: .authorized) {
    guard templateState.removeTemplate(id: originalTemplate.id) else { return }
    guard let replacementProposal = try? templateState.submitProposal(
      name: "identity.template",
      description: "Identity replacement",
      rationale: "Verifier",
      exampleScript: templateSource
    ) else { return }
    _ = try? templateState.approveProposal(
      id: replacementProposal.id,
      approvedSourceDigest: TemplateSourceReview.digest(for: templateSource.trimmingCharacters(in: .whitespacesAndNewlines))
    )
  }
  let templateHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: FunctionRegistry(functions: []),
    functionState: templateState,
    automationPermissions: replacementAutomation,
    axPermissionCoordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(bundleID: target.bundleID, appName: target.appName, mode: .control)
    ]),
    axTargetResolver: FakeAXTargetResolver()
  )
  let staleTemplate: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "template_replaced_during_tcc",
      action: "functions.run",
      params: AgentRequestParams(functionName: "identity.template", args: ["value": .string("safe")])
    ),
    to: templateHandler
  )
  expect(!staleTemplate.ok, "a same-name replacement must not inherit an in-flight template authorization")
  expectEqual(staleTemplate.error?.code, "function_disabled", "stale template identity error code")
  expect(templateState.executableTemplate(named: "identity.template")?.id != originalTemplate.id, "template replacement regression setup")
}

func verifyGlobalPermissionCategories(configuration: AgentConfiguration, screenshot: CapturedImage) throws {
  func makeHandler(
    functions: [any MacOSFunction],
    state: FunctionRuntimeState,
    coordinator: AXPermissionCoordinator
  ) -> AgentRequestHandler {
    AgentRequestHandler(
      configuration: configuration,
      permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
      screenshots: FakeScreenshotService(capturedImage: screenshot),
      functionRegistry: FunctionRegistry(functions: functions),
      functionState: state,
      automationPermissions: FakeAutomationPermissionService(status: .authorized),
      axPermissionCoordinator: coordinator,
      axTargetResolver: FakeAXTargetResolver()
    )
  }

  let category = GlobalPermissionCategory.clipboard
  let readCounter = LockedCounter()
  let globalRead = GlobalProbeFunction(name: "probe.global-read", tier: .read, category: category, counter: readCounter)
  let unapprovedRead = makeHandler(
    functions: [globalRead],
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .notNow))
  )
  let deniedRead: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "global_read_default_deny", action: "functions.run", params: AgentRequestParams(functionName: globalRead.name, args: [:])),
    to: unapprovedRead
  )
  expect(!deniedRead.ok, "unbound read functions must require an explicit global Observe grant")
  expectEqual(deniedRead.error?.code, "app_permission_required", "global Observe default-deny code")
  expectEqual(readCounter.value, 0, "unapproved global read must not execute")

  let allowedRead = makeHandler(
    functions: [globalRead],
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: category.permissionTarget, mode: .observe)
    ])
  )
  let allowedReadResult: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "global_read_observe", action: "functions.run", params: AgentRequestParams(functionName: globalRead.name, args: [:])),
    to: allowedRead
  )
  expect(allowedReadResult.ok, "Observe should allow a global read function")
  expectEqual(readCounter.value, 1, "approved global read should execute exactly once")

  let writeCounter = LockedCounter()
  let globalWrite = GlobalProbeFunction(name: "probe.global-write", tier: .write, category: category, counter: writeCounter)
  let writeState = FunctionRuntimeState(enabledFunctionNames: [globalWrite.name])
  let observeOnlyWrite = makeHandler(
    functions: [globalWrite],
    state: writeState,
    coordinator: AXPermissionCoordinator(
      rules: [AXAppPermissionRule(target: category.permissionTarget, mode: .observe)],
      prompter: FakePermissionPrompter(response: .notNow)
    )
  )
  let blockedWrite: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "global_write_observe_only", action: "functions.run", params: AgentRequestParams(functionName: globalWrite.name, args: [:])),
    to: observeOnlyWrite
  )
  expect(!blockedWrite.ok, "Observe must not permit a global write function")
  expectEqual(blockedWrite.error?.code, "app_permission_required", "global Control upgrade code")
  expectEqual(writeCounter.value, 0, "Observe-only global grant must not run writes")

  let allowedWrite = makeHandler(
    functions: [globalWrite],
    state: writeState,
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: category.permissionTarget, mode: .control)
    ])
  )
  let allowedWriteResult: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "global_write_control", action: "functions.run", params: AgentRequestParams(functionName: globalWrite.name, args: [:])),
    to: allowedWrite
  )
  expect(allowedWriteResult.ok, "Control should allow a global write function")
  expectEqual(writeCounter.value, 1, "approved global write should execute exactly once")

  let unmappedCounter = LockedCounter()
  let unmapped = UnmappedProbeFunction(counter: unmappedCounter)
  let unmappedHandler = makeHandler(
    functions: [unmapped],
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: category.permissionTarget, mode: .control)
    ])
  )
  let unmappedResult: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "unmapped_function", action: "functions.run", params: AgentRequestParams(functionName: unmapped.name, args: [:])),
    to: unmappedHandler
  )
  expect(!unmappedResult.ok, "functions without a permission target must fail closed")
  expectEqual(unmappedResult.error?.code, "function_failed", "unmapped function gate code")
  expectEqual(unmappedCounter.value, 0, "unmapped function must not execute")

  let registry = FunctionRegistry.standard()
  let catalogState = FunctionRuntimeState()
  let mappings: [(String, [String: JSONValue], GlobalPermissionCategory)] = [
    ("app.list", [:], .applicationDiscovery),
    ("menubar.list", [:], .menuBarExtras),
    ("system.get-volume", [:], .systemAudio),
    ("system.get-clipboard", [:], .clipboard),
    ("system.get-battery", [:], .power),
    ("system.get-wifi-name", [:], .network),
    ("system.set-volume", ["volume": .number(50)], .systemAudio),
    ("system.mute", ["muted": .bool(false)], .systemAudio),
    ("system.set-clipboard", ["text": .string("test")], .clipboard),
    ("system.notify", ["message": .string("test")], .notifications),
    ("dialog.ask-user", ["message": .string("test")], .dialogs),
    ("display.info", [:], .display)
  ]
  for (name, args, expectedCategory) in mappings {
    guard let function = registry.function(named: name, state: catalogState) else {
      throw NSError(domain: "ProtocolVerifier", code: 11, userInfo: [NSLocalizedDescriptionKey: "Missing standard function \(name)"])
    }
    let plan = try function.makeExecutionPlan(args: args)
    expectEqual(plan.permissionTarget?.kind, .category, "\(name) must declare a global category")
    expectEqual(plan.permissionTarget?.identifier, expectedCategory.rawValue, "\(name) global category")
  }
  expectEqual(
    Set(mappings.map { $0.2 }),
    Set(GlobalPermissionCategory.allCases),
    "every global permission category must be represented by a curated function"
  )

  // Keep the always-visible global-capability picker and the executable
  // catalog in lockstep. A new built-in must be classified as either a global
  // category, a static app target, or an intentionally dynamic app target.
  let expectedGlobalCategories = Dictionary(uniqueKeysWithValues: mappings.map { ($0.0, $0.2) })
  let expectedStaticApplicationTargets: [String: String] = [
    "finder.get-selection": "com.apple.finder",
    "finder.get-front-path": "com.apple.finder",
    "finder.reveal": "com.apple.finder"
  ]
  let expectedDynamicAppFunctions: Set<String> = [
    "app.is-running",
    "media.now-playing",
    "browser.get-url",
    "browser.get-title",
    "browser.list-tabs",
    "app.launch",
    "app.activate",
    "app.quit",
    "menubar.open",
    "menubar.click",
    "menu.list",
    "menu.click",
    "window.list",
    "window.frame",
    "window.close",
    "window.minimize",
    "window.zoom",
    "window.raise",
    "media.play-pause",
    "media.next",
    "media.previous",
    "browser.open-url",
    "browser.run-javascript"
  ]
  let expectedStandardFunctionNames = Set(expectedGlobalCategories.keys)
    .union(expectedStaticApplicationTargets.keys)
    .union(expectedDynamicAppFunctions)
  let catalog = registry.catalog(
    state: catalogState,
    automation: FakeAutomationPermissionService(status: .authorized)
  )
  expectEqual(
    Set(catalog.functions.map(\.name)),
    expectedStandardFunctionNames,
    "every standard built-in must have an explicit permission classification"
  )
  for entry in catalog.functions {
    if let category = expectedGlobalCategories[entry.name] {
      expectEqual(entry.permissionTarget?.kind, .category, "\(entry.name) catalog target kind")
      expectEqual(entry.permissionTarget?.identifier, category.rawValue, "\(entry.name) catalog category")
    } else if let bundleID = expectedStaticApplicationTargets[entry.name] {
      expectEqual(entry.permissionTarget?.kind, .application, "\(entry.name) catalog target kind")
      expectEqual(entry.permissionTarget?.bundleID, bundleID, "\(entry.name) static app bundle")
    } else {
      expect(expectedDynamicAppFunctions.contains(entry.name), "\(entry.name) must be an expected dynamic app function")
      expectEqual(entry.permissionTarget, nil, "\(entry.name) must not advertise a misleading static target")
    }
  }
}

func verifyMenuBarExtraFunctions(configuration: AgentConfiguration, screenshot: CapturedImage) throws {
  print("Verifier: menu bar extra functions")
  let statusApp = ApplicationDescriptor(
    bundleID: "com.example.StatusOwner",
    appName: "Status Owner",
    pid: 8123,
    frontmost: false
  )
  let okDiskApp = ApplicationDescriptor(
    bundleID: "com.example.OKDiskDev",
    appName: "OKDisk Dev",
    pid: 8124,
    frontmost: false
  )

  let matchingCandidates = [
    MenuBarExtraStatusItemCandidate(
      title: "OKDisk",
      description: "OKDisk primary status",
      label: nil,
      identifier: "okdisk.primary"
    ),
    MenuBarExtraStatusItemCandidate(
      title: nil,
      description: "OKDisk Idle",
      label: "OKDisk status",
      identifier: "okdisk.menu.icon"
    )
  ]
  expectEqual(
    MenuBarExtraStatusItemMatcher.matchingIndexes(query: "okdisk", candidates: matchingCandidates),
    [0],
    "status-item matching must prefer an exact title over a partial description"
  )
  expectEqual(
    MenuBarExtraStatusItemMatcher.matchingIndexes(query: "OKDisk Idle", candidates: matchingCandidates),
    [1],
    "status-item matching must include AXDescription"
  )
  expectEqual(
    MenuBarExtraStatusItemMatcher.matchingIndexes(query: "okdisk.menu.icon", candidates: matchingCandidates),
    [1],
    "status-item matching must include AXIdentifier"
  )
  expectEqual(
    MenuBarExtraStatusItemMatcher.matchingIndexes(query: "Disk", candidates: matchingCandidates),
    [0, 1],
    "partial status-item matches must retain ambiguity"
  )
  let visibleCandidates = MenuBarExtraStatusItemMatcher.visibleCandidatesDescription(matchingCandidates)
  expect(visibleCandidates.contains("description 'OKDisk Idle'"), "status-item errors must list visible descriptions")
  expect(visibleCandidates.contains("identifier 'okdisk.menu.icon'"), "status-item errors must list visible identifiers")
  expectEqual(
    resolveUniqueRunningApplication(named: "okdisk", in: [statusApp, okDiskApp]),
    .resolved(okDiskApp),
    "running app resolution must allow a unique partial localized name"
  )
  let duplicateBundleFirst = ApplicationDescriptor(
    bundleID: "com.example.DuplicateStatus",
    appName: "Duplicate Status",
    pid: 8130
  )
  let duplicateBundleSecond = ApplicationDescriptor(
    bundleID: "com.example.DuplicateStatus",
    appName: "Duplicate Status",
    pid: 8131
  )
  expectEqual(
    resolveUniqueRunningApplication(
      named: "duplicate",
      in: [duplicateBundleFirst, duplicateBundleSecond]
    ),
    .resolved(duplicateBundleFirst),
    "running app resolution must deduplicate multiple processes with one bundle ID"
  )
  expectEqual(
    resolveUniqueRunningApplication(
      named: "status",
      in: [
        ApplicationDescriptor(bundleID: "com.example.StatusOne", appName: "Status One", pid: 8130),
        ApplicationDescriptor(bundleID: "com.example.StatusTwo", appName: "Status Two", pid: 8131)
      ]
    ),
    .ambiguous,
    "partial running app resolution must reject ambiguous matches"
  )

  let resolver = FakeApplicationResolver(
    running: [statusApp, okDiskApp],
    names: ["Status Owner": .resolved(statusApp)]
  )
  let extras = RecordingMenuBarExtrasService()
  let registry = FunctionRegistry.standard(applicationResolver: resolver, menuBarExtras: extras)
  let appObserveRule = AXAppPermissionRule(
    bundleID: statusApp.bundleID,
    appName: statusApp.appName,
    mode: .observe
  )
  let appControlRule = AXAppPermissionRule(
    bundleID: statusApp.bundleID,
    appName: statusApp.appName,
    mode: .control
  )
  let okDiskObserveRule = AXAppPermissionRule(
    bundleID: okDiskApp.bundleID,
    appName: okDiskApp.appName,
    mode: .observe
  )
  let okDiskControlRule = AXAppPermissionRule(
    bundleID: okDiskApp.bundleID,
    appName: okDiskApp.appName,
    mode: .control
  )

  func makeHandler(
    state: FunctionRuntimeState,
    coordinator: AXPermissionCoordinator,
    accessibility: PermissionState = .granted
  ) -> AgentRequestHandler {
    AgentRequestHandler(
      configuration: configuration,
      permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: accessibility)),
      screenshots: FakeScreenshotService(capturedImage: screenshot),
      functionRegistry: registry,
      functionState: state,
      automationPermissions: FakeAutomationPermissionService(status: .authorized),
      axPermissionCoordinator: coordinator,
      axTargetResolver: FakeAXTargetResolver()
    )
  }

  let catalogHandler = makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator())
  let catalog: Envelope<FunctionListPayload> = try send(
    AgentRequest(id: "menubar_catalog", action: "functions.list", params: AgentRequestParams()),
    to: catalogHandler
  )
  guard let entries = catalog.data?.functions,
        let listEntry = entries.first(where: { $0.name == "menubar.list" }),
        let openEntry = entries.first(where: { $0.name == "menubar.open" }),
        let clickEntry = entries.first(where: { $0.name == "menubar.click" }) else {
    throw NSError(domain: "ProtocolVerifier", code: 20, userInfo: [NSLocalizedDescriptionKey: "Menu bar functions were not registered"])
  }
  expectEqual(listEntry.tier, .read, "menubar.list should be Tier 1")
  expectEqual(listEntry.permissionTarget?.identifier, GlobalPermissionCategory.menuBarExtras.rawValue, "menubar.list global catalog target")
  expectEqual(openEntry.tier, .write, "menubar.open should be Tier 2")
  expectEqual(clickEntry.tier, .write, "menubar.click should be Tier 2")
  expectEqual(openEntry.args.map(\.name), ["appName", "title"], "menubar.open argument schema")
  expectEqual(openEntry.args.first(where: { $0.name == "title" })?.required, false, "menubar.open title must be optional")
  expectEqual(clickEntry.args.map(\.name), ["appName", "title", "menuPath"], "menubar.click argument schema")
  expectEqual(clickEntry.args.last?.type, .stringArray, "menubar.click menuPath argument type")
  expectEqual(clickEntry.args.last?.minItems, 1, "menubar.click menuPath minimum")
  expectEqual(clickEntry.args.last?.maxItems, 32, "menubar.click menuPath maximum")

  let accessibilityDeniedHandler = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: GlobalPermissionCategory.menuBarExtras.permissionTarget, mode: .control)
    ]),
    accessibility: .denied
  )
  let accessibilityDenied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "menubar_list_accessibility_denied", action: "functions.run", params: AgentRequestParams(functionName: "menubar.list", args: [:])),
    to: accessibilityDeniedHandler
  )
  expect(!accessibilityDenied.ok, "menubar.list must require Accessibility TCC before dispatch")
  expectEqual(accessibilityDenied.error?.code, "permission_denied", "menubar.list Accessibility denial code")
  expectEqual(extras.listTargets.count, 0, "Accessibility-denied list must not reach AX service")

  let deniedGlobal = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .notNow))
  )
  let unfilteredDenied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "menubar_list_global_denied", action: "functions.run", params: AgentRequestParams(functionName: "menubar.list", args: [:])),
    to: deniedGlobal
  )
  expect(!unfilteredDenied.ok, "unfiltered menubar.list should require global Observe")
  expectEqual(unfilteredDenied.error?.code, "app_permission_required", "unfiltered list permission code")
  expectEqual(extras.listTargets.count, 0, "denied unfiltered list must not reach AX service")

  let globalListHandler = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: GlobalPermissionCategory.menuBarExtras.permissionTarget, mode: .observe)
    ])
  )
  let unfilteredList: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "menubar_list_global", action: "functions.run", params: AgentRequestParams(functionName: "menubar.list", args: [:])),
    to: globalListHandler
  )
  expect(unfilteredList.ok, "global-allowed menubar.list should run")
  expectEqual(extras.listTargets.count, 1, "unfiltered list should call AX service once")
  expectEqual(extras.listTargets[0], nil, "unfiltered list should not bind one owner app")
  guard let unfilteredValue = unfilteredList.data?.result.value,
        case .object(let unfilteredObject) = unfilteredValue,
        case .array(let unfilteredItems)? = unfilteredObject["items"],
        case .object(let firstItem)? = unfilteredItems.first else {
    throw NSError(domain: "ProtocolVerifier", code: 21, userInfo: [NSLocalizedDescriptionKey: "Unexpected menubar.list result"])
  }
  expectEqual(firstItem["appName"], .string(statusApp.appName), "menubar.list owner app result")
  expectEqual(firstItem["identifier"], .string("com.example.status-owner.vpn"), "menubar.list identifier result")

  let filteredDenied = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: GlobalPermissionCategory.menuBarExtras.permissionTarget, mode: .control)
    ], prompter: FakePermissionPrompter(response: .notNow))
  )
  let filteredWithoutAppGrant: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menubar_list_filtered_denied",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.list", args: ["appName": .string("Status Owner")])
    ),
    to: filteredDenied
  )
  expect(!filteredWithoutAppGrant.ok, "filtered menubar.list must require the owner's Observe grant")
  expectEqual(filteredWithoutAppGrant.error?.code, "app_permission_required", "filtered list permission code")
  expectEqual(extras.listTargets.count, 1, "denied filtered list must not reach AX service")

  let filteredListHandler = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [appObserveRule])
  )
  let filteredList: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_list_filtered",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.list", args: ["appName": .string("  Status Owner  ")])
    ),
    to: filteredListHandler
  )
  expect(filteredList.ok, "filtered menubar.list should accept an authorized owner app")
  expectEqual(extras.listTargets.count, 2, "filtered list should call AX service")
  expectEqual(extras.listTargets[1]?.pid, statusApp.pid, "filtered list must dispatch the re-resolved owner PID")
  expectEqual(extras.listTargets[1]?.bundleID, statusApp.bundleID, "filtered list must dispatch the authorized bundle")

  let partialAppNameListHandler = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [okDiskObserveRule])
  )
  let partialAppNameList: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_list_partial_app_name",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.list", args: ["appName": .string("  okdisk  ")])
    ),
    to: partialAppNameListHandler
  )
  expect(partialAppNameList.ok, "menubar.list should resolve a unique partial running app name")
  expectEqual(extras.listTargets.count, 3, "partial app-name list should call AX service")
  expectEqual(extras.listTargets[2]?.bundleID, okDiskApp.bundleID, "partial app-name list must target OKDisk Dev")
  guard let partialAppNameValue = partialAppNameList.data?.result.value,
        case .object(let partialAppNameObject) = partialAppNameValue,
        case .array(let partialAppNameItems)? = partialAppNameObject["items"],
        case .object(let partialAppNameItem)? = partialAppNameItems.first else {
    throw NSError(domain: "ProtocolVerifier", code: 24, userInfo: [NSLocalizedDescriptionKey: "Unexpected partial menubar.list result"])
  }
  expectEqual(partialAppNameItem["description"], .string("OKDisk Idle"), "menubar.list must expose the status-item description")
  expectEqual(partialAppNameItem["identifier"], .string("okdisk.menu.icon"), "menubar.list must expose the status-item identifier")

  let ambiguousOwnerOne = ApplicationDescriptor(
    bundleID: "com.example.OKDiskAlpha",
    appName: "OKDisk Alpha",
    pid: 8140
  )
  let ambiguousOwnerTwo = ApplicationDescriptor(
    bundleID: "com.example.OKDiskBeta",
    appName: "OKDisk Beta",
    pid: 8141
  )
  let ambiguityExtras = RecordingMenuBarExtrasService()
  let ambiguityRegistry = FunctionRegistry.standard(
    applicationResolver: FakeApplicationResolver(running: [ambiguousOwnerOne, ambiguousOwnerTwo]),
    menuBarExtras: ambiguityExtras
  )
  let ambiguityHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: ambiguityRegistry,
    functionState: FunctionRuntimeState(),
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(),
    axTargetResolver: FakeAXTargetResolver()
  )
  let ambiguousOwner: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menubar_list_ambiguous_owner",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.list", args: ["appName": .string("OKDisk")])
    ),
    to: ambiguityHandler
  )
  expect(!ambiguousOwner.ok, "menubar.list must reject an ambiguous partial owner name")
  expectEqual(ambiguousOwner.error?.code, "invalid_request", "ambiguous menu-bar owner error code")
  expectEqual(ambiguityExtras.listTargets.count, 0, "ambiguous menu-bar owner must not reach the AX service")

  let disabledOpenHandler = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [appControlRule])
  )
  let disabledOpen: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menubar_open_disabled",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.open", args: ["appName": .string("Status Owner"), "title": .string("VPN")])
    ),
    to: disabledOpenHandler
  )
  expect(!disabledOpen.ok, "menubar.open should be disabled by default")
  expectEqual(disabledOpen.error?.code, "function_disabled", "menubar.open default-enable code")

  let observeOnlyOpenHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["menubar.open"]),
    coordinator: AXPermissionCoordinator(rules: [appObserveRule], prompter: FakePermissionPrompter(response: .notNow))
  )
  let observeOnlyOpen: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menubar_open_observe_only",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.open", args: ["appName": .string("Status Owner"), "title": .string("VPN")])
    ),
    to: observeOnlyOpenHandler
  )
  expect(!observeOnlyOpen.ok, "Observe must not permit menubar.open")
  expectEqual(observeOnlyOpen.error?.code, "app_permission_required", "menubar.open Control permission code")
  expectEqual(extras.openedTitles.count, 0, "blocked menubar.open must not reach AX service")

  let openHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["menubar.open"]),
    coordinator: AXPermissionCoordinator(rules: [appControlRule])
  )
  let openedByAppName: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_open_by_app_name",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.open", args: ["appName": .string(" Status Owner ")])
    ),
    to: openHandler
  )
  expect(openedByAppName.ok, "menubar.open without title should open the app's single status item")
  expectEqual(extras.openedTitles.last, "VPN", "menubar.open by appName alone should open the only status item")
  expectEqual(extras.openedTargets.last?.pid, statusApp.pid, "menubar.open by appName alone must target the owner PID")

  let opened: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_open",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.open", args: ["appName": .string(" Status Owner "), "title": .string(" VPN ")])
    ),
    to: openHandler
  )
  expect(opened.ok, "authorized menubar.open should run")
  expectEqual(extras.openedTitles.last, "VPN", "menubar.open should normalize the status-item match")
  expectEqual(extras.openedTargets.last?.pid, statusApp.pid, "menubar.open must use the re-resolved owner PID")
  guard let openedValue = opened.data?.result.value,
        case .object(let openedObject) = openedValue,
        case .array(let menuItems)? = openedObject["menuItems"] else {
    throw NSError(domain: "ProtocolVerifier", code: 22, userInfo: [NSLocalizedDescriptionKey: "Unexpected menubar.open result"])
  }
  expectEqual(menuItems.count, 2, "menubar.open should return top-level popup items")

  let descriptionOpenHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["menubar.open"]),
    coordinator: AXPermissionCoordinator(rules: [okDiskControlRule])
  )
  let openedByDescription: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_open_by_description",
      action: "functions.run",
      params: AgentRequestParams(
        functionName: "menubar.open",
        args: ["appName": .string("OKDisk"), "title": .string("OKDisk Idle")]
      )
    ),
    to: descriptionOpenHandler
  )
  expect(openedByDescription.ok, "menubar.open should match a status item by AXDescription")
  expectEqual(extras.openedTargets.last?.bundleID, okDiskApp.bundleID, "description match must resolve the partial OKDisk app name")
  expectEqual(extras.openedTitles.last, "OKDisk Idle", "menubar.open should pass the description status-item match")

  for (title, expectedCode) in [("Disabled", "action_failed"), ("Missing", "element_not_found"), ("Ambiguous", "invalid_request")] {
    let failure: Envelope<EmptyPayload> = try send(
      AgentRequest(
        id: "menubar_open_\(title.lowercased())",
        action: "functions.run",
        params: AgentRequestParams(functionName: "menubar.open", args: ["appName": .string("Status Owner"), "title": .string(title)])
      ),
      to: openHandler
    )
    expect(!failure.ok, "menubar.open \(title) mock failure should propagate")
    expectEqual(failure.error?.code, expectedCode, "menubar.open \(title) error code")
  }

  let clickHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["menubar.click"]),
    coordinator: AXPermissionCoordinator(rules: [appControlRule])
  )
  let clicked: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_click",
      action: "functions.run",
      params: AgentRequestParams(
        functionName: "menubar.click",
        args: [
          "appName": .string("Status Owner"),
          "title": .string("VPN"),
          "menuPath": .array([.string(" Settings… "), .string(" General ")])
        ]
      )
    ),
    to: clickHandler
  )
  expect(clicked.ok, "authorized menubar.click should run")
  expectEqual(extras.clickedTitles.last, "VPN", "menubar.click status-item title")
  expectEqual(extras.clickedPaths.last, ["Settings…", "General"], "menubar.click should normalize menuPath")
  guard let clickedValue = clicked.data?.result.value,
        case .object(let clickedObject) = clickedValue,
        case .array(let clickedPath)? = clickedObject["path"] else {
    throw NSError(domain: "ProtocolVerifier", code: 23, userInfo: [NSLocalizedDescriptionKey: "Unexpected menubar.click result"])
  }
  expectEqual(clickedPath, [.string("Settings…"), .string("General")], "menubar.click result path")

  let identifierClickHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["menubar.click"]),
    coordinator: AXPermissionCoordinator(rules: [okDiskControlRule])
  )
  let clickedByIdentifier: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menubar_click_by_identifier",
      action: "functions.run",
      params: AgentRequestParams(
        functionName: "menubar.click",
        args: [
          "appName": .string("OKDisk"),
          "title": .string("okdisk.menu.icon"),
          "menuPath": .array([.string(" Quit ")])
        ]
      )
    ),
    to: identifierClickHandler
  )
  expect(clickedByIdentifier.ok, "menubar.click should match a status item by AXIdentifier")
  expectEqual(extras.clickedTitles.last, "okdisk.menu.icon", "menubar.click should pass the identifier status-item match")
  expectEqual(extras.clickedPaths.last, ["Quit"], "identifier match should retain menu-path normalization")

  let invalidClickRequests: [(String, [String: JSONValue])] = [
    ("missing_title", ["appName": .string("Status Owner"), "menuPath": .array([.string("Settings…")])]),
    ("empty_path", ["appName": .string("Status Owner"), "title": .string("VPN"), "menuPath": .array([])]),
    ("empty_segment", ["appName": .string("Status Owner"), "title": .string("VPN"), "menuPath": .array([.string(" ")])]),
    ("wrong_path_type", ["appName": .string("Status Owner"), "title": .string("VPN"), "menuPath": .string("Settings…")])
  ]
  for (suffix, args) in invalidClickRequests {
    let invalid: Envelope<EmptyPayload> = try send(
      AgentRequest(id: "menubar_click_\(suffix)", action: "functions.run", params: AgentRequestParams(functionName: "menubar.click", args: args)),
      to: clickHandler
    )
    expect(!invalid.ok, "menubar.click \(suffix) should fail validation")
    expectEqual(invalid.error?.code, "invalid_args", "menubar.click \(suffix) validation code")
  }

  let responsiveProbe = AXMenuBarExtraAppTarget(
    pid: statusApp.pid ?? 8123,
    appName: statusApp.appName,
    bundleID: statusApp.bundleID
  )
  let slowProbe = AXMenuBarExtraAppTarget(
    pid: 8132,
    appName: "Slow Status Owner",
    bundleID: "com.example.SlowStatusOwner"
  )
  let prohibitedProbe = AXMenuBarExtraAppTarget(
    pid: 8133,
    appName: "Prohibited Background Process",
    bundleID: "com.example.ProhibitedBackground"
  )
  let boundedListExtras = RecordingMenuBarExtrasService(unfilteredProbes: [
    .init(target: responsiveProbe),
    .init(target: slowProbe, shouldFail: true),
    .init(target: prohibitedProbe, hasUI: false)
  ])
  let boundedListRegistry = FunctionRegistry.standard(
    applicationResolver: resolver,
    menuBarExtras: boundedListExtras
  )
  let boundedListHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: boundedListRegistry,
    functionState: FunctionRuntimeState(),
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: GlobalPermissionCategory.menuBarExtras.permissionTarget, mode: .observe)
    ]),
    axTargetResolver: FakeAXTargetResolver()
  )
  let boundedList: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "menubar_list_skip_slow", action: "functions.run", params: AgentRequestParams(functionName: "menubar.list", args: [:])),
    to: boundedListHandler
  )
  expect(boundedList.ok, "unfiltered menubar.list should keep successful apps when one probe errors")
  guard let boundedListValue = boundedList.data?.result.value,
        case .object(let boundedListObject) = boundedListValue,
        case .array(let boundedListItems)? = boundedListObject["items"] else {
    throw NSError(domain: "ProtocolVerifier", code: 25, userInfo: [NSLocalizedDescriptionKey: "Unexpected bounded menubar.list result"])
  }
  expectEqual(boundedListItems.count, 1, "a slow/erroring menu-bar owner must be skipped")
  expectEqual(
    boundedListExtras.unfilteredProbedTargets.map(\.bundleID),
    [responsiveProbe.bundleID, slowProbe.bundleID],
    "unfiltered listing must not probe processes that cannot have UI"
  )
  expectEqual(
    boundedListExtras.skippedUnfilteredTargets.map(\.bundleID),
    [slowProbe.bundleID],
    "unfiltered listing must skip an app whose bounded AX probe errors"
  )

  let stopped = ApplicationDescriptor(bundleID: "com.example.StoppedStatus", appName: "Stopped Status")
  let stoppedPrompter = CountingPermissionPrompter(response: .allowAlways)
  let stoppedRegistry = FunctionRegistry.standard(
    applicationResolver: FakeApplicationResolver(installed: [stopped], names: ["Stopped Status": .resolved(stopped)]),
    menuBarExtras: extras
  )
  let stoppedHandler = AgentRequestHandler(
    configuration: configuration,
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .granted)),
    screenshots: FakeScreenshotService(capturedImage: screenshot),
    functionRegistry: stoppedRegistry,
    functionState: FunctionRuntimeState(),
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(prompter: stoppedPrompter),
    axTargetResolver: FakeAXTargetResolver()
  )
  let stoppedResult: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menubar_list_stopped_app",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menubar.list", args: ["appName": .string("Stopped Status")])
    ),
    to: stoppedHandler
  )
  expect(!stoppedResult.ok, "menubar.list must reject a non-running filtered app")
  expectEqual(stoppedResult.error?.code, "app_not_found", "non-running menu bar owner error code")
  expectEqual(stoppedPrompter.count, 0, "non-running menu bar owner must not prompt for access")
}

func verifyWindowAndMenuFunctions(configuration: AgentConfiguration, screenshot: CapturedImage) throws {
  print("Verifier: window and menu functions")
  let targetApp = ApplicationDescriptor(
    bundleID: "com.example.TargetApp",
    appName: "Target App",
    pid: 8200,
    frontmost: false
  )
  let resolver = FakeApplicationResolver(running: [targetApp])
  let menus = RecordingMenuService()
  let windows = RecordingWindowService()
  let registry = FunctionRegistry.standard(
    applicationResolver: resolver,
    menuBarExtras: RecordingMenuBarExtrasService(),
    appMenus: menus,
    windows: windows
  )
  let observeRule = AXAppPermissionRule(bundleID: targetApp.bundleID, appName: targetApp.appName, mode: .observe)
  let controlRule = AXAppPermissionRule(bundleID: targetApp.bundleID, appName: targetApp.appName, mode: .control)

  func makeHandler(
    state: FunctionRuntimeState,
    coordinator: AXPermissionCoordinator,
    accessibility: PermissionState = .granted
  ) -> AgentRequestHandler {
    AgentRequestHandler(
      configuration: configuration,
      permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: accessibility)),
      screenshots: FakeScreenshotService(capturedImage: screenshot),
      functionRegistry: registry,
      functionState: state,
      automationPermissions: FakeAutomationPermissionService(status: .authorized),
      axPermissionCoordinator: coordinator,
      axTargetResolver: FakeAXTargetResolver()
    )
  }

  // Catalog classification: lists are reads, mutations are writes.
  let catalogHandler = makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator())
  let catalog: Envelope<FunctionListPayload> = try send(
    AgentRequest(id: "window_menu_catalog", action: "functions.list", params: AgentRequestParams()),
    to: catalogHandler
  )
  guard let entries = catalog.data?.functions else {
    throw NSError(domain: "ProtocolVerifier", code: 30, userInfo: [NSLocalizedDescriptionKey: "Catalog missing"])
  }
  func entry(_ name: String) throws -> FunctionCatalogEntry {
    guard let entry = entries.first(where: { $0.name == name }) else {
      throw NSError(domain: "ProtocolVerifier", code: 31, userInfo: [NSLocalizedDescriptionKey: "Missing function \(name)"])
    }
    return entry
  }
  expectEqual(try entry("menu.list").tier, .read, "menu.list should be Tier 1")
  expectEqual(try entry("menu.click").tier, .write, "menu.click should be Tier 2")
  expectEqual(try entry("window.list").tier, .read, "window.list should be Tier 1")
  expectEqual(try entry("window.frame").tier, .read, "window.frame should be Tier 1")
  expectEqual(try entry("window.frame").permissionTarget, nil, "window.frame must be a dynamic app function")
  expectEqual(try entry("window.frame").args.map(\.name), ["appName", "title"], "window.frame argument schema")
  expectEqual(try entry("window.frame").args.first(where: { $0.name == "title" })?.required, false, "window.frame title must be optional")
  expectEqual(try entry("display.info").tier, .read, "display.info should be Tier 1")
  expectEqual(try entry("display.info").permissionTarget?.identifier, GlobalPermissionCategory.display.rawValue, "display.info global category")
  for name in ["window.close", "window.minimize", "window.zoom", "window.raise"] {
    expectEqual(try entry(name).tier, .write, "\(name) should be Tier 2")
    expectEqual(try entry(name).permissionTarget, nil, "\(name) must be a dynamic app function")
  }
  expectEqual(try entry("menu.click").args.map(\.name), ["appName", "title", "path", "menu"], "menu.click argument schema")
  expectEqual(try entry("window.close").args.map(\.name), ["appName", "title"], "window.close argument schema")
  expectEqual(try entry("window.close").args.first(where: { $0.name == "title" })?.required, false, "window.close title must be optional")

  // menu.list resolves the running app and requires Observe.
  let menuListDenied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "menu_list_denied", action: "functions.run", params: AgentRequestParams(functionName: "menu.list", args: ["appName": .string("Target App")])),
    to: makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .notNow)))
  )
  expect(!menuListDenied.ok, "menu.list should require Observe")
  expectEqual(menuListDenied.error?.code, "app_permission_required", "menu.list permission code")

  let menuListHandler = makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(rules: [observeRule]))
  let menuList: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "menu_list", action: "functions.run", params: AgentRequestParams(functionName: "menu.list", args: ["appName": .string("  target  ")])),
    to: menuListHandler
  )
  expect(menuList.ok, "authorized menu.list should run")
  expectEqual(menus.listAppNames.last ?? nil, "Target App", "menu.list must dispatch the resolved app name")
  guard let menuListValue = menuList.data?.result.value,
        case .object(let menuListObject) = menuListValue,
        case .array(let menuItems)? = menuListObject["items"],
        case .object(let firstMenu)? = menuItems.first else {
    throw NSError(domain: "ProtocolVerifier", code: 32, userInfo: [NSLocalizedDescriptionKey: "Unexpected menu.list result"])
  }
  expectEqual(firstMenu["title"], .string("File"), "menu.list item title")
  expectEqual(firstMenu["hasSubmenu"], .bool(true), "menu.list item hasSubmenu")

  // menu.click is disabled by default and requires Control.
  let menuClickDisabled: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menu_click_disabled",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menu.click", args: ["appName": .string("Target App"), "path": .array([.string("File")])])
    ),
    to: makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(rules: [controlRule]))
  )
  expect(!menuClickDisabled.ok, "menu.click should be disabled by default")
  expectEqual(menuClickDisabled.error?.code, "function_disabled", "menu.click default-enable code")

  let menuClickHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["menu.click"]),
    coordinator: AXPermissionCoordinator(rules: [controlRule])
  )

  let menuClickObserveOnly: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "menu_click_observe_only",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menu.click", args: ["appName": .string("Target App"), "path": .array([.string("File")])])
    ),
    to: makeHandler(
      state: FunctionRuntimeState(enabledFunctionNames: ["menu.click"]),
      coordinator: AXPermissionCoordinator(rules: [observeRule], prompter: FakePermissionPrompter(response: .notNow))
    )
  )
  expect(!menuClickObserveOnly.ok, "Observe must not permit menu.click")
  expectEqual(menuClickObserveOnly.error?.code, "app_permission_required", "menu.click Control permission code")

  let clickedByPath: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menu_click_path",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menu.click", args: ["appName": .string("Target App"), "path": .array([.string(" View "), .string(" Enter Full Screen ")])])
    ),
    to: menuClickHandler
  )
  expect(clickedByPath.ok, "authorized menu.click should run")
  expectEqual(menus.clickPaths.last, ["View", "Enter Full Screen"], "menu.click should normalize an explicit path")

  let clickedByTitlePath: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menu_click_title_path",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menu.click", args: ["appName": .string("Target App"), "title": .string("View > Enter Full Screen")])
    ),
    to: menuClickHandler
  )
  expect(clickedByTitlePath.ok, "menu.click should accept a title path")
  expectEqual(menus.clickPaths.last, ["View", "Enter Full Screen"], "menu.click should split a title path on >")

  let clickedByMenuTitle: Envelope<FunctionRunPayload> = try send(
    AgentRequest(
      id: "menu_click_menu_title",
      action: "functions.run",
      params: AgentRequestParams(functionName: "menu.click", args: ["appName": .string("Target App"), "menu": .string("File"), "title": .string("New")])
    ),
    to: menuClickHandler
  )
  expect(clickedByMenuTitle.ok, "menu.click should accept menu + title")
  expectEqual(menus.clickPaths.last, ["File", "New"], "menu.click should combine menu and title into a path")

  let invalidMenuClicks: [(String, [String: JSONValue])] = [
    ("missing_target", ["appName": .string("Target App")]),
    ("empty_path", ["appName": .string("Target App"), "path": .array([])]),
    ("wrong_path_type", ["appName": .string("Target App"), "path": .string("File")]),
    ("missing_app", ["path": .array([.string("File")])])
  ]
  for (suffix, args) in invalidMenuClicks {
    let invalid: Envelope<EmptyPayload> = try send(
      AgentRequest(id: "menu_click_\(suffix)", action: "functions.run", params: AgentRequestParams(functionName: "menu.click", args: args)),
      to: menuClickHandler
    )
    expect(!invalid.ok, "menu.click \(suffix) should fail validation")
    expectEqual(invalid.error?.code, "invalid_args", "menu.click \(suffix) validation code")
  }

  // window.list resolves the running app and requires Observe.
  let windowListHandler = makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(rules: [observeRule]))
  let windowList: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "window_list", action: "functions.run", params: AgentRequestParams(functionName: "window.list", args: ["appName": .string("Target App")])),
    to: windowListHandler
  )
  expect(windowList.ok, "authorized window.list should run")
  expectEqual(windows.listAppNames.last ?? nil, "Target App", "window.list must dispatch the resolved app name")
  guard let windowListValue = windowList.data?.result.value,
        case .object(let windowListObject) = windowListValue,
        case .array(let windowItems)? = windowListObject["windows"],
        case .object(let firstWindow)? = windowItems.first else {
    throw NSError(domain: "ProtocolVerifier", code: 33, userInfo: [NSLocalizedDescriptionKey: "Unexpected window.list result"])
  }
  expectEqual(firstWindow["title"], .string("Untitled"), "window.list window title")
  expectEqual(firstWindow["role"], .string("AXWindow"), "window.list window role")

  // window.frame resolves the running app, requires Observe, and returns the
  // window geometry in screen points.
  let windowFrameHandler = makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(rules: [observeRule]))
  let windowFrameDenied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "window_frame_denied", action: "functions.run", params: AgentRequestParams(functionName: "window.frame", args: ["appName": .string("Target App")])),
    to: makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .notNow)))
  )
  expect(!windowFrameDenied.ok, "window.frame should require Observe")
  expectEqual(windowFrameDenied.error?.code, "app_permission_required", "window.frame permission code")

  let windowFrame: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "window_frame", action: "functions.run", params: AgentRequestParams(functionName: "window.frame", args: ["appName": .string(" Target App "), "title": .string(" Untitled ")])),
    to: windowFrameHandler
  )
  expect(windowFrame.ok, "authorized window.frame should run")
  expectEqual(
    windows.frameRequests.last,
    RecordingWindowService.RecordedFrameRequest(appName: "Target App", title: "Untitled"),
    "window.frame must dispatch the resolved app and normalized title"
  )
  guard let windowFrameValue = windowFrame.data?.result.value,
        case .object(let windowFrameObject) = windowFrameValue,
        case .object(let windowFrameRect)? = windowFrameObject["frame"] else {
    throw NSError(domain: "ProtocolVerifier", code: 36, userInfo: [NSLocalizedDescriptionKey: "Unexpected window.frame result"])
  }
  expectEqual(windowFrameObject["appName"], .string("Target App"), "window.frame appName")
  expectEqual(windowFrameRect["width"], .number(1200), "window.frame width in points")
  expectEqual(windowFrameRect["height"], .number(800), "window.frame height in points")

  let windowFrameMissingApp: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "window_frame_missing_app", action: "functions.run", params: AgentRequestParams(functionName: "window.frame", args: ["title": .string("Untitled")])),
    to: windowFrameHandler
  )
  expect(!windowFrameMissingApp.ok, "window.frame without appName should fail validation")
  expectEqual(windowFrameMissingApp.error?.code, "invalid_args", "window.frame missing appName code")

  let windowFrameMissingWindow: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "window_frame_missing_window", action: "functions.run", params: AgentRequestParams(functionName: "window.frame", args: ["appName": .string("Target App"), "title": .string("Missing")])),
    to: windowFrameHandler
  )
  expect(!windowFrameMissingWindow.ok, "window.frame should propagate a missing-window failure")
  expectEqual(windowFrameMissingWindow.error?.code, "element_not_found", "window.frame missing window code")

  // display.info is a global read gated by the Display category Observe grant.
  let displayDenied: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "display_info_denied", action: "functions.run", params: AgentRequestParams(functionName: "display.info", args: [:])),
    to: makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(prompter: FakePermissionPrompter(response: .notNow)))
  )
  expect(!displayDenied.ok, "display.info should require the Display Observe grant")
  expectEqual(displayDenied.error?.code, "app_permission_required", "display.info permission code")

  let displayHandler = makeHandler(
    state: FunctionRuntimeState(),
    coordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(target: GlobalPermissionCategory.display.permissionTarget, mode: .observe)
    ])
  )
  let displayInfo: Envelope<FunctionRunPayload> = try send(
    AgentRequest(id: "display_info", action: "functions.run", params: AgentRequestParams(functionName: "display.info", args: [:])),
    to: displayHandler
  )
  expect(displayInfo.ok, "authorized display.info should run")
  guard let displayInfoValue = displayInfo.data?.result.value,
        case .object(let displayInfoObject) = displayInfoValue,
        case .array(let displays)? = displayInfoObject["displays"],
        case .object(let firstDisplay)? = displays.first else {
    throw NSError(domain: "ProtocolVerifier", code: 34, userInfo: [NSLocalizedDescriptionKey: "Unexpected display.info result"])
  }
  expect(!displays.isEmpty, "display.info should report at least one display")
  expect((firstDisplay["scale"]?.numberValue ?? 0) >= 1, "display.info scale should be at least 1")
  guard case .object(let displayFrame)? = firstDisplay["frame"] else {
    throw NSError(domain: "ProtocolVerifier", code: 35, userInfo: [NSLocalizedDescriptionKey: "display.info frame missing"])
  }
  expect((displayFrame["width"]?.numberValue ?? 0) > 0, "display.info frame width should be positive")
  expect((displayFrame["height"]?.numberValue ?? 0) > 0, "display.info frame height should be positive")

  // Window mutations are disabled by default and require Control.
  let windowCloseDisabled: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "window_close_disabled",
      action: "functions.run",
      params: AgentRequestParams(functionName: "window.close", args: ["appName": .string("Target App")])
    ),
    to: makeHandler(state: FunctionRuntimeState(), coordinator: AXPermissionCoordinator(rules: [controlRule]))
  )
  expect(!windowCloseDisabled.ok, "window.close should be disabled by default")
  expectEqual(windowCloseDisabled.error?.code, "function_disabled", "window.close default-enable code")

  let windowHandler = makeHandler(
    state: FunctionRuntimeState(enabledFunctionNames: ["window.close", "window.minimize", "window.zoom", "window.raise"]),
    coordinator: AXPermissionCoordinator(rules: [controlRule])
  )

  let windowCloseObserveOnly: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "window_close_observe_only",
      action: "functions.run",
      params: AgentRequestParams(functionName: "window.close", args: ["appName": .string("Target App")])
    ),
    to: makeHandler(
      state: FunctionRuntimeState(enabledFunctionNames: ["window.close"]),
      coordinator: AXPermissionCoordinator(rules: [observeRule], prompter: FakePermissionPrompter(response: .notNow))
    )
  )
  expect(!windowCloseObserveOnly.ok, "Observe must not permit window.close")
  expectEqual(windowCloseObserveOnly.error?.code, "app_permission_required", "window.close Control permission code")

  let windowActions: [(String, String)] = [
    ("window.close", "window.close"),
    ("window.minimize", "window.minimize"),
    ("window.zoom", "window.zoom"),
    ("window.raise", "window.raise")
  ]
  for (name, expectedAction) in windowActions {
    let result: Envelope<FunctionRunPayload> = try send(
      AgentRequest(
        id: "\(name)_run",
        action: "functions.run",
        params: AgentRequestParams(functionName: name, args: ["appName": .string(" Target App "), "title": .string(" Untitled ")])
      ),
      to: windowHandler
    )
    expect(result.ok, "authorized \(name) should run")
    expectEqual(windows.actions.last, RecordingWindowService.RecordedAction(action: expectedAction, appName: "Target App", title: "Untitled"), "\(name) must dispatch the resolved app and normalized title")
  }

  let windowCloseMissingApp: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "window_close_missing_app", action: "functions.run", params: AgentRequestParams(functionName: "window.close", args: ["title": .string("Untitled")])),
    to: windowHandler
  )
  expect(!windowCloseMissingApp.ok, "window.close without appName should fail validation")
  expectEqual(windowCloseMissingApp.error?.code, "invalid_args", "window.close missing appName code")

  let windowCloseMissingWindow: Envelope<EmptyPayload> = try send(
    AgentRequest(id: "window_close_missing_window", action: "functions.run", params: AgentRequestParams(functionName: "window.close", args: ["appName": .string("Target App"), "title": .string("Missing")])),
    to: windowHandler
  )
  expect(!windowCloseMissingWindow.ok, "window.close should propagate a missing-window failure")
  expectEqual(windowCloseMissingWindow.error?.code, "element_not_found", "window.close missing window code")
}

func verifyStoredTemplateReviewAndOutputBounds() throws {
  let target = FunctionTarget(bundleID: "com.example.TestApp", appName: "Test App", requiresAutomation: true)
  let resolver = StaticTemplateTargetResolver(targets: [target.bundleID.lowercased(): target])
  let state = FunctionRuntimeState(templateTargetResolver: resolver)
  let source = """
  tell application id "com.example.TestApp"
    return $value
  end tell
  """
  let proposal = try state.submitProposal(
    name: "reviewed.template",
    description: "Reviewed test template",
    rationale: "Verifier",
    exampleScript: source
  )
  _ = try expectAgentErrorCode("invalid_args") {
    _ = try state.approveProposal(id: proposal.id, approvedSourceDigest: "not-the-displayed-digest")
  }
  let template = try state.approveProposal(
    id: proposal.id,
    approvedSourceDigest: TemplateSourceReview.digest(for: source.trimmingCharacters(in: .whitespacesAndNewlines))
  )
  expect(template.isReviewed, "template source metadata must be reviewed")
  expectEqual(template.targetBundleID, target.bundleID, "reviewed template target bundle")
  expectEqual(template.targetAppName, target.appName, "reviewed template target app name")
  expectEqual(template.argumentNames, ["value"], "reviewed template placeholders")

  let registry = FunctionRegistry(functions: [])
  guard let function = registry.function(named: template.name, state: state) else {
    throw NSError(domain: "ProtocolVerifier", code: 7, userInfo: [NSLocalizedDescriptionKey: "Reviewed template was not registered"])
  }
  let escapedInput = "quote " + String(UnicodeScalar(34)) + " and slash " + String(UnicodeScalar(92)) + " and newline" + String(UnicodeScalar(10))
  let plan = try function.makeExecutionPlan(args: ["value": .string(escapedInput)])
  expectEqual(plan.target?.bundleID, target.bundleID, "template must dispatch only to persisted target bundle")
  let literal = FixedAppleScriptExecutor().appleScriptStringLiteral(escapedInput)
  let quoteEscape = String(UnicodeScalar(92)) + String(UnicodeScalar(34))
  let backslashEscape = String(repeating: String(UnicodeScalar(92)), count: 2)
  let newlineEscape = String(UnicodeScalar(92)) + "n"
  expect(literal.contains(quoteEscape), "template substitutions must escape quotes")
  expect(literal.contains(backslashEscape), "template substitutions must escape backslashes")
  expect(literal.contains(newlineEscape), "template substitutions must escape newlines")

  let dynamic = try state.submitProposal(
    name: "dynamic.template",
    description: "Dynamic target",
    rationale: "Verifier",
    exampleScript: "tell application \"Test App\" to return \"no\""
  )
  _ = try expectAgentErrorCode("invalid_args") {
    _ = try state.approveProposal(id: dynamic.id, approvedSourceDigest: TemplateSourceReview.digest(for: dynamic.exampleScript ?? ""))
  }
  let multiTarget = try state.submitProposal(
    name: "multi.template",
    description: "Multi target",
    rationale: "Verifier",
    exampleScript: "tell application id \"com.example.TestApp\"\n  tell application id \"com.example.Other\" to return \"no\"\nend tell"
  )
  _ = try expectAgentErrorCode("invalid_args") {
    _ = try state.approveProposal(id: multiTarget.id, approvedSourceDigest: TemplateSourceReview.digest(for: multiTarget.exampleScript ?? ""))
  }
  let obfuscated = try state.submitProposal(
    name: "obfuscated.template",
    description: "Obfuscated shell",
    rationale: "Verifier",
    exampleScript: "tell application id \"com.example.TestApp\"\n  do\\n  shell script \"id\"\nend tell"
  )
  _ = try expectAgentErrorCode("invalid_args") {
    _ = try state.approveProposal(id: obfuscated.id, approvedSourceDigest: TemplateSourceReview.digest(for: obfuscated.exampleScript ?? ""))
  }
  let unresolvedState = FunctionRuntimeState(templateTargetResolver: StaticTemplateTargetResolver(targets: [:]))
  let unresolved = try unresolvedState.submitProposal(
    name: "unresolved.template",
    description: "Unresolved target",
    rationale: "Verifier",
    exampleScript: source
  )
  _ = try expectAgentErrorCode("invalid_args") {
    _ = try unresolvedState.approveProposal(id: unresolved.id, approvedSourceDigest: TemplateSourceReview.digest(for: source.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  let legacyJSON: [String: Any] = [
    "id": UUID().uuidString,
    "name": "legacy.template",
    "summary": "Legacy source",
    "script": source,
    "argumentNames": ["value"],
    "approvedAt": Date().timeIntervalSinceReferenceDate
  ]
  let legacy = try JSONDecoder().decode(StoredFunctionTemplate.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
  expect(!legacy.isReviewed, "legacy metadata must decode fail-closed")
  let legacyState = FunctionRuntimeState(
    enabledFunctionNames: [legacy.name],
    templates: [legacy],
    templateTargetResolver: resolver
  )
  expect(legacyState.executableTemplate(named: legacy.name) == nil, "legacy template must remain disabled until re-review")
  expect(legacyState.requeueLegacyTemplateForReview(id: legacy.id), "legacy template should be preserved for explicit re-review")
  expectEqual(legacyState.snapshot().proposals.count, 1, "legacy re-review should populate the proposal inbox")

  let fileManager = FileManager.default
  let revealFixture = fileManager.temporaryDirectory.appendingPathComponent("okbrain-reveal-\(UUID().uuidString)", isDirectory: true)
  let allowedRoot = revealFixture.appendingPathComponent("allowed", isDirectory: true)
  let outsideRoot = revealFixture.appendingPathComponent("outside", isDirectory: true)
  try fileManager.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
  try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: revealFixture) }
  let escapingLink = allowedRoot.appendingPathComponent("escape", isDirectory: true)
  try fileManager.createSymbolicLink(at: escapingLink, withDestinationURL: outsideRoot)
  let escapedMissingChild = escapingLink.appendingPathComponent("missing.txt").path
  let fileEditing = LocalFileEditingService(configuration: FileEditingConfiguration(
    enabled: true,
    mode: .readWrite,
    allowedRoots: [FileEditingAllowedRoot(path: allowedRoot.path, mode: .readWrite)]
  ))
  _ = try expectAgentErrorCode("path_outside_root") {
    _ = try fileEditing.resolveExistingReadablePath(escapedMissingChild)
  }
  let revealHandler = AgentRequestHandler(
    configuration: AgentConfiguration(fileEditing: FileEditingConfiguration(
      enabled: true,
      mode: .readWrite,
      allowedRoots: [FileEditingAllowedRoot(path: allowedRoot.path, mode: .readWrite)]
    )),
    permissions: FakePermissionService(payload: .init(screenRecording: .denied, accessibility: .denied)),
    screenshots: FakeScreenshotService(capturedImage: CapturedImage(data: Data([0x52]), width: 1, height: 1)),
    fileEditing: fileEditing,
    functionRegistry: FunctionRegistry.standard(),
    functionState: FunctionRuntimeState(enabledFunctionNames: ["finder.reveal"]),
    automationPermissions: FakeAutomationPermissionService(status: .authorized),
    axPermissionCoordinator: AXPermissionCoordinator(rules: [
      AXAppPermissionRule(bundleID: "com.apple.finder", appName: "Finder", mode: .control)
    ])
  )
  let escapedReveal: Envelope<EmptyPayload> = try send(
    AgentRequest(
      id: "finder_reveal_symlink_escape",
      action: "functions.run",
      params: AgentRequestParams(functionName: "finder.reveal", args: ["path": .string(escapedMissingChild)])
    ),
    to: revealHandler
  )
  expect(!escapedReveal.ok, "finder.reveal must reject a missing child beneath an escaping symlink")
  expectEqual(escapedReveal.error?.code, "path_outside_root", "finder.reveal symlink escape error code")

  let oversizedResult = FunctionResult(value: .string(String(repeating: "x", count: FunctionOutputLimits.maximumEncodedResultBytes + 1)))
  _ = try expectAgentErrorCode("function_failed") {
    try FunctionOutputLimits.validate(oversizedResult)
  }

  do {
    _ = try FixedAppleScriptExecutor(maximumOutputBytes: 64).runAppleScript("""
    set outputText to "0123456789"
    repeat with index from 1 to 8
      set outputText to outputText & outputText
    end repeat
    return outputText
    """, timeout: 5)
    expect(false, "AppleScript output over the cap should fail")
  } catch let error as FixedAppleScriptExecutor.ExecutionError {
    guard case .outputTooLarge = error else {
      throw NSError(domain: "ProtocolVerifier", code: 8, userInfo: [NSLocalizedDescriptionKey: "Expected bounded output failure, got \(error.localizedDescription)"])
    }
  }

  do {
    _ = try FixedAppleScriptExecutor(maximumOutputBytes: 1_024).runAppleScript("delay 2\nreturn \"late\"", timeout: 1)
    expect(false, "AppleScript timeout should terminate the process")
  } catch let error as FixedAppleScriptExecutor.ExecutionError {
    guard case .timedOut = error else {
      throw NSError(domain: "ProtocolVerifier", code: 9, userInfo: [NSLocalizedDescriptionKey: "Expected timeout failure, got \(error.localizedDescription)"])
    }
  }
}

final class RecordingAccessibilityService: AccessibilityServicing, @unchecked Sendable {
  private let lock = NSLock()
  private let listedApps: [AXAppPayload]
  private var recordedTypedPIDs: [Int32?] = []
  private var recordedMenuQueryPIDs: [Int32?] = []
  private var recordedFrontmostPIDs: [Int32?] = []

  init(apps: [AXAppPayload]) {
    listedApps = apps
  }

  var typedPIDs: [Int32?] {
    lock.lock()
    defer { lock.unlock() }
    return recordedTypedPIDs
  }

  var menuQueryPIDs: [Int32?] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMenuQueryPIDs
  }

  var frontmostPIDs: [Int32?] {
    lock.lock()
    defer { lock.unlock() }
    return recordedFrontmostPIDs
  }

  private func recordMenuQuery(_ query: AXElementQuery) {
    lock.lock()
    recordedMenuQueryPIDs.append(query.pid)
    lock.unlock()
  }

  func listApps() throws -> AXAppListPayload { AXAppListPayload(apps: listedApps) }
  func listWindows(query: AXElementQuery) throws -> AXWindowListPayload { AXWindowListPayload(pid: query.pid ?? 0, app: query.appName ?? "Test", windows: []) }
  func tree(query: AXElementQuery) throws -> AXTreePayload { throw AgentProtocolError.elementNotFound("Unused test tree") }
  func find(query: AXElementQuery, limit: Int) throws -> AXFindPayload { AXFindPayload(matches: [], truncated: false) }
  func perform(query: AXElementQuery, action: String) throws -> AXPerformPayload { throw AgentProtocolError.elementNotFound("Unused test perform") }
  func menuClick(query: AXElementQuery, title: String) throws -> AXMenuActionPayload {
    recordMenuQuery(query)
    return AXMenuActionPayload(
      action: "ax.menu-click",
      appName: query.appName ?? "Test",
      path: [title],
      item: AXElementNode(role: "AXMenuBarItem", subrole: nil, title: title, label: nil, identifier: nil, value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil)
    )
  }
  func menuNavigate(query: AXElementQuery, path: [String]) throws -> AXMenuActionPayload {
    recordMenuQuery(query)
    return AXMenuActionPayload(
      action: "ax.menu-navigate",
      appName: query.appName ?? "Test",
      path: path,
      item: AXElementNode(role: "AXMenuItem", subrole: nil, title: path.last, label: nil, identifier: nil, value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil)
    )
  }
  func menuListItems(query: AXElementQuery) throws -> AXMenuListPayload {
    recordMenuQuery(query)
    return AXMenuListPayload(appName: query.appName ?? "Test", items: [AXMenuItemPayload(title: "File", enabled: true)])
  }
  func value(query: AXElementQuery) throws -> AXValuePayload { throw AgentProtocolError.elementNotFound("Unused test value") }
  func setValue(query: AXElementQuery, value: String) throws -> AXValuePayload { throw AgentProtocolError.elementNotFound("Unused test value") }
  func typeText(_ text: String, targetPid: Int32?) throws {
    lock.lock()
    recordedTypedPIDs.append(targetPid)
    lock.unlock()
  }
  func keyPress(key: String, modifiers: [String], targetPid: Int32?) throws {}
  func clickAt(x: Double, y: Double, button: String, clickCount: Int, targetPid: Int32?) throws {}
  func scroll(query: AXElementQuery, deltaX: Int, deltaY: Int, x: Double?, y: Double?, targetPid: Int32?) throws {}
  func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, targetPid: Int32?) throws {}
  func ensureFrontmost(pid: Int32?) {
    lock.lock()
    recordedFrontmostPIDs.append(pid)
    lock.unlock()
  }
}

final class RecordingAXTargetResolver: AXTargetResolving, @unchecked Sendable {
  private let lock = NSLock()
  private let resolution: AXResolvedTarget
  private let current: Bool
  private var fallbackRequests: [Bool] = []

  init(resolution: AXResolvedTarget, isCurrent: Bool) {
    self.resolution = resolution
    current = isCurrent
  }

  var frontmostFallbackRequests: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return fallbackRequests
  }

  func resolve(params: AgentRequestParams, useFrontmostFallback: Bool) throws -> AXResolvedTarget {
    lock.lock()
    fallbackRequests.append(useFrontmostFallback)
    lock.unlock()
    return resolution
  }

  func isStillCurrent(_ resolution: AXResolvedTarget) -> Bool { current }
}

final class CountingPermissionPrompter: AXPermissionPrompting, @unchecked Sendable {
  private let lock = NSLock()
  private let response: AXPermissionPromptResponse
  private var storedCount = 0

  init(response: AXPermissionPromptResponse) {
    self.response = response
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCount
  }

  func prompt(_ request: AXPermissionPromptRequest, timeout: TimeInterval) -> AXPermissionPromptResponse {
    lock.lock()
    storedCount += 1
    lock.unlock()
    return response
  }
}

final class SequencePermissionPrompter: AXPermissionPrompting, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [AXPermissionPromptResponse]

  init(responses: [AXPermissionPromptResponse]) {
    self.responses = responses
  }

  func prompt(_ request: AXPermissionPromptRequest, timeout: TimeInterval) -> AXPermissionPromptResponse {
    lock.lock()
    defer { lock.unlock() }
    guard !responses.isEmpty else { return .notNow }
    return responses.removeFirst()
  }
}

final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }
  func increment() {
    lock.lock()
    storedValue += 1
    lock.unlock()
  }
}

final class LockedBoolean: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Bool
  init(_ value: Bool) { storedValue = value }
  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      storedValue = newValue
      lock.unlock()
    }
  }
}

struct ProbeFunction: MacOSFunction {
  let name: String
  let tier: FunctionTier
  let target: FunctionTarget
  let counter: LockedCounter
  let summary = "Guardrail probe"
  let argSchema: [FunctionArg] = []
  var catalogTargetBundleID: String? { target.bundleID }

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(args: try validateFunctionArgs(args, schema: argSchema), target: target)
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    counter.increment()
    return FunctionResult(value: .object("ran", .bool(true)))
  }
}

struct GlobalProbeFunction: MacOSFunction {
  let name: String
  let tier: FunctionTier
  let category: GlobalPermissionCategory
  let counter: LockedCounter
  let summary = "Global permission probe"
  let argSchema: [FunctionArg] = []
  let catalogTargetBundleID: String? = nil

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(
      args: try validateFunctionArgs(args, schema: argSchema),
      permissionTarget: category.permissionTarget
    )
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    counter.increment()
    return FunctionResult(value: .object("ran", .bool(true)))
  }
}

struct UnmappedProbeFunction: MacOSFunction {
  let name = "probe.unmapped"
  let tier: FunctionTier = .read
  let counter: LockedCounter
  let summary = "Unmapped permission probe"
  let argSchema: [FunctionArg] = []
  let catalogTargetBundleID: String? = nil

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(args: try validateFunctionArgs(args, schema: argSchema))
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    counter.increment()
    return FunctionResult(value: .object("ran", .bool(true)))
  }
}

/// Deliberately malformed plans verify that handler-side authorization cannot
/// be redirected by a buggy or future catalog implementation.
struct MismatchedPermissionProbeFunction: MacOSFunction {
  let name: String
  let tier: FunctionTier
  let target: FunctionTarget?
  let declaredPermissionTarget: PermissionTarget
  let counter: LockedCounter
  let summary = "Mismatched permission probe"
  let argSchema: [FunctionArg] = []
  var catalogTargetBundleID: String? { target?.bundleID }

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(
      args: try validateFunctionArgs(args, schema: argSchema),
      target: target,
      permissionTarget: declaredPermissionTarget
    )
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    counter.increment()
    return FunctionResult(value: .object("ran", .bool(true)))
  }
}

final class MutatingAutomationPermissionService: AutomationPermissionServicing, @unchecked Sendable {
  private let lock = NSLock()
  private let initial: AutomationPermissionStatus
  private let afterRequest: AutomationPermissionStatus
  private let onRequest: @Sendable () -> Void
  private var storedRequestCount = 0

  init(
    initial: AutomationPermissionStatus,
    afterRequest: AutomationPermissionStatus,
    onRequest: @escaping @Sendable () -> Void = {}
  ) {
    self.initial = initial
    self.afterRequest = afterRequest
    self.onRequest = onRequest
  }

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedRequestCount
  }

  func status(forBundleID bundleID: String) -> AutomationPermissionStatus { initial }
  func requestAccess(forBundleID bundleID: String) -> AutomationPermissionStatus {
    lock.lock()
    storedRequestCount += 1
    lock.unlock()
    onRequest()
    return afterRequest
  }
}

struct StaticTemplateTargetResolver: TemplateTargetResolving {
  let targets: [String: FunctionTarget]
  func resolveTemplateTarget(bundleID: String) -> FunctionTarget? {
    targets[bundleID.lowercased()]
  }
}

func runConfigurationVerifier() throws {  let fileManager = FileManager.default
  let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("okbrain-agent-config-\(UUID().uuidString).bundle", isDirectory: true)
  let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
  try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: bundleURL) }

  let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
  let devPlist = """
  <?xml version=\"1.0\" encoding=\"UTF-8\"?>
  <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
  <plist version=\"1.0\">
  <dict>
    <key>CFBundleIdentifier</key>
    <string>com.okbrain.macos-agent.dev</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>AppEnvironment</key>
    <string>dev</string>
    <key>AppStateDirectoryName</key>
    <string>.okbrain-macos-agent-dev</string>
  </dict>
  </plist>
  """
  try devPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

  guard let bundle = Bundle(url: bundleURL) else {
    throw NSError(domain: "Verifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load test bundle"])
  }

  let devConfiguration = AgentConfiguration.current(environment: [:], bundle: bundle)
  expectEqual(devConfiguration.appEnvironment, "dev", "dev app environment")
  expectEqual(devConfiguration.stateDirectoryName, ".okbrain-macos-agent-dev", "dev state directory")
  expectEqual(devConfiguration.socketPath, AgentConfiguration.defaultDevSocketPath, "dev default socket")
  let toggledDevConfiguration = devConfiguration.withFileEditingSettings(enabled: true, allowedRoots: [])
  expectEqual(toggledDevConfiguration.appEnvironment, "dev", "dev app environment after file editing toggle")
  expectEqual(toggledDevConfiguration.stateDirectoryName, ".okbrain-macos-agent-dev", "dev state directory after file editing toggle")

  let overrideConfiguration = AgentConfiguration.current(
    environment: ["MACOS_AGENT_SOCKET_PATH": "/tmp/custom-okbrain.sock"],
    bundle: bundle
  )
  expectEqual(overrideConfiguration.socketPath, "/tmp/custom-okbrain.sock", "socket override precedence")

  let prodConfiguration = AgentConfiguration.current(environment: [:], bundle: .main)
  expectEqual(prodConfiguration.appEnvironment, "prod", "main app environment fallback")
  expectEqual(prodConfiguration.socketPath, AgentConfiguration.defaultSocketPath, "prod default socket")
}

func runFileEditingVerifier(permissions: FakePermissionService) throws {
  let fileManager = FileManager.default
  let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent(".build/okbrain-agent-fs-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: rootURL) }

  func absolutePath(_ relativePath: String) -> String {
    rootURL.appendingPathComponent(relativePath).path
  }

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
    screenshots: FakeScreenshotService(capturedImage: CapturedImage(data: Data([0x52, 0x49]), mimeType: "image/webp", width: 1, height: 1))
  )

  let status: Envelope<AgentStatusPayload> = try send(
    AgentRequest(protocolName: AgentConfiguration.protocolName, id: "fs_status", action: "agent.status", params: AgentRequestParams()),
    to: handler
  )
  expect(status.ok, "v3 status response should be ok")
  expectEqual(status.protocolName, AgentConfiguration.protocolName, "binary status protocol")
  expect(status.data?.capabilities.contains("fs.read") == true, "v3 status should expose fs.read")
  expectEqual(status.data?.fileEditing?.mode, .readWrite, "file editing mode")

  let workspace: Envelope<WorkspaceDescribePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_workspace",
      action: "workspace.describe",
      params: AgentRequestParams(path: rootURL.path)
    ),
    to: handler
  )
  expect(workspace.ok, "workspace.describe should be ok")
  expectEqual(workspace.data?.exists, true, "workspace exists")

  let write: Envelope<FileWritePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_write",
      action: "fs.write",
      params: AgentRequestParams(
        path: absolutePath("src/app.txt"),
        content: "one\nreturn null\nthree\n",
        createDirs: true
      )
    ),
    to: handler
  )
  expect(write.ok, "fs.write should be ok")
  expectEqual(write.data?.path, absolutePath("src/app.txt"), "write path")
  expect(write.data?.sha256.isEmpty == false, "write sha")

  let read: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_read",
      action: "fs.read",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), startLine: 2, endLine: 2)
    ),
    to: handler
  )
  expect(read.ok, "fs.read should be ok")
  expectEqual(read.data?.content, "return null\n", "read line range")

  let patch: Envelope<FilePatchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_patch",
      action: "fs.patch",
      params: AgentRequestParams(
        path: absolutePath("src/app.txt"),
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
      protocolName: AgentConfiguration.protocolName,
      id: "fs_read_after_patch",
      action: "fs.read",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), startLine: 1, endLine: 4)
    ),
    to: handler
  )
  expect(freshReadAfterPatch.ok, "fs.read after fs.patch should be ok")
  expectEqual(freshReadAfterPatch.data?.content, "one\nreturn 42\nthree\n", "fs.read should reflect patched content")
  expectEqual(freshReadAfterPatch.data?.lineCount, 3, "fs.read after patch line count")
  expectEqual(freshReadAfterPatch.data?.sha256, patch.data?.sha256, "fs.read after patch sha")

  let overwrite: Envelope<FileWritePayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_write_overwrite",
      action: "fs.write",
      params: AgentRequestParams(
        path: absolutePath("src/app.txt"),
        content: "one\nreturn 42\ninserted\nthree\n",
        expectedSha256: patch.data?.sha256
      )
    ),
    to: handler
  )
  expect(overwrite.ok, "fs.write overwrite should be ok")

  let freshReadAfterWrite: Envelope<FileReadPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_read_after_write",
      action: "fs.read",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), startLine: 1, endLine: 10)
    ),
    to: handler
  )
  expect(freshReadAfterWrite.ok, "fs.read after fs.write should be ok")
  expectEqual(freshReadAfterWrite.data?.content, "one\nreturn 42\ninserted\nthree\n", "fs.read should reflect overwritten content")
  expectEqual(freshReadAfterWrite.data?.lineCount, 4, "fs.read after write line count")
  expectEqual(freshReadAfterWrite.data?.sha256, overwrite.data?.sha256, "fs.read after write sha")

  let search: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_search",
      action: "fs.search",
      params: AgentRequestParams(path: rootURL.path, glob: "*.txt", query: "return 42")
    ),
    to: handler
  )
  expect(search.ok, "fs.search should be ok")
  expectEqual(search.data?.matches.first?.file, "src/app.txt", "search match file")
  expectEqual(search.data?.matches.first?.line, 2, "search match line")

  let fileSearch: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_search_file",
      action: "fs.search",
      params: AgentRequestParams(path: absolutePath("src/app.txt"), query: "inserted")
    ),
    to: handler
  )
  expect(fileSearch.ok, "fs.search should accept a single-file path")
  expect(fileSearch.data?.matches.count == 1, "single-file search should return one match")
  expectEqual(fileSearch.data?.matches.first?.file, "app.txt", "single-file search match file")
  expectEqual(fileSearch.data?.matches.first?.line, 3, "single-file search match line")

  let list: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_list",
      action: "fs.list",
      params: AgentRequestParams(path: rootURL.path, recursive: true, glob: "*.txt")
    ),
    to: handler
  )
  expect(list.ok, "fs.list should be ok")
  expect(list.data?.entries.contains(where: { $0.path == "src/app.txt" }) == true, "list should include file")
  expect(list.data?.entries.contains(where: { $0.name == "src/app.txt" }) == true, "list should include file name")

  // --- Hidden file/directory tests ---
  // Create hidden files and directories
  let hiddenSubdir = absolutePath(".hidden_dir/subdir")
  try fileManager.createDirectory(at: URL(fileURLWithPath: hiddenSubdir, isDirectory: true), withIntermediateDirectories: true)
  try "secret content".write(to: URL(fileURLWithPath: absolutePath(".hidden_dir/inside.txt")), atomically: true, encoding: .utf8)
  try "deep secret".write(to: URL(fileURLWithPath: absolutePath(".hidden_dir/subdir/deep.txt")), atomically: true, encoding: .utf8)
  try "hidden root".write(to: URL(fileURLWithPath: absolutePath(".hidden_file")), atomically: true, encoding: .utf8)
  // Create a .git directory to verify it stays excluded via gitignore matcher
  try fileManager.createDirectory(at: URL(fileURLWithPath: absolutePath(".git"), isDirectory: true), withIntermediateDirectories: true)
  try "git config".write(to: URL(fileURLWithPath: absolutePath(".git/config")), atomically: true, encoding: .utf8)

  // fs.list should include hidden files by default (includeHidden defaults to true)
  let listHidden: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_list_hidden",
      action: "fs.list",
      params: AgentRequestParams(path: rootURL.path, recursive: true)
    ),
    to: handler
  )
  expect(listHidden.ok, "fs.list with hidden should be ok")
  expect(
    listHidden.data?.entries.contains(where: { $0.path == ".hidden_file" }) == true,
    "list should include hidden file .hidden_file"
  )
  expect(
    listHidden.data?.entries.contains(where: { $0.path == ".hidden_dir/inside.txt" }) == true,
    "list should include file inside .hidden_dir"
  )
  expect(
    listHidden.data?.entries.contains(where: { $0.path == ".hidden_dir/subdir/deep.txt" }) == true,
    "list should include file in subdir of .hidden_dir"
  )
  // .git must still be excluded by GitignoreMatcher (respectGitignore defaults to true)
  expect(
    listHidden.data?.entries.contains(where: { $0.path.hasPrefix(".git") }) == false,
    "list should exclude .git directory via gitignore matcher"
  )

  // fs.search should find content inside hidden files by default
  let searchHidden: Envelope<FileSearchPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_search_hidden",
      action: "fs.search",
      params: AgentRequestParams(path: rootURL.path, query: "secret")
    ),
    to: handler
  )
  expect(searchHidden.ok, "fs.search hidden should be ok")
  expect(
    searchHidden.data?.matches.contains(where: { $0.file == ".hidden_dir/inside.txt" }) == true,
    "search should find match inside .hidden_dir"
  )
  expect(
    searchHidden.data?.matches.contains(where: { $0.file == ".hidden_dir/subdir/deep.txt" }) == true,
    "search should find match inside .hidden_dir/subdir"
  )
  // .git must still be excluded from search results
  expect(
    searchHidden.data?.matches.contains(where: { $0.file.hasPrefix(".git") }) == false,
    "search should exclude .git directory via gitignore matcher"
  )

  // fs.list with includeHidden: false should exclude hidden files
  let listExcludeHidden: Envelope<FileListPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_list_exclude",
      action: "fs.list",
      params: AgentRequestParams(path: rootURL.path, recursive: true, includeHidden: false)
    ),
    to: handler
  )
  expect(listExcludeHidden.ok, "fs.list excludeHidden should be ok")
  expect(
    listExcludeHidden.data?.entries.contains(where: { $0.path == ".hidden_file" }) == false,
    "list with includeHidden:false should exclude .hidden_file"
  )
  expect(
    listExcludeHidden.data?.entries.contains(where: { $0.path.hasPrefix(".hidden_dir") }) == false,
    "list with includeHidden:false should exclude .hidden_dir"
  )
  // Regular files should still appear
  expect(
    listExcludeHidden.data?.entries.contains(where: { $0.path == "src/app.txt" }) == true,
    "list with includeHidden:false should still include regular files"
  )

  let escape: Envelope<EmptyPayload> = try send(
    AgentRequest(
      protocolName: AgentConfiguration.protocolName,
      id: "fs_escape",
      action: "fs.read",
      params: AgentRequestParams(path: rootURL.deletingLastPathComponent().appendingPathComponent("outside.txt").path)
    ),
    to: handler
  )
  expect(!escape.ok, "root escape should fail")
  expectEqual(escape.error?.code, "root_not_allowed", "root escape error code")
}

func runSocketVerifier() throws {
  let socketPath = "/private/tmp/oka-\(UUID().uuidString.prefix(8)).sock"
  defer { unlink(socketPath) }
  let stateLock = NSLock()
  var isRunning = false
  var latestSnapshot: SocketServerSnapshot?
  let requestHeader = Data(#"{"protocol":"okbrain.macos-agent.v3","id":"req_socket","action":"agent.info"}"#.utf8)
  let responseHeader = Data(#"{"protocol":"okbrain.macos-agent.v3","id":"req_socket","ok":true,"data":{"transport":"ssh-unix-socket-binary-frame"}}"#.utf8)
  let server = UnixSocketServer(socketPath: socketPath, maxRequestBytes: 1024) { requestData in
    expectEqual(requestData, requestHeader, "socket request frame header")
    return (try? AgentBinaryFrame.encode(headerData: responseHeader)) ?? Data()
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

  try writeAll(try AgentBinaryFrame.encode(headerData: requestHeader), to: fd)
  let responseFrame = try AgentBinaryFrame.decode(try readAll(from: fd))
  let response = String(data: responseFrame.headerData, encoding: .utf8) ?? ""
  expect(response.contains(#""ok":true"#), "socket response ok")
  expect(response.contains(#""transport":"ssh-unix-socket-binary-frame""#), "socket response transport")
}

func send<T: Decodable>(_ request: AgentRequest, to handler: AgentRequestHandler) throws -> Envelope<T> {
  try sendFrame(request, to: handler, as: T.self).envelope
}

func sendFrame<T: Decodable>(
  _ request: AgentRequest,
  to handler: AgentRequestHandler,
  as type: T.Type
) throws -> (envelope: Envelope<T>, bodyData: Data) {
  let requestData = try JSONEncoder().encode(request)
  return try sendRawFrame(requestData, to: handler, as: type)
}

func sendRaw<T: Decodable>(_ requestData: Data, to handler: AgentRequestHandler) throws -> Envelope<T> {
  try sendRawFrame(requestData, to: handler, as: T.self).envelope
}

func sendRawFrame<T: Decodable>(
  _ requestData: Data,
  to handler: AgentRequestHandler,
  as type: T.Type
) throws -> (envelope: Envelope<T>, bodyData: Data) {
  let responseData = handler.handle(requestData: requestData)
  let frame = try AgentBinaryFrame.decode(responseData)
  let envelope = try JSONDecoder().decode(Envelope<T>.self, from: frame.headerData)
  return (envelope, frame.bodyData)
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

func readAll(from fd: Int32) throws -> Data {
  var data = Data()

  while true {
    var buffer = [UInt8](repeating: 0, count: 8192)
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count == 0 {
      break
    }

    if count < 0 {
      throw NSError(domain: "ProtocolVerifier", code: 3)
    }

    data.append(contentsOf: buffer.prefix(count))
  }

  return data
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

struct FakeAccessibilityService: AccessibilityServicing {
  var apps: [AXAppPayload] = [
    AXAppPayload(pid: 4242, name: "TextEdit", bundleId: "com.apple.TextEdit", active: true, windowCount: 1)
  ]
  var windows = AXWindowListPayload(
    pid: 4242,
    app: "TextEdit",
    windows: [AXWindowPayload(index: 0, title: "Untitled", frame: CaptureRect(x: 10, y: 10, width: 400, height: 300), main: true)]
  )
  var findResult = AXFindPayload(
    matches: [
      AXElementNode(
        role: "AXButton", subrole: nil, title: "OK", label: nil, identifier: "okButton",
        value: nil, valueTruncated: nil,
        frame: CaptureRect(x: 20, y: 20, width: 80, height: 30),
        enabled: true, focused: false, children: nil
      )
    ],
    truncated: false
  )
  var performResult: AXPerformPayload?
  var valueResult = AXValuePayload(
    element: AXElementNode(
      role: "AXTextField", subrole: nil, title: nil, label: "Name", identifier: "nameField",
      value: .string("hello"), valueTruncated: nil,
      frame: CaptureRect(x: 20, y: 60, width: 200, height: 24),
      enabled: true, focused: true, children: nil
    )
  )
  var treeResult: AXTreePayload?

  func listApps() throws -> AXAppListPayload {
    AXAppListPayload(apps: apps)
  }

  func listWindows(query: AXElementQuery) throws -> AXWindowListPayload {
    windows
  }

  func tree(query: AXElementQuery) throws -> AXTreePayload {
    if let treeResult { return treeResult }
    return AXTreePayload(
      pid: query.pid ?? 4242,
      app: query.appName ?? "TextEdit",
      window: windows.windows.first,
      truncated: false,
      root: AXElementNode(
        role: "AXWindow", subrole: "AXStandardWindow", title: "Untitled", label: nil, identifier: nil,
        value: nil, valueTruncated: nil,
        frame: CaptureRect(x: 10, y: 10, width: 400, height: 300),
        enabled: true, focused: true,
        children: [
          AXElementNode(
            role: "AXButton", subrole: nil, title: "OK", label: nil, identifier: "okButton",
            value: nil, valueTruncated: nil,
            frame: CaptureRect(x: 20, y: 20, width: 80, height: 30),
            enabled: true, focused: false, children: nil
          )
        ]
      )
    )
  }

  func find(query: AXElementQuery, limit: Int) throws -> AXFindPayload {
    findResult
  }

  func perform(query: AXElementQuery, action: String) throws -> AXPerformPayload {
    if let performResult { return performResult }
    return AXPerformPayload(action: action, element: findResult.matches[0])
  }

  func menuClick(query: AXElementQuery, title: String) throws -> AXMenuActionPayload {
    AXMenuActionPayload(
      action: "ax.menu-click",
      appName: query.appName ?? "TextEdit",
      path: [title],
      item: AXElementNode(
        role: "AXMenuBarItem", subrole: nil, title: title, label: nil, identifier: nil,
        value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
      )
    )
  }

  func menuNavigate(query: AXElementQuery, path: [String]) throws -> AXMenuActionPayload {
    AXMenuActionPayload(
      action: "ax.menu-navigate",
      appName: query.appName ?? "TextEdit",
      path: path,
      item: AXElementNode(
        role: "AXMenuItem", subrole: nil, title: path.last, label: nil, identifier: nil,
        value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
      )
    )
  }

  func menuListItems(query: AXElementQuery) throws -> AXMenuListPayload {
    AXMenuListPayload(
      appName: query.appName ?? "TextEdit",
      items: [
        AXMenuItemPayload(title: "TextEdit", enabled: true),
        AXMenuItemPayload(title: "File", enabled: true),
        AXMenuItemPayload(title: "Edit", enabled: true)
      ]
    )
  }

  func value(query: AXElementQuery) throws -> AXValuePayload {
    valueResult
  }

  func setValue(query: AXElementQuery, value: String) throws -> AXValuePayload {
    valueResult
  }

  func typeText(_ text: String, targetPid: Int32?) throws {}

  func keyPress(key: String, modifiers: [String], targetPid: Int32?) throws {}

  func clickAt(x: Double, y: Double, button: String, clickCount: Int, targetPid: Int32?) throws {}
  func scroll(query: AXElementQuery, deltaX: Int, deltaY: Int, x: Double?, y: Double?, targetPid: Int32?) throws {}
  func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, targetPid: Int32?) throws {}
  func ensureFrontmost(pid: Int32?) {}
}

struct FakePermissionPrompter: AXPermissionPrompting {
  let response: AXPermissionPromptResponse

  func prompt(_ request: AXPermissionPromptRequest, timeout: TimeInterval) -> AXPermissionPromptResponse {
    response
  }
}

struct FakeAXTargetResolver: AXTargetResolving {
  func resolve(params: AgentRequestParams, useFrontmostFallback: Bool) throws -> AXResolvedTarget {
    AXResolvedTarget(
      target: AXPermissionTarget(bundleID: "com.apple.TextEdit", appName: "TextEdit", pid: 4242),
      pid: 4242,
      wasResolved: true
    )
  }

  func isStillCurrent(_ resolution: AXResolvedTarget) -> Bool {
    resolution.wasResolved && resolution.pid == 4242
  }
}

struct FakeAutomationPermissionService: AutomationPermissionServicing {
  let status: AutomationPermissionStatus

  func status(forBundleID bundleID: String) -> AutomationPermissionStatus { status }
  func requestAccess(forBundleID bundleID: String) -> AutomationPermissionStatus { status }
}

final class RecordingMenuBarExtrasService: MenuBarExtrasServicing, @unchecked Sendable {
  struct UnfilteredListProbe {
    let target: AXMenuBarExtraAppTarget
    let hasUI: Bool
    let shouldFail: Bool

    init(target: AXMenuBarExtraAppTarget, hasUI: Bool = true, shouldFail: Bool = false) {
      self.target = target
      self.hasUI = hasUI
      self.shouldFail = shouldFail
    }
  }

  private static let defaultTarget = AXMenuBarExtraAppTarget(
    pid: 8123,
    appName: "Status Owner",
    bundleID: "com.example.StatusOwner"
  )

  private let lock = NSLock()
  private let unfilteredProbes: [UnfilteredListProbe]
  private var storedListTargets: [AXMenuBarExtraAppTarget?] = []
  private var storedOpenedTargets: [AXMenuBarExtraAppTarget] = []
  private var storedOpenedTitles: [String] = []
  private var storedClickedTitles: [String] = []
  private var storedClickedPaths: [[String]] = []
  private var storedUnfilteredProbedTargets: [AXMenuBarExtraAppTarget] = []
  private var storedSkippedUnfilteredTargets: [AXMenuBarExtraAppTarget] = []

  init(unfilteredProbes: [UnfilteredListProbe] = []) {
    self.unfilteredProbes = unfilteredProbes.isEmpty
      ? [UnfilteredListProbe(target: Self.defaultTarget)]
      : unfilteredProbes
  }

  var listTargets: [AXMenuBarExtraAppTarget?] {
    lock.lock()
    defer { lock.unlock() }
    return storedListTargets
  }

  var openedTargets: [AXMenuBarExtraAppTarget] {
    lock.lock()
    defer { lock.unlock() }
    return storedOpenedTargets
  }

  var openedTitles: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedOpenedTitles
  }

  var clickedTitles: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedClickedTitles
  }

  var clickedPaths: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return storedClickedPaths
  }

  var unfilteredProbedTargets: [AXMenuBarExtraAppTarget] {
    lock.lock()
    defer { lock.unlock() }
    return storedUnfilteredProbedTargets
  }

  var skippedUnfilteredTargets: [AXMenuBarExtraAppTarget] {
    lock.lock()
    defer { lock.unlock() }
    return storedSkippedUnfilteredTargets
  }

  func listMenuBarExtras(app: AXMenuBarExtraAppTarget?) throws -> AXMenuBarExtrasListPayload {
    lock.lock()
    storedListTargets.append(app)
    lock.unlock()

    if let app {
      return AXMenuBarExtrasListPayload(items: [statusItem(for: app)])
    }

    let items = collectUnfilteredMenuBarExtraItems(
      from: unfilteredProbes,
      shouldInspect: { $0.hasUI },
      inspect: { probe in
        self.recordUnfilteredProbe(probe.target)
        guard !probe.shouldFail else {
          self.recordSkippedUnfilteredProbe(probe.target)
          throw AgentProtocolError.actionFailed("Simulated AX timeout for \(probe.target.appName)")
        }
        return [self.statusItem(for: probe.target)]
      }
    )
    return AXMenuBarExtrasListPayload(items: items)
  }

  func openMenuBarExtra(app: AXMenuBarExtraAppTarget, title: String?) throws -> AXMenuBarExtraOpenPayload {
    let item = statusItem(for: app)
    if let title {
      switch title {
      case "Disabled":
        throw AgentProtocolError.actionFailed("Status item is disabled")
      case "Missing":
        throw AgentProtocolError.elementNotFound("Status item is missing")
      case "Ambiguous":
        throw AgentProtocolError.invalidRequest("Multiple status items match")
      default:
        break
      }
      try requireMatchingStatusItem(title, for: app)
      lock.lock()
      storedOpenedTargets.append(app)
      storedOpenedTitles.append(title)
      lock.unlock()
    } else {
      // Opening by app alone succeeds when the owner exposes exactly one item.
      lock.lock()
      storedOpenedTargets.append(app)
      storedOpenedTitles.append(item.title ?? item.label ?? item.description ?? "<untitled>")
      lock.unlock()
    }
    return AXMenuBarExtraOpenPayload(
      appName: app.appName,
      statusItem: item,
      menuItems: [
        AXElementNode(
          role: "AXMenuItem", subrole: nil, title: "Settings…", label: nil, identifier: "settings",
          value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
        ),
        AXElementNode(
          role: "AXMenuItem", subrole: nil, title: "Quit", label: nil, identifier: "quit",
          value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
        )
      ]
    )
  }

  func clickMenuBarExtra(
    app: AXMenuBarExtraAppTarget,
    title: String,
    menuPath: [String]
  ) throws -> AXMenuBarExtraClickPayload {
    try requireMatchingStatusItem(title, for: app)
    lock.lock()
    storedClickedTitles.append(title)
    storedClickedPaths.append(menuPath)
    lock.unlock()
    return AXMenuBarExtraClickPayload(
      appName: app.appName,
      statusItem: statusItem(for: app),
      path: menuPath,
      item: AXElementNode(
        role: "AXMenuItem", subrole: nil, title: menuPath.last, label: nil, identifier: nil,
        value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
      )
    )
  }

  private func recordUnfilteredProbe(_ target: AXMenuBarExtraAppTarget) {
    lock.lock()
    storedUnfilteredProbedTargets.append(target)
    lock.unlock()
  }

  private func recordSkippedUnfilteredProbe(_ target: AXMenuBarExtraAppTarget) {
    lock.lock()
    storedSkippedUnfilteredTargets.append(target)
    lock.unlock()
  }

  private func requireMatchingStatusItem(_ title: String, for app: AXMenuBarExtraAppTarget) throws {
    let item = statusItem(for: app)
    let candidate = MenuBarExtraStatusItemCandidate(
      title: item.title,
      description: item.description,
      label: item.label,
      identifier: item.identifier
    )
    guard !MenuBarExtraStatusItemMatcher.matchingIndexes(query: title, candidates: [candidate]).isEmpty else {
      throw AgentProtocolError.elementNotFound(
        "Status item '\(title)' not found in \(app.appName). Visible status items: \(candidate.visibleDescription)"
      )
    }
  }

  private func statusItem(for app: AXMenuBarExtraAppTarget) -> AXMenuBarExtraPayload {
    if app.bundleID.caseInsensitiveCompare("com.example.OKDiskDev") == .orderedSame {
      return AXMenuBarExtraPayload(
        appName: app.appName,
        bundleID: app.bundleID,
        pid: app.pid,
        title: nil,
        label: "OKDisk Idle",
        identifier: "okdisk.menu.icon",
        description: "OKDisk Idle",
        enabled: true,
        frame: CaptureRect(x: 1200, y: 0, width: 24, height: 24)
      )
    }

    return AXMenuBarExtraPayload(
      appName: app.appName,
      bundleID: app.bundleID,
      pid: app.pid,
      title: "VPN",
      label: "Acme VPN",
      identifier: "com.example.status-owner.vpn",
      description: "Acme VPN status menu",
      enabled: true,
      frame: CaptureRect(x: 1200, y: 0, width: 24, height: 24)
    )
  }
}

final class RecordingMenuService: AppMenuServicing, @unchecked Sendable {
  private let lock = NSLock()
  private var storedListAppNames: [String?] = []
  private var storedClickAppNames: [String?] = []
  private var storedClickPaths: [[String]] = []

  var listAppNames: [String?] {
    lock.lock(); defer { lock.unlock() }
    return storedListAppNames
  }

  var clickAppNames: [String?] {
    lock.lock(); defer { lock.unlock() }
    return storedClickAppNames
  }

  var clickPaths: [[String]] {
    lock.lock(); defer { lock.unlock() }
    return storedClickPaths
  }

  func listMenuItems(appName: String?) throws -> AXAppMenuListPayload {
    lock.lock()
    storedListAppNames.append(appName)
    lock.unlock()
    return AXAppMenuListPayload(
      appName: appName ?? "TextEdit",
      items: [
        AXAppMenuItemPayload(title: "File", enabled: true, hasSubmenu: true, path: ["File"]),
        AXAppMenuItemPayload(title: "Edit", enabled: true, hasSubmenu: true, path: ["Edit"]),
        AXAppMenuItemPayload(title: "View", enabled: false, hasSubmenu: true, path: ["View"])
      ]
    )
  }

  func clickMenuItem(appName: String?, path: [String]) throws -> AXMenuActionPayload {
    if path.last == "Missing" {
      throw AgentProtocolError.elementNotFound("Menu item 'Missing' not found")
    }
    lock.lock()
    storedClickAppNames.append(appName)
    storedClickPaths.append(path)
    lock.unlock()
    return AXMenuActionPayload(
      action: "ax.menu-navigate",
      appName: appName ?? "TextEdit",
      path: path,
      item: AXElementNode(
        role: "AXMenuItem", subrole: nil, title: path.last, label: nil, identifier: nil,
        value: nil, valueTruncated: nil, frame: nil, enabled: true, focused: false, children: nil
      )
    )
  }
}

final class RecordingWindowService: WindowServicing, @unchecked Sendable {
  struct RecordedAction: Equatable {
    let action: String
    let appName: String
    let title: String?
  }

  struct RecordedFrameRequest: Equatable {
    let appName: String
    let title: String?
  }

  private let lock = NSLock()
  private var storedListAppNames: [String?] = []
  private var storedActions: [RecordedAction] = []
  private var storedFrameRequests: [RecordedFrameRequest] = []

  var listAppNames: [String?] {
    lock.lock(); defer { lock.unlock() }
    return storedListAppNames
  }

  var actions: [RecordedAction] {
    lock.lock(); defer { lock.unlock() }
    return storedActions
  }

  var frameRequests: [RecordedFrameRequest] {
    lock.lock(); defer { lock.unlock() }
    return storedFrameRequests
  }

  func listWindows(appName: String?) throws -> AXWindowCatalogPayload {
    lock.lock()
    storedListAppNames.append(appName)
    lock.unlock()
    return AXWindowCatalogPayload(windows: [
      AXWindowCatalogItemPayload(
        appName: appName ?? "TextEdit",
        bundleID: "com.apple.TextEdit",
        pid: 4242,
        index: 0,
        title: "Untitled",
        role: "AXWindow",
        subrole: "AXStandardWindow",
        frame: CaptureRect(x: 10, y: 10, width: 400, height: 300),
        main: true
      )
    ])
  }

  func windowFrame(appName: String, title: String?) throws -> AXWindowFramePayload {
    if title == "Missing" {
      throw AgentProtocolError.elementNotFound("No window matches 'Missing' in \(appName). Windows: [0] Untitled")
    }
    lock.lock()
    storedFrameRequests.append(RecordedFrameRequest(appName: appName, title: title))
    lock.unlock()
    return AXWindowFramePayload(
      appName: appName,
      bundleID: "com.apple.TextEdit",
      pid: 4242,
      index: 0,
      title: title ?? "Untitled",
      frame: CaptureRect(x: 120, y: 80, width: 1200, height: 800)
    )
  }

  func closeWindow(appName: String, title: String?) throws -> AXWindowActionPayload {
    try record("window.close", appName: appName, title: title)
  }

  func minimizeWindow(appName: String, title: String?) throws -> AXWindowActionPayload {
    try record("window.minimize", appName: appName, title: title)
  }

  func zoomWindow(appName: String, title: String?) throws -> AXWindowActionPayload {
    try record("window.zoom", appName: appName, title: title)
  }

  func raiseWindow(appName: String, title: String?) throws -> AXWindowActionPayload {
    try record("window.raise", appName: appName, title: title)
  }

  private func record(_ action: String, appName: String, title: String?) throws -> AXWindowActionPayload {
    if title == "Missing" {
      throw AgentProtocolError.elementNotFound("No window matches 'Missing'")
    }
    lock.lock()
    storedActions.append(RecordedAction(action: action, appName: appName, title: title))
    lock.unlock()
    return AXWindowActionPayload(
      action: action,
      appName: appName,
      bundleID: "com.apple.TextEdit",
      pid: 4242,
      index: 0,
      title: title ?? "Untitled"
    )
  }
}

struct FakeApplicationResolver: ApplicationResolving, RunningApplicationNameResolving {
  let runningByBundleID: [String: ApplicationDescriptor]
  let resolvableByBundleID: [String: ApplicationDescriptor]
  let nameResolutions: [String: ApplicationNameResolution]

  init(
    running: [ApplicationDescriptor] = [],
    installed: [ApplicationDescriptor] = [],
    names: [String: ApplicationNameResolution] = [:]
  ) {
    runningByBundleID = Dictionary(uniqueKeysWithValues: running.map { ($0.bundleID.lowercased(), $0) })
    var resolvable = Dictionary(uniqueKeysWithValues: installed.map { ($0.bundleID.lowercased(), $0) })
    for app in running {
      resolvable[app.bundleID.lowercased()] = app
    }
    resolvableByBundleID = resolvable
    nameResolutions = Dictionary(uniqueKeysWithValues: names.map { ($0.key.lowercased(), $0.value) })
  }

  func resolveApplication(bundleID: String) -> ApplicationDescriptor? {
    resolvableByBundleID[bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
  }

  func runningApplication(bundleID: String) -> ApplicationDescriptor? {
    runningByBundleID[bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
  }

  func resolveApplication(named name: String) -> ApplicationNameResolution {
    nameResolutions[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? .notFound
  }

  func resolveRunningApplication(named name: String) -> ApplicationNameResolution {
    resolveUniqueRunningApplication(named: name, in: Array(runningByBundleID.values))
  }
}

struct VerifierReadFunction: MacOSFunction {
  let name = "test.read"
  let summary = "Verifier read function"
  let tier: FunctionTier = .read
  let argSchema = [FunctionArg(name: "message", type: .string, required: true, description: "Message")]
  let catalogTargetBundleID: String? = nil

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(
      args: try validateFunctionArgs(args, schema: argSchema),
      permissionTarget: GlobalPermissionCategory.power.permissionTarget
    )
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    FunctionResult(value: .object("message", plan.args["message"]))
  }
}

struct VerifierWriteFunction: MacOSFunction {
  let name = "test.write"
  let summary = "Verifier write function"
  let tier: FunctionTier = .write
  let argSchema: [FunctionArg] = []
  let catalogTargetBundleID: String? = "com.example.TestApp"

  func makeExecutionPlan(args: [String: JSONValue]) throws -> FunctionExecutionPlan {
    FunctionExecutionPlan(
      args: try validateFunctionArgs(args, schema: argSchema),
      target: FunctionTarget(bundleID: "com.example.TestApp", appName: "Test App", requiresAutomation: false)
    )
  }

  func run(plan: FunctionExecutionPlan) throws -> FunctionResult {
    FunctionResult(value: .object("ran", .bool(true)))
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
  let details: JSONValue?
}

struct EmptyPayload: Decodable {}

@main
struct ProtocolVerifier {
  static func main() {
    do {
      try runProtocolVerifier()
      try runSocketVerifier()
      print("Protocol verifier passed")
    } catch let error as AgentProtocolError {
      FileHandle.standardError.write(Data("FAIL [\(error.code)]: \(error.message) details=\(String(describing: error.details))\n".utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
