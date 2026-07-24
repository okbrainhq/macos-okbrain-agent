import Foundation

public protocol ScreenshotCapturing: Sendable {
  func capture(_ params: AgentRequestParams) throws -> CapturedImage
}

public final class AgentRequestHandler: @unchecked Sendable {
  private let configuration: AgentConfiguration
  private let permissions: PermissionChecking
  private let screenshots: ScreenshotCapturing
  private let fileEditing: FileEditingServicing
  private let accessibility: AccessibilityServicing
  private let osascript: OsascriptServicing
  private let remoteControlEnabled: @Sendable () -> Bool
  private let makeDisplayWake: @Sendable (TimeInterval) -> (any DisplayWaking)?

  private let envelopeActions: Set<String> = [
    "agent.status",
    "agent.info",
    "permissions.status",
    "screenshot.capture"
  ]

  private let fileActions: Set<String> = [
    "workspace.describe",
    "fs.stat",
    "fs.list",
    "fs.read",
    "fs.write",
    "fs.patch",
    "fs.search"
  ]

  private let accessibilityActions: Set<String> = [
    "ax.list-apps",
    "ax.list-windows",
    "ax.get-tree",
    "ax.find",
    "ax.perform",
    "ax.get-value",
    "ax.set-value",
    "ax.type-text",
    "ax.key-press",
    "ax.click-at",
    "ax.scroll"
  ]

  private let osascriptActions: Set<String> = [
    "osascript.run"
  ]

  public init(
    configuration: AgentConfiguration,
    permissions: PermissionChecking = SystemPermissionService(),
    screenshots: ScreenshotCapturing = ScreenCaptureKitScreenshotService(),
    fileEditing: FileEditingServicing? = nil,
    accessibility: AccessibilityServicing = SystemAccessibilityService(),
    osascript: OsascriptServicing = SystemOsascriptService(),
    remoteControlEnabled: (@Sendable () -> Bool)? = nil,
    displayWakeFactory: (@Sendable (TimeInterval) -> (any DisplayWaking)?)? = nil
  ) {
    self.configuration = configuration
    self.permissions = permissions
    self.screenshots = screenshots
    self.fileEditing = fileEditing ?? LocalFileEditingService(configuration: configuration.fileEditing)
    self.accessibility = accessibility
    self.osascript = osascript
    self.remoteControlEnabled = remoteControlEnabled ?? { true }
    self.makeDisplayWake = displayWakeFactory ?? { settleDelay in DisplayWakeGuard(settleDelay: settleDelay) }
  }

