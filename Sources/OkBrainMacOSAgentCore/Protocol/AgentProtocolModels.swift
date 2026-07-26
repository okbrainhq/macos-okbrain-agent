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
  // Screenshot params
  public var mode: String?
  public var format: String?
  public var includeCursor: Bool?
  public var quality: Int?
  public var appName: String?
  public var windowId: UInt32?
  public var rect: CaptureRect?

  // File editing params
  public var path: String?
  public var recursive: Bool?
  public var glob: String?
  public var includeHidden: Bool?
  public var respectGitignore: Bool?
  public var limit: Int?
  public var startLine: Int?
  public var endLine: Int?
  public var maxBytes: Int?
  public var encoding: String?
  public var content: String?
  public var createDirs: Bool?
  public var expectedSha256: String?
  public var backup: Bool?
  public var edits: [FilePatchEdit]?
  public var whitespaceNormalizedFallback: Bool?
  public var dryRun: Bool?
  public var query: String?
  public var regex: Bool?
  public var maxResults: Int?

  // Accessibility params
  public var pid: Int32?
  public var windowTitle: String?
  public var windowIndex: Int?
  public var role: String?
  public var title: String?
  public var label: String?
  public var identifier: String?
  public var valueContains: String?
  public var index: Int?
  public var value: String?
  public var depth: Int?
  public var maxElements: Int?
  public var allWindows: Bool?
  public var scope: String?
  public var action: String?
  public var x: Double?
  public var y: Double?
  public var button: String?
  public var clickCount: Int?
  public var key: String?
  public var modifiers: [String]?
  public var text: String?
  public var deltaX: Int?
  public var deltaY: Int?
  public var targetPid: Int32?
  public var compact: Bool?
  public var toX: Double?
  public var toY: Double?

  // Curated macOS function params
  public var functionName: String?
  public var args: [String: JSONValue]?
  public var name: String?
  public var description: String?
  public var rationale: String?
  public var exampleScript: String?


  public init(
    mode: String? = nil,
    format: String? = nil,
    includeCursor: Bool? = nil,
    quality: Int? = nil,
    appName: String? = nil,
    windowId: UInt32? = nil,
    rect: CaptureRect? = nil,
    path: String? = nil,
    recursive: Bool? = nil,
    glob: String? = nil,
    includeHidden: Bool? = nil,
    respectGitignore: Bool? = nil,
    limit: Int? = nil,
    startLine: Int? = nil,
    endLine: Int? = nil,
    maxBytes: Int? = nil,
    encoding: String? = nil,
    content: String? = nil,
    createDirs: Bool? = nil,
    expectedSha256: String? = nil,
    backup: Bool? = nil,
    edits: [FilePatchEdit]? = nil,
    whitespaceNormalizedFallback: Bool? = nil,
    dryRun: Bool? = nil,
    query: String? = nil,
    regex: Bool? = nil,
    maxResults: Int? = nil,
    pid: Int32? = nil,
    windowTitle: String? = nil,
    windowIndex: Int? = nil,
    role: String? = nil,
    title: String? = nil,
    label: String? = nil,
    identifier: String? = nil,
    valueContains: String? = nil,
    index: Int? = nil,
    value: String? = nil,
    depth: Int? = nil,
    maxElements: Int? = nil,
    allWindows: Bool? = nil,
    scope: String? = nil,
    action: String? = nil,
    x: Double? = nil,
    y: Double? = nil,
    button: String? = nil,
    clickCount: Int? = nil,
    key: String? = nil,
    modifiers: [String]? = nil,
    text: String? = nil,
    deltaX: Int? = nil,
    deltaY: Int? = nil,
    targetPid: Int32? = nil,
    compact: Bool? = nil,
    toX: Double? = nil,
    toY: Double? = nil,
    functionName: String? = nil,
    args: [String: JSONValue]? = nil,
    name: String? = nil,
    description: String? = nil,
    rationale: String? = nil,
    exampleScript: String? = nil
  ) {
    self.mode = mode
    self.format = format
    self.includeCursor = includeCursor
    self.quality = quality
    self.appName = appName
    self.windowId = windowId
    self.rect = rect
    self.path = path
    self.recursive = recursive
    self.glob = glob
    self.includeHidden = includeHidden
    self.respectGitignore = respectGitignore
    self.limit = limit
    self.startLine = startLine
    self.endLine = endLine
    self.maxBytes = maxBytes
    self.encoding = encoding
    self.content = content
    self.createDirs = createDirs
    self.expectedSha256 = expectedSha256
    self.backup = backup
    self.edits = edits
    self.whitespaceNormalizedFallback = whitespaceNormalizedFallback
    self.dryRun = dryRun
    self.query = query
    self.regex = regex
    self.maxResults = maxResults
    self.pid = pid
    self.windowTitle = windowTitle
    self.windowIndex = windowIndex
    self.role = role
    self.title = title
    self.label = label
    self.identifier = identifier
    self.valueContains = valueContains
    self.index = index
    self.value = value
    self.depth = depth
    self.maxElements = maxElements
    self.allWindows = allWindows
    self.scope = scope
    self.action = action
    self.x = x
    self.y = y
    self.button = button
    self.clickCount = clickCount
    self.key = key
    self.modifiers = modifiers
    self.text = text
    self.deltaX = deltaX
    self.deltaY = deltaY
    self.targetPid = targetPid
    self.compact = compact
    self.toX = toX
    self.toY = toY
    self.functionName = functionName
    self.args = args
    self.name = name
    self.description = description
    self.rationale = rationale
    self.exampleScript = exampleScript
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case format
    case includeCursor
    case quality
    case appName
    case windowId
    case rect
    case path
    case recursive
    case glob
    case includeHidden
    case respectGitignore
    case limit
    case startLine
    case endLine
    case maxBytes
    case encoding
    case content
    case createDirs
    case expectedSha256
    case backup
    case edits
    case whitespaceNormalizedFallback
    case dryRun
    case query
    case regex
    case maxResults
    case pid
    case windowTitle
    case windowIndex
    case role
    case title
    case label
    case identifier
    case valueContains
    case index
    case value
    case depth
    case maxElements
    case allWindows
    case scope
    case action
    case x
    case y
    case button
    case clickCount
    case key
    case modifiers
    case text
    case deltaX
    case deltaY
    case targetPid
    case compact
    case toX
    case toY
    case functionName
    case args
    case name
    case description
    case rationale
    case exampleScript
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decodeIfPresent(String.self, forKey: .mode)
    format = try container.decodeIfPresent(String.self, forKey: .format)
    includeCursor = try container.decodeIfPresent(Bool.self, forKey: .includeCursor)
    quality = try container.decodeIfPresent(Int.self, forKey: .quality)
    appName = try container.decodeIfPresent(String.self, forKey: .appName)
    rect = try container.decodeIfPresent(CaptureRect.self, forKey: .rect)
    path = try container.decodeIfPresent(String.self, forKey: .path)
    recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive)
    glob = try container.decodeIfPresent(String.self, forKey: .glob)
    includeHidden = try container.decodeIfPresent(Bool.self, forKey: .includeHidden)
    respectGitignore = try container.decodeIfPresent(Bool.self, forKey: .respectGitignore)
    limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    startLine = try container.decodeIfPresent(Int.self, forKey: .startLine)
    endLine = try container.decodeIfPresent(Int.self, forKey: .endLine)
    maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes)
    encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
    content = try container.decodeIfPresent(String.self, forKey: .content)
    createDirs = try container.decodeIfPresent(Bool.self, forKey: .createDirs)
    expectedSha256 = try container.decodeIfPresent(String.self, forKey: .expectedSha256)
    backup = try container.decodeIfPresent(Bool.self, forKey: .backup)
    edits = try container.decodeIfPresent([FilePatchEdit].self, forKey: .edits)
    whitespaceNormalizedFallback = try container.decodeIfPresent(Bool.self, forKey: .whitespaceNormalizedFallback)
    dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun)
    query = try container.decodeIfPresent(String.self, forKey: .query)
    regex = try container.decodeIfPresent(Bool.self, forKey: .regex)
    maxResults = try container.decodeIfPresent(Int.self, forKey: .maxResults)
    pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
    windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
    windowIndex = try container.decodeIfPresent(Int.self, forKey: .windowIndex)
    role = try container.decodeIfPresent(String.self, forKey: .role)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
    valueContains = try container.decodeIfPresent(String.self, forKey: .valueContains)
    index = try container.decodeIfPresent(Int.self, forKey: .index)
    value = try container.decodeIfPresent(String.self, forKey: .value)
    depth = try container.decodeIfPresent(Int.self, forKey: .depth)
    maxElements = try container.decodeIfPresent(Int.self, forKey: .maxElements)
    allWindows = try container.decodeIfPresent(Bool.self, forKey: .allWindows)
    scope = try container.decodeIfPresent(String.self, forKey: .scope)
    action = try container.decodeIfPresent(String.self, forKey: .action)
    x = try container.decodeIfPresent(Double.self, forKey: .x)
    y = try container.decodeIfPresent(Double.self, forKey: .y)
    button = try container.decodeIfPresent(String.self, forKey: .button)
    clickCount = try container.decodeIfPresent(Int.self, forKey: .clickCount)
    key = try container.decodeIfPresent(String.self, forKey: .key)
    modifiers = try container.decodeIfPresent([String].self, forKey: .modifiers)
    text = try container.decodeIfPresent(String.self, forKey: .text)
    deltaX = try container.decodeIfPresent(Int.self, forKey: .deltaX)
    deltaY = try container.decodeIfPresent(Int.self, forKey: .deltaY)
    targetPid = try container.decodeIfPresent(Int32.self, forKey: .targetPid)
    compact = try container.decodeIfPresent(Bool.self, forKey: .compact)
    toX = try container.decodeIfPresent(Double.self, forKey: .toX)
    toY = try container.decodeIfPresent(Double.self, forKey: .toY)
    functionName = try container.decodeIfPresent(String.self, forKey: .functionName)
    args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    rationale = try container.decodeIfPresent(String.self, forKey: .rationale)
    exampleScript = try container.decodeIfPresent(String.self, forKey: .exampleScript)

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

