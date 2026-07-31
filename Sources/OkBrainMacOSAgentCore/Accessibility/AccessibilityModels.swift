import Foundation

/// A JSON-friendly accessibility attribute value.
public enum AXAttributeValue: Equatable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
}

extension AXAttributeValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let boolValue = try? container.decode(Bool.self) {
      self = .bool(boolValue)
    } else if let intValue = try? container.decode(Int.self) {
      self = .int(intValue)
    } else if let doubleValue = try? container.decode(Double.self) {
      self = .double(doubleValue)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    }
  }
}

/// Element targeting query shared by every `ax.*` action.
/// Match semantics: every non-empty criterion must match.
/// `title`, `label`, and `identifier` match case-insensitively as "contains".
/// `role` matches the element role or subrole exactly (case-insensitive).
public struct AXElementQuery: Equatable, Sendable {
  public var appName: String?
  public var pid: Int32?
  public var windowTitle: String?
  public var windowIndex: Int?
  public var role: String?
  public var title: String?
  public var label: String?
  public var identifier: String?
  public var valueContains: String?
  public var index: Int
  public var maxDepth: Int
  public var maxElements: Int
  public var allWindows: Bool
  /// Search scope: "windows" (default), "menubar", or "all".
  public var scope: String?
  /// When true, only include interactive/scrollable roles in the tree.
  public var compact: Bool

  public init(
    appName: String? = nil,
    pid: Int32? = nil,
    windowTitle: String? = nil,
    windowIndex: Int? = nil,
    role: String? = nil,
    title: String? = nil,
    label: String? = nil,
    identifier: String? = nil,
    valueContains: String? = nil,
    index: Int = 0,
    maxDepth: Int = 10,
    maxElements: Int = 500,
    allWindows: Bool = false,
    scope: String? = nil,
    compact: Bool = false
  ) {
    self.appName = appName
    self.pid = pid
    self.windowTitle = windowTitle
    self.windowIndex = windowIndex
    self.role = role
    self.title = title
    self.label = label
    self.identifier = identifier
    self.valueContains = valueContains
    self.index = index
    self.maxDepth = maxDepth
    self.maxElements = maxElements
    self.allWindows = allWindows
    self.scope = scope
    self.compact = compact
  }

  public var hasMatchCriteria: Bool {
    [role, title, label, identifier, valueContains].contains { value in
      value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
  }
}

/// A snapshot of one accessibility element (and optionally its subtree).
public struct AXElementNode: Codable, Equatable, Sendable {
  public let role: String?
  public let subrole: String?
  public let title: String?
  public let label: String?
  public let identifier: String?
  public let value: AXAttributeValue?
  public let valueTruncated: Bool?
  public let frame: CaptureRect?
  public let enabled: Bool?
  public let focused: Bool?
  public let children: [AXElementNode]?

  public init(
    role: String?,
    subrole: String?,
    title: String?,
    label: String?,
    identifier: String?,
    value: AXAttributeValue?,
    valueTruncated: Bool?,
    frame: CaptureRect?,
    enabled: Bool?,
    focused: Bool?,
    children: [AXElementNode]?
  ) {
    self.role = role
    self.subrole = subrole
    self.title = title
    self.label = label
    self.identifier = identifier
    self.value = value
    self.valueTruncated = valueTruncated
    self.frame = frame
    self.enabled = enabled
    self.focused = focused
    self.children = children
  }
}

public struct AXAppPayload: Codable, Equatable, Sendable {
  public let pid: Int32
  public let name: String
  public let bundleId: String?
  public let active: Bool
  public let windowCount: Int

  public init(pid: Int32, name: String, bundleId: String?, active: Bool, windowCount: Int) {
    self.pid = pid
    self.name = name
    self.bundleId = bundleId
    self.active = active
    self.windowCount = windowCount
  }
}

public struct AXAppListPayload: Codable, Equatable, Sendable {
  public let apps: [AXAppPayload]