  public func handle(requestData: Data) -> Data {
    var responseID = "unknown"
    var responseProtocol = AgentConfiguration.protocolName

    do {
      guard !requestData.isEmpty else {
        throw AgentProtocolError.invalidRequest("Request frame header must contain a JSON object")
      }

      let request = try JSONDecoder().decode(AgentRequest.self, from: requestData)
      let requestID = normalizedID(request.id)
      responseID = requestID
      let action = request.action.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !action.isEmpty else {
        throw AgentProtocolError.invalidRequest("Request action is required")
      }

      guard envelopeActions.contains(action) || fileActions.contains(action) || accessibilityActions.contains(action) || osascriptActions.contains(action) else {
        throw AgentProtocolError.unsupportedAction("Unsupported action: \(action)")
      }

      guard let protocolName = request.protocolName,
            AgentConfiguration.supportedProtocolVersions.contains(protocolName) else {
        throw AgentProtocolError.protocolMismatch("Expected protocol \(AgentConfiguration.protocolName)")
      }
      responseProtocol = protocolName

      // Single kill-switch for every remote-control surface: Accessibility
      // (ax.*) and AppleScript (osascript.run).
      if (accessibilityActions.contains(action) || osascriptActions.contains(action)), !remoteControlEnabled() {
        throw AgentProtocolError.invalidRequest("Remote control APIs (Accessibility ax.* and AppleScript osascript.run) are disabled in the agent's settings")
      }

      // Wake the display for accessibility and AppleScript commands so AX
      // queries, synthetic input events, and osascript-driven UI automation
      // work even when the display has gone to sleep.
      // No-op (no delay) when the display is already awake.
      var displayWake: (any DisplayWaking)?
      if accessibilityActions.contains(action) || osascriptActions.contains(action) {
        displayWake = makeDisplayWake(0.5)
      }
      defer { displayWake?.release() }

      switch action {
      case "agent.status":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: statusPayload())
      case "permissions.status":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: permissionsWithFileAccess())
      case "agent.info":
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: infoPayload())
      case "screenshot.capture":
        return try capture(
          protocolName: responseProtocol,
          id: requestID,
          params: request.params ?? AgentRequestParams(mode: "full", format: "webp", quality: 80)
        )
      case "workspace.describe":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.describeWorkspace(request.params ?? AgentRequestParams())
        )
      case "fs.stat":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.stat(request.params ?? AgentRequestParams())
        )
      case "fs.list":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.list(request.params ?? AgentRequestParams())
        )
      case "fs.read":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.read(request.params ?? AgentRequestParams())
        )
      case "fs.write":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.write(request.params ?? AgentRequestParams())
        )
      case "fs.patch":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.patch(request.params ?? AgentRequestParams())
        )
      case "fs.search":
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: fileEditing.search(request.params ?? AgentRequestParams())
        )
      case "ax.list-apps":
        try requireAccessibility()
        return try encodeSuccess(protocolName: responseProtocol, id: requestID, data: accessibility.listApps())
      case "ax.list-windows":
        try requireAccessibility()
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: accessibility.listWindows(query: axQuery(request.params))
        )
      case "ax.get-tree":
        try requireAccessibility()
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: accessibility.tree(query: axQuery(request.params))
        )
      case "ax.find":
        try requireAccessibility()
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: accessibility.find(query: axQuery(request.params, defaultDepth: 30), limit: request.params?.maxResults ?? 20)
        )
      case "ax.perform":
        try requireAccessibility()
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: accessibility.perform(query: axQuery(request.params, defaultDepth: 30), action: request.params?.action ?? "press")
        )
      case "ax.get-value":
        try requireAccessibility()
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: accessibility.value(query: axQuery(request.params, defaultDepth: 30))
        )
      case "ax.set-value":
        try requireAccessibility()
        guard let value = request.params?.value else {
          throw AgentProtocolError.invalidRequest("value is required for ax.set-value")
        }
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: accessibility.setValue(query: axQuery(request.params, defaultDepth: 30), value: value)
        )
      case "ax.type-text":
        try requireAccessibility()
        guard let text = request.params?.text, !text.isEmpty else {
          throw AgentProtocolError.invalidRequest("text is required for ax.type-text")
        }
        try accessibility.typeText(text)
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: AXSimpleResultPayload(action: "ax.type-text", detail: "Typed \(text.count) characters")
        )
      case "ax.key-press":
        try requireAccessibility()
        guard let key = request.params?.key, !key.isEmpty else {
          throw AgentProtocolError.invalidRequest("key is required for ax.key-press")
        }
        try accessibility.keyPress(key: key, modifiers: request.params?.modifiers ?? [])
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: AXSimpleResultPayload(
            action: "ax.key-press",
            detail: "Pressed \((request.params?.modifiers ?? []).joined(separator: "+"))\(request.params?.modifiers?.isEmpty == false ? "+" : "")\(key)"
          )
        )
      case "ax.click-at":
        try requireAccessibility()
        guard let x = request.params?.x, let y = request.params?.y else {
          throw AgentProtocolError.invalidRequest("x and y are required for ax.click-at")
        }
        try accessibility.clickAt(x: x, y: y, button: request.params?.button ?? "left", clickCount: request.params?.clickCount ?? 1)
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: AXSimpleResultPayload(action: "ax.click-at", detail: "Clicked at (\(x), \(y))")
        )
      case "ax.scroll":
        try requireAccessibility()
        try accessibility.scroll(
          query: axQuery(request.params, defaultDepth: 30),
          deltaX: request.params?.deltaX ?? 0,
          deltaY: request.params?.deltaY ?? 0,
          x: request.params?.x,
          y: request.params?.y
        )
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: AXSimpleResultPayload(
            action: "ax.scroll",
            detail: "Scrolled by (\(request.params?.deltaX ?? 0), \(request.params?.deltaY ?? 0))"
          )
        )
      case "osascript.run":
        guard let script = request.params?.script, !script.isEmpty else {
          throw AgentProtocolError.invalidRequest("script is required for osascript.run")
        }
        return try encodeSuccess(
          protocolName: responseProtocol,
          id: requestID,
          data: osascript.run(
            script: script,
            language: request.params?.language ?? "applescript",
            timeout: request.params?.timeout ?? 0
          )
        )
      default:
        throw AgentProtocolError.unsupportedAction("Unsupported action: \(action)")
      }
    } catch let error as AgentProtocolError {
      return errorResponseData(protocolName: responseProtocol, id: responseID, error: error)
    } catch {
      return errorResponseData(
        protocolName: responseProtocol,
        id: responseID,
        error: .invalidRequest("Unable to decode request JSON: \(error.localizedDescription)")
      )
    }
  }

  public func errorResponseData(id: String, error: AgentProtocolError) -> Data {
    errorResponseData(protocolName: AgentConfiguration.protocolName, id: id, error: error)
  }

  private func errorResponseData(protocolName: String, id: String, error: AgentProtocolError) -> Data {
    do {
      let headerData = try JSONEncoder().encode(ErrorEnvelope(
        protocolName: protocolName,
        id: id,
        error: ErrorPayload(code: error.code, message: error.message)
      ))
      return try AgentBinaryFrame.encode(headerData: headerData)
    } catch {
      let fallback = "{\"protocol\":\"\(protocolName)\",\"id\":\"unknown\",\"ok\":false,\"error\":{\"code\":\"encode_failed\",\"message\":\"Unable to encode response\"}}"
      let headerData = Data(fallback.utf8)
      return (try? AgentBinaryFrame.encode(headerData: headerData)) ?? headerData
    }
  }

  private func capture(protocolName: String, id: String, params: AgentRequestParams) throws -> Data {
    let currentPermissions = permissions.currentPermissions()
    guard currentPermissions.screenRecording == .granted else {
      throw AgentProtocolError.permissionDenied("Screen Recording permission is not granted")
    }

    let image = try screenshots.capture(params)
    guard image.data.count <= configuration.maxScreenshotBytes else {
      throw AgentProtocolError.responseTooLarge(image.data.count)
    }

    return try encodeSuccess(
      protocolName: protocolName,
      id: id,
      data: ScreenshotCapturePayload(image: image),
      bodyData: image.data
    )
  }

  private func requireAccessibility() throws {
    guard permissions.currentPermissions().accessibility == .granted else {
      throw AgentProtocolError.permissionDenied("Accessibility permission is not granted")
    }
  }

  private func axQuery(_ params: AgentRequestParams?, defaultDepth: Int = 10) -> AXElementQuery {
    AXElementQuery(
      appName: params?.appName,
      pid: params?.pid,
      windowTitle: params?.windowTitle,
      windowIndex: params?.windowIndex,
      role: params?.role,
      title: params?.title,
      label: params?.label,
      identifier: params?.identifier,
      valueContains: params?.valueContains,
      index: params?.index ?? 0,
      maxDepth: params?.depth ?? defaultDepth,
      maxElements: params?.maxElements ?? 500,
      allWindows: params?.allWindows ?? false,
      scope: params?.scope
    )
  }

  private func statusPayload() -> AgentStatusPayload {
    let currentPermissions = permissionsWithFileAccess()
    var capabilities = [
      "screenshot.full",
      "screenshot.window",
      "screenshot.region",
      "screenshot.cursor",
      "screenshot.webp",
      "screenshot.binary",
      "osascript.run"
    ]

    if configuration.fileEditing.enabled {
      capabilities.append(contentsOf: [
        "workspace.describe",
        "fs.stat",
        "fs.list",
        "fs.read",
        "fs.write",
        "fs.patch",
        "fs.search"
      ])
    }

    if currentPermissions.accessibility == .granted {
      capabilities.append(contentsOf: [
        "ax.list-apps",
        "ax.list-windows",
        "ax.get-tree",
        "ax.find",
        "ax.perform",
        "ax.get-value",
        "ax.set-value",
        "ax.type-text",
        "ax.key-press",
        "ax.click-at",
        "ax.scroll"
      ])
    }

    return AgentStatusPayload(
      installed: true,
      running: true,
      available: currentPermissions.screenRecording == .granted
        || currentPermissions.accessibility == .granted
        || configuration.fileEditing.enabled,
      version: configuration.version,
      socketPath: configuration.socketPath,
      permissions: currentPermissions,
      capabilities: capabilities,
      protocolVersions: AgentConfiguration.supportedProtocolVersions,
      fileEditing: FileEditingStatusPayload(configuration: configuration.fileEditing)
    )
  }

  private func permissionsWithFileAccess() -> AgentPermissionsPayload {
    let current = permissions.currentPermissions()
    return AgentPermissionsPayload(
      screenRecording: current.screenRecording,
      accessibility: current.accessibility,
      fileAccess: configuration.fileEditing.enabled ? .granted : .unknown
    )
  }

  private func infoPayload() -> AgentInfoPayload {
    AgentInfoPayload(
      version: configuration.version,
      build: configuration.build,
      protocolName: AgentConfiguration.protocolName,
      socketPath: configuration.socketPath,
      transport: "ssh-unix-socket-binary-frame",
      protocolVersions: AgentConfiguration.supportedProtocolVersions
    )
  }

  private func normalizedID(_ id: String?) -> String {
    let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedID?.isEmpty == false ? trimmedID! : "req_\(UUID().uuidString)"
  }

  private func encodeSuccess<T: Encodable>(
    protocolName: String,
    id: String,
    data: T,
    bodyData: Data = Data()
  ) throws -> Data {
    let headerData = try JSONEncoder().encode(SuccessEnvelope(
      protocolName: protocolName,
      id: id,
      data: data
    ))
    return try AgentBinaryFrame.encode(headerData: headerData, bodyData: bodyData)
  }
}

private struct SuccessEnvelope<T: Encodable>: Encodable {
  let protocolName: String
  let id: String
  let ok = true
  let data: T

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case ok
    case data
  }
}

private struct ErrorEnvelope: Encodable {
  let protocolName: String
  let id: String
  let ok = false
  let error: ErrorPayload

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case ok
    case error
  }
}

private struct ErrorPayload: Encodable {
  let code: String
  let message: String
}