public struct FilePatchEdit: Codable, Equatable, Sendable {
  public let oldText: String
  public let newText: String
  public let startLine: Int?

  public init(oldText: String, newText: String, startLine: Int? = nil) {
    self.oldText = oldText
    self.newText = newText
    self.startLine = startLine
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
  public let data: Data
  public let mimeType: String
  public let width: Int
  public let height: Int

  public init(data: Data, mimeType: String = "image/webp", width: Int, height: Int) {
    self.data = data
    self.mimeType = mimeType
    self.width = width
    self.height = height
  }
}

public struct ScreenshotCapturePayload: Codable, Equatable, Sendable {
  public let mimeType: String
  public let encoding: String
  public let byteLength: Int
  public let width: Int
  public let height: Int

  public init(image: CapturedImage) {
    mimeType = image.mimeType
    encoding = "binary"
    byteLength = image.data.count
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
  public let protocolVersions: [String]
  public let permissions: AgentPermissionsPayload
  public let capabilities: [String]
  public let fileEditing: FileEditingStatusPayload?

  public init(
    installed: Bool,
    running: Bool,
    available: Bool,
    version: String,
    socketPath: String,
    permissions: AgentPermissionsPayload,
    capabilities: [String],
    protocolVersions: [String] = AgentConfiguration.supportedProtocolVersions,
    fileEditing: FileEditingStatusPayload? = nil
  ) {
    self.installed = installed
    self.running = running
    self.available = available
    self.version = version
    self.socketPath = socketPath
    self.protocolVersions = protocolVersions
    self.permissions = permissions
    self.capabilities = capabilities
    self.fileEditing = fileEditing
  }
}

public struct AgentInfoPayload: Codable, Equatable, Sendable {
  public let version: String
  public let build: String
  public let protocolName: String
  public let protocolVersions: [String]
  public let socketPath: String
  public let transport: String

