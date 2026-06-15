import Foundation

public enum FileEditingMode: String, Codable, Equatable, Hashable, Sendable {
  case disabled
  case readOnly = "read-only"
  case readWrite = "read-write"

  public var canRead: Bool {
    self == .readOnly || self == .readWrite
  }

  public var canWrite: Bool {
    self == .readWrite
  }
}

public struct FileEditingAllowedRoot: Codable, Equatable, Identifiable, Sendable {
  public var id: String {
    path
  }

  public let path: String
  public let mode: FileEditingMode

  public init(path: String, mode: FileEditingMode = .readWrite) {
    self.path = path
    self.mode = mode
  }
}

public struct FileEditingLimits: Codable, Equatable, Sendable {
  public let maxReadBytes: Int
  public let maxWriteBytes: Int
  public let maxSearchResults: Int
  public let maxListEntries: Int

  public init(
    maxReadBytes: Int = 1 * 1024 * 1024,
    maxWriteBytes: Int = 5 * 1024 * 1024,
    maxSearchResults: Int = 200,
    maxListEntries: Int = 1000
  ) {
    self.maxReadBytes = maxReadBytes
    self.maxWriteBytes = maxWriteBytes
    self.maxSearchResults = maxSearchResults
    self.maxListEntries = maxListEntries
  }
}

public struct FileEditingConfiguration: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let mode: FileEditingMode
  public let allowedRoots: [FileEditingAllowedRoot]
  public let limits: FileEditingLimits

  public init(
    enabled: Bool = false,
    mode: FileEditingMode = .disabled,
    allowedRoots: [FileEditingAllowedRoot] = [],
    limits: FileEditingLimits = FileEditingLimits()
  ) {
    let effectiveEnabled = enabled && mode != .disabled
    self.enabled = effectiveEnabled
    self.mode = effectiveEnabled ? mode : .disabled
    self.allowedRoots = allowedRoots
    self.limits = limits
  }

  public static let disabled = FileEditingConfiguration()

  public static func toggleEnabled(
    _ enabled: Bool,
    allowedRoots: [FileEditingAllowedRoot] = [],
    limits: FileEditingLimits = FileEditingLimits()
  ) -> FileEditingConfiguration {
    FileEditingConfiguration(
      enabled: enabled,
      mode: enabled ? .readWrite : .disabled,
      allowedRoots: allowedRoots,
      limits: limits
    )
  }
}

public struct AgentConfiguration: Equatable, Sendable {
  public static let protocolName = "okbrain.macos-agent.v3"
  public static let supportedProtocolVersions = [protocolName]
  public static let defaultSocketPath = "/tmp/okbrain-macos-agent.sock"
  public static let defaultDevSocketPath = "/tmp/okbrain-macos-agent-dev.sock"
  public static let defaultVersion = "2.0.0"

  public let socketPath: String
  public let version: String
  public let build: String
  public let appEnvironment: String
  public let stateDirectoryName: String
  public let maxScreenshotBytes: Int
  public let maxRequestBytes: Int
  public let fileEditing: FileEditingConfiguration

  public init(
    socketPath: String = AgentConfiguration.defaultSocketPath,
    version: String = AgentConfiguration.defaultVersion,
    build: String = "dev",
    appEnvironment: String = "prod",
    stateDirectoryName: String = ".okbrain-macos-agent",
    maxScreenshotBytes: Int = 64 * 1024 * 1024,
    maxRequestBytes: Int = 6 * 1024 * 1024,
    fileEditing: FileEditingConfiguration = .disabled
  ) {
    self.socketPath = socketPath
    self.version = version
    self.build = build
    self.appEnvironment = appEnvironment
    self.stateDirectoryName = stateDirectoryName
    self.maxScreenshotBytes = maxScreenshotBytes
    self.maxRequestBytes = maxRequestBytes
    self.fileEditing = fileEditing
  }

