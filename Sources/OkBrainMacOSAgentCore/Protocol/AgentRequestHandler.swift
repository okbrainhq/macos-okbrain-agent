import Foundation

public protocol ScreenshotCapturing: Sendable {
  func capture(_ params: AgentRequestParams) throws -> CapturedImage
}

public final class AgentRequestHandler: @unchecked Sendable {
  private let configuration: AgentConfiguration
  private let permissions: PermissionChecking
  private let screenshots: ScreenshotCapturing

  private let v1Actions: Set<String> = [
    "agent.status",
    "agent.info",
    "permissions.status",
    "screenshot.capture"
  ]

  private let legacyActions: Set<String> = [
    "ping",
    "capture_full",
    "capture_window",
    "capture_region"
  ]

  public init(
    configuration: AgentConfiguration,
    permissions: PermissionChecking = SystemPermissionService(),
    screenshots: ScreenshotCapturing = ScreenCaptureKitScreenshotService()
  ) {
    self.configuration = configuration
    self.permissions = permissions
    self.screenshots = screenshots
  }

  public func handle(requestData: Data) -> Data {
    var responseID = "unknown"

    do {
      guard !requestData.isEmpty else {
        throw AgentProtocolError.invalidRequest("Request must be a single newline-delimited JSON object")
      }

      let request = try JSONDecoder().decode(AgentRequest.self, from: requestData)
      let requestID = normalizedID(request.id)
      responseID = requestID
      let action = request.action.trimmingCharacters(in: .whitespacesAndNewlines)

      guard !action.isEmpty else {
        throw AgentProtocolError.invalidRequest("Request action is required")
      }

      if v1Actions.contains(action) {
        guard request.protocolName == AgentConfiguration.protocolName else {
          throw AgentProtocolError.protocolMismatch("Expected protocol \(AgentConfiguration.protocolName)")
        }
      } else if !legacyActions.contains(action) {
        throw AgentProtocolError.unsupportedAction("Unsupported action: \(action)")
      }

      switch action {
      case "agent.status":
        return try encodeSuccess(id: requestID, data: statusPayload())
      case "permissions.status":
        return try encodeSuccess(id: requestID, data: permissions.currentPermissions())
      case "agent.info":
        return try encodeSuccess(id: requestID, data: infoPayload())
      case "screenshot.capture":
        return try capture(id: requestID, params: request.params ?? AgentRequestParams(mode: "full", format: "png"))
      case "ping":
        return try encodeSuccess(id: requestID, data: PingPayload(pong: true, version: configuration.version))
      case "capture_full":
        return try capture(
          id: requestID,
          params: mergingLegacyMode("full", into: request.params)
        )
      case "capture_window":
        return try capture(
          id: requestID,
          params: mergingLegacyMode("window", into: request.params)
        )
      case "capture_region":
        return try capture(
          id: requestID,
          params: mergingLegacyMode("region", into: request.params)
        )
      default:
        throw AgentProtocolError.unsupportedAction("Unsupported action: \(action)")
      }
    } catch let error as AgentProtocolError {
      return errorResponseData(id: responseID, error: error)
    } catch {
      return errorResponseData(
        id: responseID,
        error: .invalidRequest("Unable to decode request JSON: \(error.localizedDescription)")
      )
    }
  }

  public func errorResponseData(id: String, error: AgentProtocolError) -> Data {
    do {
      return try JSONEncoder().encode(ErrorEnvelope(
        protocolName: AgentConfiguration.protocolName,
        id: id,
        error: ErrorPayload(code: error.code, message: error.message)
      ))
    } catch {
      return Data(
        #"{"protocol":"okbrain.macos-agent.v1","id":"unknown","ok":false,"error":{"code":"encode_failed","message":"Unable to encode response"}}"#.utf8
      )
    }
  }

  private func capture(id: String, params: AgentRequestParams) throws -> Data {
    let currentPermissions = permissions.currentPermissions()
    guard currentPermissions.screenRecording == .granted else {
      throw AgentProtocolError.permissionDenied("Screen Recording permission is not granted")
    }

    let image = try screenshots.capture(params)
    guard image.pngData.count <= configuration.maxScreenshotBytes else {
      throw AgentProtocolError.responseTooLarge(image.pngData.count)
    }

    return try encodeSuccess(id: id, data: ScreenshotCapturePayload(image: image))
  }

  private func statusPayload() -> AgentStatusPayload {
    let currentPermissions = permissions.currentPermissions()
    return AgentStatusPayload(
      installed: true,
      running: true,
      available: currentPermissions.screenRecording == .granted,
      version: configuration.version,
      socketPath: configuration.socketPath,
      permissions: currentPermissions,
      capabilities: [
        "screenshot.full",
        "screenshot.window",
        "screenshot.region",
        "screenshot.cursor"
      ]
    )
  }

  private func infoPayload() -> AgentInfoPayload {
    AgentInfoPayload(
      version: configuration.version,
      build: configuration.build,
      protocolName: AgentConfiguration.protocolName,
      socketPath: configuration.socketPath,
      transport: "ssh-unix-socket"
    )
  }

  private func mergingLegacyMode(_ mode: String, into params: AgentRequestParams?) -> AgentRequestParams {
    var next = params ?? AgentRequestParams()
    next.mode = mode
    next.format = next.format ?? "png"
    next.includeCursor = next.includeCursor ?? false
    return next
  }

  private func normalizedID(_ id: String?) -> String {
    let trimmedID = id?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedID?.isEmpty == false ? trimmedID! : "req_\(UUID().uuidString)"
  }

  private func encodeSuccess<T: Encodable>(id: String, data: T) throws -> Data {
    try JSONEncoder().encode(SuccessEnvelope(
      protocolName: AgentConfiguration.protocolName,
      id: id,
      data: data
    ))
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