  public init(
    version: String,
    build: String,
    protocolName: String,
    socketPath: String,
    transport: String,
    protocolVersions: [String] = AgentConfiguration.supportedProtocolVersions
  ) {
    self.version = version
    self.build = build
    self.protocolName = protocolName
    self.protocolVersions = protocolVersions
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

public struct FileEditingStatusPayload: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let mode: FileEditingMode
  public let limits: FileEditingLimits

  public init(configuration: FileEditingConfiguration) {
    enabled = configuration.enabled
    mode = configuration.mode
    limits = configuration.limits
  }
}

public struct WorkspaceDescribePayload: Codable, Equatable, Sendable {
  public let root: String
  public let exists: Bool
  public let caseSensitive: Bool
  public let vcs: VCSInfoPayload?

  public init(root: String, exists: Bool, caseSensitive: Bool, vcs: VCSInfoPayload?) {
    self.root = root
    self.exists = exists
    self.caseSensitive = caseSensitive
    self.vcs = vcs
  }
}

public struct VCSInfoPayload: Codable, Equatable, Sendable {
  public let type: String
  public let root: String

  public init(type: String, root: String) {
    self.type = type
    self.root = root
  }
}

public struct FileStatPayload: Codable, Equatable, Sendable {
  public let path: String
  public let type: String
  public let size: Int64
  public let mtime: String
  public let sha256: String?
  public let isBinary: Bool?
  public let permissions: String