  public init(apps: [AXAppPayload]) {
    self.apps = apps
  }
}

public struct AXWindowPayload: Codable, Equatable, Sendable {
  public let index: Int
  public let title: String?
  public let frame: CaptureRect?
  public let main: Bool

  public init(index: Int, title: String?, frame: CaptureRect?, main: Bool) {
    self.index = index
    self.title = title
    self.frame = frame
    self.main = main
  }
}

public struct AXWindowListPayload: Codable, Equatable, Sendable {
  public let pid: Int32
  public let app: String
  public let windows: [AXWindowPayload]

  public init(pid: Int32, app: String, windows: [AXWindowPayload]) {
    self.pid = pid
    self.app = app
    self.windows = windows
  }
}

public struct AXTreePayload: Codable, Equatable, Sendable {
  public let pid: Int32
  public let app: String
  public let window: AXWindowPayload?
  public let truncated: Bool
  public let root: AXElementNode

  public init(pid: Int32, app: String, window: AXWindowPayload?, truncated: Bool, root: AXElementNode) {
    self.pid = pid
    self.app = app
    self.window = window
    self.truncated = truncated
    self.root = root
  }
}

public struct AXFindPayload: Codable, Equatable, Sendable {
  public let matches: [AXElementNode]
  public let truncated: Bool

  public init(matches: [AXElementNode], truncated: Bool) {
    self.matches = matches
    self.truncated = truncated
  }
}

public struct AXPerformPayload: Codable, Equatable, Sendable {
  public let action: String
  public let element: AXElementNode

  public init(action: String, element: AXElementNode) {
    self.action = action
    self.element = element
  }
}

public struct AXValuePayload: Codable, Equatable, Sendable {
  public let element: AXElementNode

  public init(element: AXElementNode) {
    self.element = element
  }
}

public struct AXSimpleResultPayload: Codable, Equatable, Sendable {
  public let action: String
  public let detail: String

  public init(action: String, detail: String) {
    self.action = action
    self.detail = detail
  }
}

/// One top-level item in an application's menu bar.
public struct AXMenuItemPayload: Codable, Equatable, Sendable {
  public let title: String
  public let enabled: Bool

  public init(title: String, enabled: Bool) {
    self.title = title
    self.enabled = enabled
  }
}

/// The visible top-level menu bar items for one application.
public struct AXMenuListPayload: Codable, Equatable, Sendable {
  public let appName: String
  public let items: [AXMenuItemPayload]

  public init(appName: String, items: [AXMenuItemPayload]) {
    self.appName = appName
    self.items = items
  }
}

/// Result of a high-level menu click or hierarchical navigation action.
public struct AXMenuActionPayload: Codable, Equatable, Sendable {
  public let action: String
  public let appName: String
  public let path: [String]
  public let item: AXElementNode

  public init(action: String, appName: String, path: [String], item: AXElementNode) {
    self.action = action
    self.appName = appName
    self.path = path
    self.item = item
  }
}

/// A concrete, already-resolved owner of menu-bar status items. Curated
/// functions bind access to its bundle ID before passing this PID to AX.
public struct AXMenuBarExtraAppTarget: Equatable, Sendable {
  public let pid: Int32
  public let appName: String
  public let bundleID: String

  public init(pid: Int32, appName: String, bundleID: String) {
    self.pid = pid
    self.appName = appName
    self.bundleID = bundleID
  }
}

/// One status item from an application's `AXExtrasMenuBar`.
public struct AXMenuBarExtraPayload: Codable, Equatable, Sendable {
  public let appName: String
  public let bundleID: String?
  public let pid: Int32
  public let title: String?
  public let label: String?
  public let identifier: String?
  public let description: String?
  public let enabled: Bool
  public let frame: CaptureRect?

