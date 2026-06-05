import Foundation

public protocol ScreenshotCapturing: Sendable {
  func capture(_ params: AgentRequestParams) throws -> CapturedImage
}

public final class AgentRequestHandler: @unchecked Sendable {
  private let configuration: AgentConfiguration
  private let permissions: PermissionChecking
  private let screenshots: ScreenshotCapturing
  private let fileEditing: FileEditingServicing

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

  public init(
    configuration: AgentConfiguration,
    permissions: PermissionChecking = SystemPermissionService(),
    screenshots: ScreenshotCapturing = ScreenCaptureKitScreenshotService(),
    fileEditing: FileEditingServicing? = nil
  ) {
    self.configuration = configuration
    self.permissions = permissions
    self.screenshots = screenshots
    self.fileEditing = fileEditing ?? LocalFileEditingService(configuration: configuration.fileEditing)
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

      guard envelopeActions.contains(action) || fileActions.contains(action) else {
        throw AgentProtocolError.unsupportedAction("Unsupported action: \(action)")
      }

      guard let protocolName = request.protocolName,
            AgentConfiguration.supportedProtocolVersions.contains(protocolName) else {
        throw AgentProtocolError.protocolMismatch("Expected protocol \(AgentConfiguration.protocolName)")
      }
      responseProtocol = protocolName

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

  private func statusPayload() -> AgentStatusPayload {
    let currentPermissions = permissionsWithFileAccess()
    var capabilities = [
      "screenshot.full",
      "screenshot.window",
      "screenshot.region",
      "screenshot.cursor",
      "screenshot.webp",
      "screenshot.binary"
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

    return AgentStatusPayload(
      installed: true,
      running: true,
      available: currentPermissions.screenRecording == .granted || configuration.fileEditing.enabled,
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