  public init(path: String, type: String, size: Int64, mtime: String, sha256: String?, isBinary: Bool?, permissions: String) {
    self.path = path
    self.type = type
    self.size = size
    self.mtime = mtime
    self.sha256 = sha256
    self.isBinary = isBinary
    self.permissions = permissions
  }
}

public struct FileListPayload: Codable, Equatable, Sendable {
  public let entries: [FileListEntryPayload]
  public let truncated: Bool

  public init(entries: [FileListEntryPayload], truncated: Bool) {
    self.entries = entries
    self.truncated = truncated
  }
}

public struct FileListEntryPayload: Codable, Equatable, Sendable {
  public let name: String
  public let path: String
  public let type: String
  public let size: Int64
  public let mtime: String

  public init(name: String, path: String, type: String, size: Int64, mtime: String) {
    self.name = name
    self.path = path
    self.type = type
    self.size = size
    self.mtime = mtime
  }
}

public struct FileReadPayload: Codable, Equatable, Sendable {
  public let path: String
  public let content: String
  public let encoding: String
  public let lineCount: Int
  public let range: FileReadRangePayload
  public let sha256: String
  public let truncated: Bool

  public init(
    path: String,
    content: String,
    encoding: String,
    lineCount: Int,
    range: FileReadRangePayload,
    sha256: String,
    truncated: Bool
  ) {
    self.path = path
    self.content = content
    self.encoding = encoding
    self.lineCount = lineCount
    self.range = range
    self.sha256 = sha256
    self.truncated = truncated
  }
}

public struct FileReadRangePayload: Codable, Equatable, Sendable {
  public let startLine: Int
  public let endLine: Int

  public init(startLine: Int, endLine: Int) {
    self.startLine = startLine
    self.endLine = endLine
  }
}

public struct FileWritePayload: Codable, Equatable, Sendable {
  public let path: String
  public let bytesWritten: Int
  public let previousSha256: String?
  public let sha256: String
  public let backupPath: String?

  public init(path: String, bytesWritten: Int, previousSha256: String?, sha256: String, backupPath: String?) {
    self.path = path
    self.bytesWritten = bytesWritten
    self.previousSha256 = previousSha256
    self.sha256 = sha256
    self.backupPath = backupPath
  }
}

public struct FilePatchPayload: Codable, Equatable, Sendable {
  public let path: String
  public let applied: Int
  public let previousSha256: String
  public let sha256: String
  public let changedLines: [Int]
  public let backupPath: String?
  public let warnings: [String]?

  public init(
    path: String,
    applied: Int,
    previousSha256: String,
    sha256: String,
    changedLines: [Int],
    backupPath: String?,
    warnings: [String]? = nil
  ) {
    self.path = path
    self.applied = applied
    self.previousSha256 = previousSha256
    self.sha256 = sha256
    self.changedLines = changedLines
    self.backupPath = backupPath
    self.warnings = warnings
  }
}

public struct FileSearchPayload: Codable, Equatable, Sendable {
  public let matches: [FileSearchMatchPayload]
  public let truncated: Bool

  public init(matches: [FileSearchMatchPayload], truncated: Bool) {
    self.matches = matches
    self.truncated = truncated
  }
}

public struct FileSearchMatchPayload: Codable, Equatable, Sendable {
  public let file: String
  public let line: Int
  public let text: String

  public init(file: String, line: Int, text: String) {
    self.file = file
    self.line = line
    self.text = text
  }
}