  public init(
    appName: String,
    bundleID: String?,
    pid: Int32,
    title: String?,
    label: String?,
    identifier: String?,
    description: String?,
    enabled: Bool,
    frame: CaptureRect?
  ) {
    self.appName = appName
    self.bundleID = bundleID
    self.pid = pid
    self.title = title
    self.label = label
    self.identifier = identifier
    self.description = description
    self.enabled = enabled
    self.frame = frame
  }
}

/// Status items found across one or more running applications.
public struct AXMenuBarExtrasListPayload: Codable, Equatable, Sendable {
  public let items: [AXMenuBarExtraPayload]

  public init(items: [AXMenuBarExtraPayload]) {
    self.items = items
  }
}

/// A status item's popup menu after it has been opened.
public struct AXMenuBarExtraOpenPayload: Codable, Equatable, Sendable {
  public let appName: String
  public let statusItem: AXMenuBarExtraPayload
  public let menuItems: [AXElementNode]

  public init(appName: String, statusItem: AXMenuBarExtraPayload, menuItems: [AXElementNode]) {
    self.appName = appName
    self.statusItem = statusItem
    self.menuItems = menuItems
  }
}

/// Result of pressing a menu item in a status item's popup hierarchy.
public struct AXMenuBarExtraClickPayload: Codable, Equatable, Sendable {
  public let appName: String
  public let statusItem: AXMenuBarExtraPayload
  public let path: [String]
  public let item: AXElementNode

  public init(appName: String, statusItem: AXMenuBarExtraPayload, path: [String], item: AXElementNode) {
    self.appName = appName
    self.statusItem = statusItem
    self.path = path
    self.item = item
  }
}

/// One item in an application's menu bar (or one of its menus) as surfaced by
/// the curated `menu.list` function. `path` is the title path that `menu.click`
/// accepts to press the same item.
public struct AXAppMenuItemPayload: Codable, Equatable, Sendable {
  public let title: String
  public let enabled: Bool
  public let hasSubmenu: Bool
  public let path: [String]

  public init(title: String, enabled: Bool, hasSubmenu: Bool, path: [String]) {
    self.title = title
    self.enabled = enabled
    self.hasSubmenu = hasSubmenu
    self.path = path
  }
}

/// The visible menu bar items for one application.
public struct AXAppMenuListPayload: Codable, Equatable, Sendable {
  public let appName: String
  public let items: [AXAppMenuItemPayload]

  public init(appName: String, items: [AXAppMenuItemPayload]) {
    self.appName = appName
    self.items = items
  }
}

/// One on-screen window as surfaced by the curated `window.list` function.
/// `index` is the window's stable position within its owning application and is
/// used as the window identifier for the other `window.*` functions.
public struct AXWindowCatalogItemPayload: Codable, Equatable, Sendable {
  public let appName: String
  public let bundleID: String?
  public let pid: Int32
  public let index: Int
  public let title: String?
  public let role: String?
  public let subrole: String?
  public let frame: CaptureRect?
  public let main: Bool

  public init(
    appName: String,
    bundleID: String?,
    pid: Int32,
    index: Int,
    title: String?,
    role: String?,
    subrole: String?,
    frame: CaptureRect?,
    main: Bool
  ) {
    self.appName = appName
    self.bundleID = bundleID
    self.pid = pid
    self.index = index
    self.title = title
    self.role = role
    self.subrole = subrole
    self.frame = frame
    self.main = main
  }
}

/// Windows found across one or more running applications.
public struct AXWindowCatalogPayload: Codable, Equatable, Sendable {
  public let windows: [AXWindowCatalogItemPayload]

  public init(windows: [AXWindowCatalogItemPayload]) {
    self.windows = windows
  }
}

/// Result of a curated window action (close, minimize, zoom, or raise).
public struct AXWindowActionPayload: Codable, Equatable, Sendable {
  public let action: String
  public let appName: String
  public let bundleID: String?
  public let pid: Int32
  public let index: Int
  public let title: String?

  public init(action: String, appName: String, bundleID: String?, pid: Int32, index: Int, title: String?) {
    self.action = action
    self.appName = appName
    self.bundleID = bundleID
    self.pid = pid
    self.index = index
    self.title = title
  }
}
