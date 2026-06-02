import Foundation

public struct AgentConfiguration: Equatable, Sendable {
  public static let protocolName = "okbrain.macos-agent.v1"
  public static let defaultSocketPath = "/tmp/okbrain-macos-agent.sock"
  public static let defaultVersion = "1.0.0"

  public let socketPath: String
  public let version: String
  public let build: String
  public let maxScreenshotBytes: Int
  public let maxRequestBytes: Int

  public init(
    socketPath: String = AgentConfiguration.defaultSocketPath,
    version: String = AgentConfiguration.defaultVersion,
    build: String = "dev",
    maxScreenshotBytes: Int = 64 * 1024 * 1024,
    maxRequestBytes: Int = 64 * 1024
  ) {
    self.socketPath = socketPath
    self.version = version
    self.build = build
    self.maxScreenshotBytes = maxScreenshotBytes
    self.maxRequestBytes = maxRequestBytes
  }

  public static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
  ) -> AgentConfiguration {
    let configuredSocketPath = environment["MACOS_AGENT_SOCKET_PATH"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let socketPath = configuredSocketPath?.isEmpty == false ? configuredSocketPath! : defaultSocketPath

    let info = bundle.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? defaultVersion
    let build = info["CFBundleVersion"] as? String ?? "dev"

    return AgentConfiguration(socketPath: socketPath, version: version, build: build)
  }
}