  public static func current(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main,
    fileEditingEnabled: Bool = false,
    filePermissionRules: [FileEditingAllowedRoot] = []
  ) -> AgentConfiguration {
    let info = bundle.infoDictionary ?? [:]
    let appEnvironment = normalizedAppEnvironment(info["AppEnvironment"] as? String, bundleIdentifier: bundle.bundleIdentifier)
    let stateDirectoryName = normalizedStateDirectoryName(
      info["AppStateDirectoryName"] as? String,
      appEnvironment: appEnvironment
    )

    let configuredSocketPath = environment["MACOS_AGENT_SOCKET_PATH"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let channelDefaultSocketPath = appEnvironment == "dev" ? defaultDevSocketPath : defaultSocketPath
    let socketPath = configuredSocketPath?.isEmpty == false ? configuredSocketPath! : channelDefaultSocketPath

    let version = info["CFBundleShortVersionString"] as? String ?? defaultVersion
    let build = info["CFBundleVersion"] as? String ?? "dev"

    let limits = FileEditingLimits(
      maxReadBytes: positiveInt(environment["MACOS_AGENT_MAX_READ_BYTES"]) ?? 1 * 1024 * 1024,
      maxWriteBytes: positiveInt(environment["MACOS_AGENT_MAX_WRITE_BYTES"]) ?? 5 * 1024 * 1024,
      maxSearchResults: positiveInt(environment["MACOS_AGENT_MAX_SEARCH_RESULTS"]) ?? 200,
      maxListEntries: positiveInt(environment["MACOS_AGENT_MAX_LIST_ENTRIES"]) ?? 1000
    )

    let fileEditing = FileEditingConfiguration.toggleEnabled(
      fileEditingEnabled,
      allowedRoots: filePermissionRules,
      limits: limits
    )
    let minimumRequestBytes = fileEditing.enabled ? fileEditing.limits.maxWriteBytes + 1024 * 1024 : 64 * 1024
    let maxRequestBytes = positiveInt(environment["MACOS_AGENT_MAX_REQUEST_BYTES"]) ?? max(6 * 1024 * 1024, minimumRequestBytes)

    return AgentConfiguration(
      socketPath: socketPath,
      version: version,
      build: build,
      appEnvironment: appEnvironment,
      stateDirectoryName: stateDirectoryName,
      maxRequestBytes: maxRequestBytes,
      fileEditing: fileEditing
    )
  }

  public func withFileEditingEnabled(_ enabled: Bool) -> AgentConfiguration {
    withFileEditingSettings(enabled: enabled, allowedRoots: fileEditing.allowedRoots)
  }

  public func withFileEditingSettings(
    enabled: Bool,
    allowedRoots: [FileEditingAllowedRoot]
  ) -> AgentConfiguration {
    let nextFileEditing = FileEditingConfiguration.toggleEnabled(
      enabled,
      allowedRoots: allowedRoots,
      limits: fileEditing.limits
    )
    let minimumRequestBytes = nextFileEditing.enabled ? nextFileEditing.limits.maxWriteBytes + 1024 * 1024 : 64 * 1024

    return AgentConfiguration(
      socketPath: socketPath,
      version: version,
      build: build,
      appEnvironment: appEnvironment,
      stateDirectoryName: stateDirectoryName,
      maxScreenshotBytes: maxScreenshotBytes,
      maxRequestBytes: max(maxRequestBytes, minimumRequestBytes),
      fileEditing: nextFileEditing
    )
  }

  private static func normalizedAppEnvironment(_ raw: String?, bundleIdentifier: String?) -> String {
    let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value == "dev" || bundleIdentifier?.hasSuffix(".dev") == true {
      return "dev"
    }
    return "prod"
  }

  private static func normalizedStateDirectoryName(_ raw: String?, appEnvironment: String) -> String {
    let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value, !value.isEmpty {
      return value
    }
    return appEnvironment == "dev" ? ".okbrain-macos-agent-dev" : ".okbrain-macos-agent"
  }

  private static func positiveInt(_ raw: String?) -> Int? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
          let value = Int(raw), value > 0 else {
      return nil
    }
    return value
  }
}