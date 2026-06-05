import Foundation

public enum FileEditingMode: String, Codable, Equatable, Sendable {
  case disabled
  case readOnly = "read-only"
  case readWrite = "read-write"

  public var canWrite: Bool {
    self == .readWrite
  }
}

public struct FileEditingAllowedRoot: Codable, Equatable, Sendable {
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
    let effectiveEnabled = enabled && mode != .disabled && !allowedRoots.isEmpty
    self.enabled = effectiveEnabled
    self.mode = effectiveEnabled ? mode : .disabled
    self.allowedRoots = effectiveEnabled ? allowedRoots : []
    self.limits = limits
  }

  public static let disabled = FileEditingConfiguration()
}

public struct AgentConfiguration: Equatable, Sendable {
  public static let protocolV1Name = "okbrain.macos-agent.v1"
  public static let protocolV2Name = "okbrain.macos-agent.v2"
  public static let protocolName = protocolV1Name
  public static let supportedProtocolVersions = [protocolV1Name, protocolV2Name]
  public static let defaultSocketPath = "/tmp/okbrain-macos-agent.sock"
  public static let defaultVersion = "2.0.0"

  public let socketPath: String
  public let version: String
  public let build: String
  public let maxScreenshotBytes: Int
  public let maxRequestBytes: Int
  public let fileEditing: FileEditingConfiguration

  public init(
    socketPath: String = AgentConfiguration.defaultSocketPath,
    version: String = AgentConfiguration.defaultVersion,
    build: String = "dev",
    maxScreenshotBytes: Int = 64 * 1024 * 1024,
    maxRequestBytes: Int = 6 * 1024 * 1024,
    fileEditing: FileEditingConfiguration = .disabled
  ) {
    self.socketPath = socketPath
    self.version = version
    self.build = build
    self.maxScreenshotBytes = maxScreenshotBytes
    self.maxRequestBytes = maxRequestBytes
    self.fileEditing = fileEditing
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

    let limits = FileEditingLimits(
      maxReadBytes: positiveInt(environment["MACOS_AGENT_MAX_READ_BYTES"]) ?? 1 * 1024 * 1024,
      maxWriteBytes: positiveInt(environment["MACOS_AGENT_MAX_WRITE_BYTES"]) ?? 5 * 1024 * 1024,
      maxSearchResults: positiveInt(environment["MACOS_AGENT_MAX_SEARCH_RESULTS"]) ?? 200,
      maxListEntries: positiveInt(environment["MACOS_AGENT_MAX_LIST_ENTRIES"]) ?? 1000
    )

    let requestedMode = fileEditingMode(environment["MACOS_AGENT_FILE_EDITING_MODE"])
    let defaultRootMode: FileEditingMode = requestedMode == .readOnly ? .readOnly : .readWrite
    let roots = parseAllowedRoots(
      environment["MACOS_AGENT_ALLOWED_ROOTS"] ?? environment["OKBRAIN_MACOS_AGENT_ALLOWED_ROOTS"],
      defaultMode: defaultRootMode
    )
    let effectiveMode = requestedMode ?? (roots.isEmpty ? .disabled : .readWrite)
    let cappedRoots = roots.map { root in
      FileEditingAllowedRoot(
        path: root.path,
        mode: effectiveMode == .readOnly ? .readOnly : root.mode
      )
    }

    let fileEditing = FileEditingConfiguration(
      enabled: effectiveMode != .disabled,
      mode: effectiveMode,
      allowedRoots: cappedRoots,
      limits: limits
    )

    let minimumRequestBytes = fileEditing.enabled ? fileEditing.limits.maxWriteBytes + 1024 * 1024 : 64 * 1024
    let maxRequestBytes = positiveInt(environment["MACOS_AGENT_MAX_REQUEST_BYTES"]) ?? max(6 * 1024 * 1024, minimumRequestBytes)

    return AgentConfiguration(
      socketPath: socketPath,
      version: version,
      build: build,
      maxRequestBytes: maxRequestBytes,
      fileEditing: fileEditing
    )
  }

  private static func positiveInt(_ raw: String?) -> Int? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
          let value = Int(raw), value > 0 else {
      return nil
    }
    return value
  }

  private static func fileEditingMode(_ raw: String?) -> FileEditingMode? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
      return nil
    }

    switch raw {
    case "disabled", "off", "false", "0", "none":
      return .disabled
    case "read-only", "readonly", "ro":
      return .readOnly
    case "read-write", "readwrite", "rw", "true", "1", "enabled", "on":
      return .readWrite
    default:
      return nil
    }
  }

  private static func parseAllowedRoots(_ raw: String?, defaultMode: FileEditingMode) -> [FileEditingAllowedRoot] {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return []
    }

    let separators = CharacterSet(charactersIn: "\n;")
    return raw
      .components(separatedBy: separators)
      .flatMap { chunk in chunk.components(separatedBy: ",") }
      .compactMap { entry -> FileEditingAllowedRoot? in
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          return nil
        }

        let pieces = trimmed.components(separatedBy: "|")
        let path = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
          return nil
        }

        let mode = pieces.count > 1 ? fileEditingMode(pieces[1]) ?? defaultMode : defaultMode
        guard mode != .disabled else {
          return nil
        }

        return FileEditingAllowedRoot(path: (path as NSString).expandingTildeInPath, mode: mode)
      }
  }
}
