import Foundation

public struct AgentRequest: Codable, Equatable, Sendable {
  public let protocolName: String?
  public let id: String?
  public let action: String
  public let params: AgentRequestParams?

  public init(
    protocolName: String? = AgentConfiguration.protocolName,
    id: String? = UUID().uuidString,
    action: String,
    params: AgentRequestParams? = nil
  ) {
    self.protocolName = protocolName
    self.id = id
    self.action = action
    self.params = params
  }

  private enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case id
    case action
    case params
  }
}

public struct AgentRequestParams: Codable, Equatable, Sendable {
  public var mode: String?
  public var format: String?
  public var includeCursor: Bool?
  public var appName: String?
  public var windowId: UInt32?
  public var rect: CaptureRect?

  public init(
    mode: String? = nil,
    format: String? = nil,
    includeCursor: Bool? = nil,
    appName: String? = nil,
    windowId: UInt32? = nil,
    rect: CaptureRect? = nil
  ) {
    self.mode = mode
    self.format = format
    self.includeCursor = includeCursor
    self.appName = appName
    self.windowId = windowId
    self.rect = rect
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case format
    case includeCursor
    case appName
    case windowId
    case rect
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decodeIfPresent(String.self, forKey: .mode)
    format = try container.decodeIfPresent(String.self, forKey: .format)
    includeCursor = try container.decodeIfPresent(Bool.self, forKey: .includeCursor)
    appName = try container.decodeIfPresent(String.self, forKey: .appName)
    rect = try container.decodeIfPresent(CaptureRect.self, forKey: .rect)

    if let numericWindowID = try? container.decodeIfPresent(UInt32.self, forKey: .windowId) {
      windowId = numericWindowID
    } else if let signedWindowID = try? container.decodeIfPresent(Int.self, forKey: .windowId), signedWindowID >= 0 {
      windowId = UInt32(signedWindowID)
    } else if let stringWindowID = try? container.decodeIfPresent(String.self, forKey: .windowId),
              let parsedWindowID = UInt32(stringWindowID) {
      windowId = parsedWindowID
    } else {
      windowId = nil
    }
  }
}

public struct CaptureRect: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct CapturedImage: Equatable, Sendable {
  public let pngData: Data
  public let width: Int
  public let height: Int

  public init(pngData: Data, width: Int, height: Int) {
    self.pngData = pngData
    self.width = width
    self.height = height
  }
}

public struct ScreenshotCapturePayload: Codable, Equatable, Sendable {
  public let mimeType: String
  public let base64: String
  public let width: Int
  public let height: Int

  public init(image: CapturedImage) {
    mimeType = "image/png"
    base64 = image.pngData.base64EncodedString()
    width = image.width
    height = image.height
  }
}

public struct AgentStatusPayload: Codable, Equatable, Sendable {
  public let installed: Bool
  public let running: Bool
  public let available: Bool
  public let version: String
  public let socketPath: String
  public let permissions: AgentPermissionsPayload
  public let capabilities: [String]

  public init(
    installed: Bool,
    running: Bool,
    available: Bool,
    version: String,
    socketPath: String,
    permissions: AgentPermissionsPayload,
    capabilities: [String]
  ) {
    self.installed = installed
    self.running = running
    self.available = available
    self.version = version
    self.socketPath = socketPath
    self.permissions = permissions
    self.capabilities = capabilities
  }
}

public struct AgentInfoPayload: Codable, Equatable, Sendable {
  public let version: String
  public let build: String
  public let protocolName: String
  public let socketPath: String
  public let transport: String

  public init(
    version: String,
    build: String,
    protocolName: String,
    socketPath: String,
    transport: String
  ) {
    self.version = version
    self.build = build
    self.protocolName = protocolName
    self.socketPath = socketPath
    self.transport = transport
  }
}

public struct PingPayload: Codable, Equatable, Sendable {
  public let pong: Bool
  public let version: String

  public init(pong: Bool, version: String) {
    self.pong = pong
    self.version = version
  }
}
